import 'dart:io';
import 'dart:convert';

import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// SharedPreferences key holding the set of already-uploaded dump identifiers
/// (`<basename>:<finalSize>`), used to make auto-upload idempotent.
const _kUploadedKey = 'wr_uploaded_ids';

/// MIME type used when uploading Opus-in-OGG dump files to Drive.
const _kOpusMime = 'audio/ogg; codecs=opus';

/// The default Drive folder that recordings are stored under (user-overridable
/// via the [_kFolderKey] preference, set on the Settings page).
const _kFolderName = 'recordings';

/// Project default Drive folder. This matches the PC-side Drive mirror at
/// `C:\Users\knsol\coai\recordings`.
const _kDefaultFolderId = '1IPNXw8EzMz6u6nGUo5H1xtuwkI4NKayJ';

/// SharedPreferences key holding the user-chosen destination folder name
/// (shown in Settings; also the create-by-name fallback).
const _kFolderKey = 'wr_drive_folder';

/// SharedPreferences key holding the user-chosen destination folder ID. When
/// set, uploads target this exact folder (picked from the folder chooser),
/// bypassing name-based lookup.
const _kFolderIdKey = 'wr_drive_folder_id';

/// Drive API scope that allows creating / uploading files only.
const _kDriveScope = drive.DriveApi.driveFileScope;

/// Read scope is needed for transcript markdown files created by the PC-side
/// transcription pipeline, not necessarily by this mobile app.
const _kDriveReadScope = drive.DriveApi.driveReadonlyScope;

class WrTranscriptFile {
  const WrTranscriptFile({
    required this.id,
    required this.name,
    this.modifiedTime,
    this.sizeBytes,
  });

  final String id;
  final String name;
  final DateTime? modifiedTime;
  final int? sizeBytes;
}

// ---------------------------------------------------------------------------
// Private HTTP client that injects Google auth headers into every request.
// ---------------------------------------------------------------------------

class _GoogleAuthClient extends http.BaseClient {
  _GoogleAuthClient(this._headers);

  final Map<String, String> _headers;
  final http.Client _inner = http.Client();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    request.headers.addAll(_headers);
    return _inner.send(request);
  }

  @override
  void close() {
    _inner.close();
    super.close();
  }
}

// ---------------------------------------------------------------------------
// Public service
// ---------------------------------------------------------------------------

/// Uploads recorded .opus dump files from the local device to Google Drive.
///
/// Dependency-injection-friendly: pass a pre-configured [GoogleSignIn]
/// instance (useful in tests). When omitted, a default instance scoped to
/// [drive.DriveApi.driveFileScope] is created.
///
/// For unit-testing without network access use the [WrDriveUploader.withApi]
/// factory, which injects a mock [drive.DriveApi] directly and skips
/// the Google sign-in flow entirely.
///
/// Example:
/// ```dart
/// final uploader = WrDriveUploader();
/// final fileId = await uploader.uploadFile(localFile, 'session-1234.opus');
/// ```
class WrDriveUploader {
  WrDriveUploader({GoogleSignIn? googleSignIn})
      : _googleSignIn = googleSignIn ??
            GoogleSignIn(scopes: [_kDriveScope, _kDriveReadScope]),
        _apiOverride = null,
        _useDefaultFolderId = true;

  /// Test-only constructor that bypasses Google sign-in entirely and uses the
  /// provided [drive.DriveApi] mock for all Drive calls.
  WrDriveUploader.withApi(drive.DriveApi api)
      : _googleSignIn = GoogleSignIn(scopes: [_kDriveScope, _kDriveReadScope]),
        _apiOverride = api,
        _useDefaultFolderId = false;

  final GoogleSignIn _googleSignIn;

  /// When non-null, [_buildApi] returns this directly (used in tests).
  final drive.DriveApi? _apiOverride;
  final bool _useDefaultFolderId;

  // Cache the folder ID so repeated uploads in one session skip the search.
  String? _cachedFolderId;

  // Cache of folder metadata (id -> File) for resolving ancestor paths.
  final Map<String, drive.File> _metaCache = {};

