import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:google_sign_in/google_sign_in.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mojio/services/wr_drive_uploader.dart';

// ---------------------------------------------------------------------------
// Mocks
// ---------------------------------------------------------------------------

class _MockGoogleSignIn extends Mock implements GoogleSignIn {}

class _MockDriveApi extends Mock implements drive.DriveApi {}

class _MockFilesResource extends Mock implements drive.FilesResource {}

// ---------------------------------------------------------------------------
// Fakes (required by mocktail for any() / captureAny() with custom types)
// ---------------------------------------------------------------------------

class _FakeDriveFile extends Fake implements drive.File {}

class _FakeMedia extends Fake implements drive.Media {}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Creates a temporary file pre-filled with [content] bytes.
Future<File> _tempOpusFile([String content = 'fake opus data']) async {
  final dir = Directory.systemTemp.createTempSync('wr_uploader_test_');
  return File('${dir.path}/session.opus')..writeAsBytesSync(content.codeUnits);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  setUpAll(() {
    registerFallbackValue(_FakeDriveFile());
    registerFallbackValue(_FakeMedia());
  });

  late _MockDriveApi mockApi;
  late _MockFilesResource mockFiles;
  late _MockGoogleSignIn mockSignIn;

  setUp(() {
    SharedPreferences.setMockInitialValues({});

    mockApi = _MockDriveApi();
    mockFiles = _MockFilesResource();
    mockSignIn = _MockGoogleSignIn();

    // DriveApi.files delegate to the files resource mock.
    when(() => mockApi.files).thenReturn(mockFiles);
  });

  group('WrDriveUploader.uploadFile', () {
    // ------------------------------------------------------------------
    // Scenario 1: folder does not exist yet — should create it, then upload.
    //
    // Note: in mocktail, any(named:'x') matches null (absent named arg), so
    // a stub with uploadMedia: any(named:...) also intercepts folder-create
    // calls (which omit uploadMedia). We use a single stub that dispatches on
    // uploadMedia presence to avoid the two-stub ambiguity.
    // ------------------------------------------------------------------
    test('creates folder when none exists and uploads with correct MIME type',
        () async {
      // list() returns empty — no folder found.
      when(() => mockFiles.list(
            q: any(named: 'q'),
            spaces: any(named: 'spaces'),
            $fields: any(named: r'$fields'),
          )).thenAnswer((_) async => drive.FileList()..files = []);

      var folderCreated = false;
      drive.Media? capturedMedia;
      when(() => mockFiles.create(
            any(),
            uploadMedia: any(named: 'uploadMedia'),
          )).thenAnswer((inv) async {
        final uploadMedia = inv.namedArguments[#uploadMedia];
        if (uploadMedia == null) {
          folderCreated = true;
          return drive.File()..id = 'folder-id-123';
        }
        capturedMedia = uploadMedia as drive.Media;
        return drive.File()..id = 'file-id-abc';
      });

      final dumpFile = await _tempOpusFile();
      final uploader = WrDriveUploader.withApi(mockApi);

      final fileId = await uploader.uploadFile(dumpFile, 'session-0001.opus');

      expect(fileId, 'file-id-abc');
      expect(folderCreated, true);

      // list() must have been called to look for the folder.
      verify(() => mockFiles.list(
            q: any(named: 'q'),
            spaces: any(named: 'spaces'),
            $fields: any(named: r'$fields'),
          )).called(1);

      // Verify MIME type from the captured media object.
      expect(capturedMedia?.contentType, 'audio/ogg; codecs=opus');
    });

    // ------------------------------------------------------------------
    // Scenario 2: folder exists — should re-use it without creating again.
    // ------------------------------------------------------------------
    test('uses existing folder returned by Drive list()', () async {
      final existingFolder = drive.File()
        ..id = 'existing-folder-id'
        ..name = 'wearable-recordings';

      when(() => mockFiles.list(
            q: any(named: 'q'),
            spaces: any(named: 'spaces'),
            $fields: any(named: r'$fields'),
          )).thenAnswer(
        (_) async => drive.FileList()..files = [existingFolder],
      );

      var folderCreateCount = 0;
      when(() => mockFiles.create(
            any(),
            uploadMedia: any(named: 'uploadMedia'),
          )).thenAnswer((inv) async {
        final uploadMedia = inv.namedArguments[#uploadMedia];
        if (uploadMedia == null) {
          folderCreateCount++;
          return drive.File()..id = 'should-not-happen';
        }
        return drive.File()..id = 'uploaded-file-id';
      });

      final dumpFile = await _tempOpusFile();
      final uploader = WrDriveUploader.withApi(mockApi);

      final fileId = await uploader.uploadFile(dumpFile, 'session.opus');
      expect(fileId, 'uploaded-file-id');

      // Folder create must NOT have been called.
      expect(folderCreateCount, 0);
    });

    // ------------------------------------------------------------------
    // Scenario 3: folder ID is cached — list() called only once.
    // ------------------------------------------------------------------
    test('caches folder ID so list() is called only once across uploads',
        () async {
      final existingFolder = drive.File()..id = 'folder-cached';
      when(() => mockFiles.list(
            q: any(named: 'q'),
            spaces: any(named: 'spaces'),
            $fields: any(named: r'$fields'),
          )).thenAnswer(
        (_) async => drive.FileList()..files = [existingFolder],
      );

      var uploadCount = 0;
      when(() => mockFiles.create(
            any(),
            uploadMedia: any(named: 'uploadMedia'),
          )).thenAnswer((inv) async {
        final uploadMedia = inv.namedArguments[#uploadMedia];
        if (uploadMedia == null) return drive.File()..id = 'folder-cached';
        uploadCount++;
        return drive.File()..id = 'f-$uploadCount';
      });

      final dumpFile = await _tempOpusFile();
      final uploader = WrDriveUploader.withApi(mockApi);

      await uploader.uploadFile(dumpFile, 'a.opus');
      await uploader.uploadFile(dumpFile, 'b.opus');

      // Only one list() even though we uploaded twice.
      verify(() => mockFiles.list(
            q: any(named: 'q'),
            spaces: any(named: 'spaces'),
            $fields: any(named: r'$fields'),
          )).called(1);
    });

    // ------------------------------------------------------------------
    // Scenario 4: Drive returns a file with no ID — should throw.
    // ------------------------------------------------------------------
    test('throws StateError when Drive API returns a file with no ID',
        () async {
      final existingFolder = drive.File()..id = 'folder-x';
      when(() => mockFiles.list(
            q: any(named: 'q'),
            spaces: any(named: 'spaces'),
            $fields: any(named: r'$fields'),
          )).thenAnswer(
        (_) async => drive.FileList()..files = [existingFolder],
      );

      when(() => mockFiles.create(
            any(),
            uploadMedia: any(named: 'uploadMedia'),
          )).thenAnswer((inv) async {
        final uploadMedia = inv.namedArguments[#uploadMedia];
        if (uploadMedia == null) return drive.File()..id = 'folder-x';
        return drive.File(); // id == null
      });

      final dumpFile = await _tempOpusFile();
      final uploader = WrDriveUploader.withApi(mockApi);

      await expectLater(
        () => uploader.uploadFile(dumpFile, 'bad.opus'),
        throwsA(isA<StateError>()),
      );
    });

    // ------------------------------------------------------------------
    // Scenario 5: Google Sign-In cancelled — should throw StateError.
    // ------------------------------------------------------------------
    test('throws StateError when Google Sign-In is cancelled', () async {
      when(() => mockSignIn.currentUser).thenReturn(null);
      when(() => mockSignIn.signInSilently()).thenAnswer((_) async => null);
      when(() => mockSignIn.signIn()).thenAnswer((_) async => null);

      final dumpFile = await _tempOpusFile();
      // Use the standard constructor with the mock sign-in (no API override).
      final uploader = WrDriveUploader(googleSignIn: mockSignIn);

      await expectLater(
        () => uploader.uploadFile(dumpFile, 'session.opus'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('cancelled'),
          ),
        ),
      );
    });

    // ------------------------------------------------------------------
    // Scenario 6: remoteFileName is stored as the Drive file name.
    // ------------------------------------------------------------------
    test('sets correct remote file name in Drive metadata', () async {
      // Folder already exists — only the upload create is called.
      final existingFolder = drive.File()..id = 'f-folder';
      when(() => mockFiles.list(
            q: any(named: 'q'),
            spaces: any(named: 'spaces'),
            $fields: any(named: r'$fields'),
          )).thenAnswer(
        (_) async => drive.FileList()..files = [existingFolder],
      );

      drive.File? capturedMeta;
      when(() => mockFiles.create(
            any(),
            uploadMedia: any(named: 'uploadMedia'),
          )).thenAnswer((invocation) async {
        final uploadMedia = invocation.namedArguments[#uploadMedia];
        if (uploadMedia == null) return drive.File()..id = 'f-folder';
        capturedMeta = invocation.positionalArguments.first as drive.File;
        return drive.File()..id = 'new-id';
      });

      final dumpFile = await _tempOpusFile();
      final uploader = WrDriveUploader.withApi(mockApi);

      await uploader.uploadFile(dumpFile, 'my-custom-name.opus');

      expect(capturedMeta?.name, 'my-custom-name.opus');
      expect(capturedMeta?.parents, contains('f-folder'));
    });
  });

  group('WrDriveUploader.uploadIfNew', () {
    test('re-uploads when local uploaded marker exists but Drive file is gone',
        () async {
      final dumpFile = await _tempOpusFile();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
        'wr_uploaded_ids',
        ['${dumpFile.uri.pathSegments.last}:${await dumpFile.length()}'],
      );

      when(() => mockFiles.list(
            q: any(named: 'q'),
            spaces: any(named: 'spaces'),
            $fields: any(named: r'$fields'),
          )).thenAnswer((invocation) async {
        final q = invocation.namedArguments[#q] as String?;
        if (q != null &&
            q.contains("mimeType='application/vnd.google-apps.folder'")) {
          return drive.FileList()..files = [drive.File()..id = 'folder-id'];
        }
        return drive.FileList()..files = [];
      });

      when(() => mockFiles.create(
            any(),
            uploadMedia: any(named: 'uploadMedia'),
          )).thenAnswer((_) async => drive.File()..id = 'new-file-id');

      final uploader = WrDriveUploader.withApi(mockApi);

      final id = await uploader.uploadIfNew(dumpFile, 'session.opus');

      expect(id, 'new-file-id');
      verify(() => mockFiles.create(
            any(),
            uploadMedia: any(named: 'uploadMedia'),
          )).called(1);
    });

    test('skips upload only when the Drive file still exists', () async {
      final dumpFile = await _tempOpusFile();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
        'wr_uploaded_ids',
        ['${dumpFile.uri.pathSegments.last}:${await dumpFile.length()}'],
      );

      when(() => mockFiles.list(
            q: any(named: 'q'),
            spaces: any(named: 'spaces'),
            $fields: any(named: r'$fields'),
          )).thenAnswer((invocation) async {
        final q = invocation.namedArguments[#q] as String?;
        if (q != null &&
            q.contains("mimeType='application/vnd.google-apps.folder'")) {
          return drive.FileList()..files = [drive.File()..id = 'folder-id'];
        }
        return drive.FileList()
          ..files = [drive.File()..id = 'existing-file-id'];
      });

      final uploader = WrDriveUploader.withApi(mockApi);

      final id = await uploader.uploadIfNew(dumpFile, 'session.opus');

      expect(id, isNull);
      verifyNever(() => mockFiles.create(
            any(),
            uploadMedia: any(named: 'uploadMedia'),
          ));
    });
  });

  group('WrDriveUploader.listFiles', () {
    // ------------------------------------------------------------------
    // Scenario 7: folder not found → empty list returned without error.
    // ------------------------------------------------------------------
    test('returns empty list when the folder does not exist', () async {
      when(() => mockFiles.list(
            q: any(named: 'q'),
            spaces: any(named: 'spaces'),
            $fields: any(named: r'$fields'),
          )).thenAnswer((_) async => drive.FileList()..files = []);

      final uploader = WrDriveUploader.withApi(mockApi);
      final files = await uploader.listFiles();

      expect(files, isEmpty);
      // Only one list() call — the folder lookup; no file-listing call.
      verify(() => mockFiles.list(
            q: any(named: 'q'),
            spaces: any(named: 'spaces'),
            $fields: any(named: r'$fields'),
          )).called(1);
    });

    // ------------------------------------------------------------------
    // Scenario 8: folder found, files exist → returns them in order.
    //
    // listFiles() calls list() twice: first to find the folder, then to
    // enumerate files. We dispatch on the q parameter to return different
    // responses.
    // ------------------------------------------------------------------
    test('returns file list when folder and files exist', () async {
      when(() => mockFiles.list(
            q: any(named: 'q'),
            spaces: any(named: 'spaces'),
            $fields: any(named: r'$fields'),
          )).thenAnswer((inv) async {
        final q = inv.namedArguments[#q] as String? ?? '';
        if (q.contains('in parents')) {
          return drive.FileList()
            ..files = [
              drive.File()
                ..id = 'file-1'
                ..name = 'session-001.opus',
              drive.File()
                ..id = 'file-2'
                ..name = 'session-002.opus',
            ];
        }
        // Folder-lookup call.
        return drive.FileList()..files = [drive.File()..id = 'folder-id'];
      });

      final uploader = WrDriveUploader.withApi(mockApi);
      final files = await uploader.listFiles();

      expect(files, hasLength(2));
      expect(files[0].name, 'session-001.opus');
      expect(files[1].name, 'session-002.opus');
      // Two list() calls: folder lookup + file enumeration.
      verify(() => mockFiles.list(
            q: any(named: 'q'),
            spaces: any(named: 'spaces'),
            $fields: any(named: r'$fields'),
          )).called(2);
    });
  });

  group('WrDriveUploader.deleteFile', () {
    // ------------------------------------------------------------------
    // Scenario 9: deleteFile() delegates to api.files.delete() with the
    // correct file ID.
    // ------------------------------------------------------------------
    test('calls api.files.delete() with the given file ID', () async {
      when(() => mockFiles.delete(any())).thenAnswer((_) async {});

      final uploader = WrDriveUploader.withApi(mockApi);
      await uploader.deleteFile('target-file-id');

      verify(() => mockFiles.delete('target-file-id')).called(1);
    });
  });

  group('WrDriveUploader.listTranscripts', () {
    test('falls back to recordings/transcripts when app folder setting is gone',
        () async {
      final queries = <String>[];
      when(() => mockFiles.list(
            q: any(named: 'q'),
            spaces: any(named: 'spaces'),
            $fields: any(named: r'$fields'),
            orderBy: any(named: 'orderBy'),
            pageSize: any(named: 'pageSize'),
          )).thenAnswer((inv) async {
        final q = inv.namedArguments[#q] as String? ?? '';
        queries.add(q);
        if (q.contains("'transcripts-folder' in parents")) {
          return drive.FileList()
            ..files = [
              drive.File()
                ..id = 'md-1'
                ..name = '2026-06-06.md'
                ..modifiedTime = DateTime.utc(2026, 6, 6, 7, 19)
                ..size = '137963',
            ];
        }
        return drive.FileList()..files = [];
      });

      when(() => mockFiles.list(
            q: any(named: 'q'),
            spaces: any(named: 'spaces'),
            $fields: any(named: r'$fields'),
            pageSize: any(named: 'pageSize'),
          )).thenAnswer((inv) async {
        final q = inv.namedArguments[#q] as String? ?? '';
        queries.add(q);

        if (q.contains("name='wearable-recordings'")) {
          return drive.FileList()..files = [];
        }
        if (q.contains("name='recordings'")) {
          return drive.FileList()
            ..files = [
              drive.File()
                ..id = 'recordings-folder'
                ..name = 'recordings',
            ];
        }
        if (q.contains("'recordings-folder' in parents") &&
            q.contains("name='transcripts'")) {
          return drive.FileList()
            ..files = [
              drive.File()
                ..id = 'transcripts-folder'
                ..name = 'transcripts',
            ];
        }
        if (q.contains("'transcripts-folder' in parents")) {
          return drive.FileList()
            ..files = [
              drive.File()
                ..id = 'md-1'
                ..name = '2026-06-06.md'
                ..modifiedTime = DateTime.utc(2026, 6, 6, 7, 19)
                ..size = '137963',
            ];
        }
        if (q.contains("name='transcripts'")) {
          return drive.FileList()..files = [];
        }
        return drive.FileList()..files = [];
      });

      final uploader = WrDriveUploader.withApi(mockApi);
      final files = await uploader.listTranscripts();

      printOnFailure(queries.join('\n'));
      expect(files, hasLength(1));
      expect(files.single.id, 'md-1');
      expect(files.single.name, '2026-06-06.md');
      expect(files.single.sizeBytes, 137963);
    });
  });
}