  /// Signs in (or re-uses an existing session) and returns an authenticated
  /// [drive.DriveApi] instance backed by a [_GoogleAuthClient].
  ///
  /// If [_apiOverride] is set (test-only), returns it directly.
  Future<drive.DriveApi> _buildApi() async {
    final override = _apiOverride;
    if (override != null) return override;

    GoogleSignInAccount? account = _googleSignIn.currentUser;
    account ??= await _googleSignIn.signInSilently();
    account ??= await _googleSignIn.signIn();

    if (account == null) {
      throw StateError('Google Sign-In cancelled or failed.');
    }

    final authHeaders = await account.authHeaders;
    final client = _GoogleAuthClient(authHeaders);
    return drive.DriveApi(client);
  }

  /// The configured destination folder name (user-overridable in Settings),
  /// falling back to [_kFolderName].
  Future<String> folderName() async {
    final prefs = await SharedPreferences.getInstance();
    final n = prefs.getString(_kFolderKey)?.trim();
    return (n == null || n.isEmpty) ? _kFolderName : n;
  }

  /// Lists the child folders (id + name) directly under [parentId] — use
  /// `'root'` for My Drive — alphabetically. Powers the hierarchical folder
  /// chooser so the app mirrors Drive's own folder tree.
  Future<List<drive.File>> listSubfolders(String parentId) async {
    final api = await _buildApi();
    final result = await api.files.list(
      q: "'$parentId' in parents and "
          "mimeType='application/vnd.google-apps.folder' and trashed=false",
      spaces: 'drive',
      $fields: 'files(id,name)',
      orderBy: 'name',
      pageSize: 200,
    );
    return result.files ?? [];
  }

  /// Searches ALL of the user's Drive folders by name (case-insensitive
  /// substring). Unlike [listSubfolders], this spans the whole Drive — My
  /// Drive, "Computers" (Drive-for-desktop synced folders), and shared items —
  /// so the user can target a PC-synced folder that isn't reachable by walking
  /// the My-Drive tree. Returns id + name (+ parents for disambiguation).
  Future<List<drive.File>> searchFolders(String query) async {
    final api = await _buildApi();
    final escaped = query.replaceAll("'", r"\'");
    final result = await api.files.list(
      q: "name contains '$escaped' and "
          "mimeType='application/vnd.google-apps.folder' and trashed=false",
      spaces: 'drive',
      $fields: 'files(id,name,parents)',
      orderBy: 'name',
      pageSize: 100,
    );
    return result.files ?? [];
  }

  /// Builds a human-readable location for a folder from its [parents], e.g.
  /// "My Drive › Projects › 2026", or "MyLaptop › Documents" for a Computers
  /// (Drive-for-desktop) folder. Resolves ancestor names via the API with a
  /// small cache. Used to disambiguate same-named folders in search results.
  Future<String> folderPath(List<String>? parents) async {
    if (parents == null || parents.isEmpty) return 'My Drive';
    final api = await _buildApi();
    final names = <String>[];
    List<String>? current = parents;
    var guard = 0;
    while (current != null && current.isNotEmpty && guard++ < 12) {
      final pid = current.first;
      if (pid == 'root') {
        names.add('My Drive');
        break;
      }
      var meta = _metaCache[pid];
      if (meta == null) {
        meta =
            await api.files.get(pid, $fields: 'id,name,parents') as drive.File;
        _metaCache[pid] = meta;
      }
      names.add(meta.name ?? '…');
      current = meta.parents;
    }
    return names.reversed.join(' › ');
  }

  /// Creates a new Drive folder (optionally under [parentId]) and returns it
  /// (id + name populated).
  Future<drive.File> createFolder(String name, {String? parentId}) async {
    final api = await _buildApi();
    final folder = drive.File()
      ..name = name
      ..mimeType = 'application/vnd.google-apps.folder';
    if (parentId != null && parentId != 'root') folder.parents = [parentId];
    return api.files.create(folder, $fields: 'id,name');
  }

  /// The exact destination folder ID chosen in Settings, or null if the user
  /// hasn't picked one (then we fall back to resolving [folderName] by name).
  Future<String?> _configuredFolderId() async {
    final prefs = await SharedPreferences.getInstance();
    final id = prefs.getString(_kFolderIdKey)?.trim();
    if (id != null && id.isNotEmpty) return id;
    return _useDefaultFolderId ? _kDefaultFolderId : null;
  }

  /// Returns the Drive folder ID for the configured folder, creating it if
  /// needed. Cached for the lifetime of this [WrDriveUploader] instance.
  Future<String> _ensureFolder(drive.DriveApi api) async {
    final cached = _cachedFolderId;
    if (cached != null) return cached;

    // Prefer an explicitly-picked folder ID (from the folder chooser).
    final pickedId = await _configuredFolderId();
    if (pickedId != null) {
      _cachedFolderId = pickedId;
      return pickedId;
    }

    final name = await folderName();
    // Search for an existing folder with the expected name owned by the user.
    final query =
        "mimeType='application/vnd.google-apps.folder' and name='$name' and trashed=false";
    final result = await api.files.list(
      q: query,
      spaces: 'drive',
      $fields: 'files(id,name)',
    );

    final files = result.files;
    if (files != null && files.isNotEmpty) {
      _cachedFolderId = files.first.id!;
      return _cachedFolderId!;
    }

    // Folder not found — create it.
    final folder = drive.File()
      ..name = name
      ..mimeType = 'application/vnd.google-apps.folder';
    final created = await api.files.create(folder);
    _cachedFolderId = created.id!;
    return _cachedFolderId!;
  }

  /// Lists all files in the configured Drive folder, most-recently modified
  /// first. Returns an empty list if the folder does not exist yet.
  Future<List<drive.File>> listFiles() async {
    final api = await _buildApi();

    String? folderId = _cachedFolderId ?? await _configuredFolderId();
    if (folderId == null) {
      final name = await folderName();
      final query =
          "mimeType='application/vnd.google-apps.folder' and name='$name' and trashed=false";
      final result = await api.files.list(
        q: query,
        spaces: 'drive',
        $fields: 'files(id)',
      );
      final folderFiles = result.files;
      if (folderFiles == null || folderFiles.isEmpty) return [];
      folderId = folderFiles.first.id!;
      _cachedFolderId = folderId;
    }

    final result = await api.files.list(
      q: "'$folderId' in parents and trashed=false",
      spaces: 'drive',
      $fields: 'files(id,name,modifiedTime)',
    );
    final files = result.files ?? [];
    // Sort most-recently-modified first (client-side; list is small).
    files.sort((a, b) {
      final at = a.modifiedTime;
      final bt = b.modifiedTime;
      if (at == null && bt == null) return 0;
      if (at == null) return 1;
      if (bt == null) return -1;
      return bt.compareTo(at);
    });
    return files;
  }

  /// Permanently deletes the Drive file identified by [fileId].
  Future<void> deleteFile(String fileId) async {
    final api = await _buildApi();
    await api.files.delete(fileId);
  }

  Future<String?> _findChildFolder(
    drive.DriveApi api, {
    required String parentId,
    required String name,
  }) async {
    final escaped = name.replaceAll("'", r"\'");
    final result = await api.files.list(
      q: "'$parentId' in parents and "
          "mimeType='application/vnd.google-apps.folder' and "
          "name='$escaped' and trashed=false",
      spaces: 'drive',
      $fields: 'files(id,name)',
      pageSize: 1,
    );
    final files = result.files;
    if (files == null || files.isEmpty) return null;
    return files.first.id;
  }

  Future<List<String>> _findFolderIdsByName(
    drive.DriveApi api,
    String name,
  ) async {
    final escaped = name.replaceAll("'", r"\'");
    final result = await api.files.list(
      q: "mimeType='application/vnd.google-apps.folder' and "
          "name='$escaped' and trashed=false",
      spaces: 'drive',
      $fields: 'files(id,name)',
      pageSize: 20,
    );
    return (result.files ?? const <drive.File>[])
        .map((f) => f.id)
        .whereType<String>()
        .toList();
  }

  Future<List<WrTranscriptFile>> _listTranscriptMarkdownFiles(
    drive.DriveApi api,
    String transcriptsId,
  ) async {
    final result = await api.files.list(
      q: "'$transcriptsId' in parents and "
          "name contains '.md' and trashed=false",
      spaces: 'drive',
      $fields: 'files(id,name,modifiedTime,size)',
      orderBy: 'modifiedTime desc',
      pageSize: 200,
    );

    return (result.files ?? const <drive.File>[])
        .where(
            (f) => f.id != null && (f.name ?? '').toLowerCase().endsWith('.md'))
        .map((f) => WrTranscriptFile(
              id: f.id!,
              name: f.name ?? '(unnamed).md',
              modifiedTime: f.modifiedTime,
              sizeBytes: int.tryParse(f.size ?? ''),
            ))
        .toList();
  }

  /// Lists markdown transcript files under
  /// `<configured Drive folder>/transcripts/`.
  ///
  /// The app's local settings can disappear when a debug build is reinstalled,
  /// while the PC-side transcription pipeline keeps writing to
  /// `recordings/transcripts`. To keep the transcript screen useful after that
  /// kind of reinstall, search the configured folder first, then common
  /// recording folders, then any Drive folder named `transcripts`.
  Future<List<WrTranscriptFile>> listTranscripts() async {
    final api = await _buildApi();

    final parentIds = <String>{};
    final configuredId = _cachedFolderId ?? await _configuredFolderId();
    if (configuredId != null) parentIds.add(configuredId);

    final configuredName = await folderName();
    final parentNames = <String>{configuredName, _kFolderName};
    for (final name in parentNames) {
      parentIds.addAll(await _findFolderIdsByName(api, name));
    }

    final transcriptFolderIds = <String>{};
    for (final parentId in parentIds) {
      final id =
          await _findChildFolder(api, parentId: parentId, name: 'transcripts');
      if (id != null) transcriptFolderIds.add(id);
    }

    if (transcriptFolderIds.isEmpty) {
      transcriptFolderIds
          .addAll(await _findFolderIdsByName(api, 'transcripts'));
    }

    final byId = <String, WrTranscriptFile>{};
    for (final folderId in transcriptFolderIds) {
      for (final f in await _listTranscriptMarkdownFiles(api, folderId)) {
        byId[f.id] = f;
      }
    }

    final files = byId.values.toList();
    files.sort((a, b) {
      final at = a.modifiedTime;
      final bt = b.modifiedTime;
      if (at == null && bt == null) return a.name.compareTo(b.name);
      if (at == null) return 1;
      if (bt == null) return -1;
      return bt.compareTo(at);
    });
    return files;
  }

  /// Downloads a markdown transcript file as UTF-8 text.
  Future<String> downloadTranscriptMarkdown(String fileId) async {
    final api = await _buildApi();
    final media = await api.files.get(
      fileId,
      downloadOptions: drive.DownloadOptions.fullMedia,
    ) as drive.Media;
    final bytes = <int>[];
    await for (final chunk in media.stream) {
      bytes.addAll(chunk);
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  /// Uploads [localFile] to the "wearable-recordings/" Drive folder.
  ///
  /// [remoteFileName] is the name the file will have on Drive (e.g.
  /// `"session-1234.opus"`). Returns the newly created Drive file ID.
  ///
  /// Throws [StateError] if the user cancels sign-in, or re-throws any
  /// Drive API error.
  Future<String> uploadFile(File localFile, String remoteFileName) async {
    final api = await _buildApi();
    final folderId = await _ensureFolder(api);

    final meta = drive.File()
      ..name = remoteFileName
      ..parents = [folderId];

    final media = drive.Media(
      localFile.openRead(),
      await localFile.length(),
      contentType: _kOpusMime,
    );

    final created = await api.files.create(
      meta,
      uploadMedia: media,
    );

    final id = created.id;
    if (id == null) {
      throw StateError('Drive API returned a file with no ID.');
    }
    return id;
  }

  // Cache of remote name -> Drive file id, so the omi-style incremental sync
  // updates the same session file in place instead of creating duplicates.
  final Map<String, String> _fileIdByName = {};

  /// Creates the Drive file [remoteFileName] if it doesn't exist, or REPLACES
  /// its content if it does. Used by the omi-style sync: one growing file per
  /// recording session, updated in place (keeps the Drive file count low).
  /// Returns the Drive file id.
  Future<String> uploadOrUpdate(File localFile, String remoteFileName) async {
    final api = await _buildApi();
    final folderId = await _ensureFolder(api);

    String? fileId = _fileIdByName[remoteFileName];
    if (fileId == null) {
      final escaped = remoteFileName.replaceAll("'", r"\'");
      final res = await api.files.list(
        q: "'$folderId' in parents and name='$escaped' and trashed=false",
        spaces: 'drive',
        $fields: 'files(id)',
      );
      final found = res.files;
      if (found != null && found.isNotEmpty) fileId = found.first.id;
    }

    final media = drive.Media(
      localFile.openRead(),
      await localFile.length(),
      contentType: _kOpusMime,
    );

    if (fileId != null) {
      await api.files.update(drive.File(), fileId, uploadMedia: media);
      _fileIdByName[remoteFileName] = fileId;
      return fileId;
    }

    final meta = drive.File()
      ..name = remoteFileName
      ..parents = [folderId];
    final created = await api.files.create(meta, uploadMedia: media);
    final id = created.id;
    if (id == null) {
      throw StateError('Drive API returned a file with no ID.');
    }
    _fileIdByName[remoteFileName] = id;
    return id;
  }

  /// Email of the currently-signed-in Google account (silent sign-in), or null
  /// if no account is connected yet.
  Future<String?> currentEmail() async {
    if (_apiOverride != null) return null;
    final acct =
        _googleSignIn.currentUser ?? await _googleSignIn.signInSilently();
    return acct?.email;
  }

  /// Interactive account picker: signs out then signs in so Google shows its
  /// account chooser. Returns the chosen account's email (null if cancelled).
  /// Resets the cached folder id since a different account = a different Drive.
  Future<String?> chooseAccount() async {
    await _googleSignIn.signOut();
    final acct = await _googleSignIn.signIn();
    _cachedFolderId = null;
    return acct?.email;
  }

  /// Disconnects the current Google account.
  Future<void> signOut() async {
    await _googleSignIn.signOut();
    _cachedFolderId = null;
  }

  Future<String> _idFor(File f) async =>
      '${f.uri.pathSegments.last}:${await f.length()}';

  /// True if [localFile] (by name + current size) has already been uploaded.
  Future<bool> isUploaded(File localFile) async {
    final prefs = await SharedPreferences.getInstance();
    final set = prefs.getStringList(_kUploadedKey) ?? const <String>[];
    return set.contains(await _idFor(localFile));
  }

  /// True if any file with base name [name] has been uploaded (size-agnostic).
  /// Lets the SD-sync skip re-fetching a completed chunk it already sent.
  Future<bool> isUploadedByName(String name) async {
    final prefs = await SharedPreferences.getInstance();
    final set = prefs.getStringList(_kUploadedKey) ?? const <String>[];
    return set.any((id) => id.startsWith('$name:'));
  }

  /// Uploads [localFile] only if it hasn't been uploaded before (tracked by
  /// name + final size in SharedPreferences). Returns the Drive file id on a
  /// fresh upload, or null if it was already uploaded.
  Future<String?> uploadIfNew(File localFile, String remoteFileName) async {
    final prefs = await SharedPreferences.getInstance();
    final set = prefs.getStringList(_kUploadedKey) ?? <String>[];
    final id = await _idFor(localFile);
    if (set.contains(id)) {
      final api = await _buildApi();
      final folderId = await _ensureFolder(api);
      final escaped = remoteFileName.replaceAll("'", r"\'");
      final existing = await api.files.list(
        q: "'$folderId' in parents and name='$escaped' and trashed=false",
        spaces: 'drive',
        $fields: 'files(id)',
      );
      final files = existing.files;
      if (files != null && files.isNotEmpty) return null;
    }
    final fileId = await uploadFile(localFile, remoteFileName);
    if (!set.contains(id)) set.add(id);
    await prefs.setStringList(_kUploadedKey, set);
    return fileId;
  }

  /// Uploads every file in [files] that hasn't been uploaded yet. Per-file
  /// failures are swallowed (left for a later retry). Returns how many files
  /// were freshly uploaded.
  Future<int> syncPending(
    List<File> files, {
    required String Function(File) nameFor,
    void Function(File file, String driveId)? onUploaded,
  }) async {
    var count = 0;
    for (final f in files) {
      try {
        final id = await uploadIfNew(f, nameFor(f));
        if (id != null) {
          count++;
          onUploaded?.call(f, id);
        }
      } catch (_) {
        // Network / auth hiccup — leave this file for the next sync.
      }
    }
    return count;
  }
}
