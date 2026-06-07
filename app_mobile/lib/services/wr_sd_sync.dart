import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'wr_ble_device.dart';
import 'wr_drive_uploader.dart';
import 'wr_storage_client.dart';
import 'wr_sync_schedule.dart';

/// SharedPreferences key: upload only over Wi-Fi (don't use mobile data).
const kWifiOnlyKey = 'wr_upload_wifi_only';

/// SharedPreferences key: upload queued chunks to Drive automatically.
const kDriveUploadAutoKey = 'wr_drive_upload_auto';

/// Live state of the Drive upload queue (chunks fetched from the device but not
/// yet uploaded to Google Drive), for the UI.
class WrUploadStatus {
  const WrUploadStatus({
    required this.pendingFiles,
    required this.pendingBytes,
    required this.completedBytes,
    required this.totalBytes,
    required this.uploading,
    required this.blockedNoWifi,
    required this.autoUpload,
    required this.waitingForManual,
    required this.uploadedChunks,
    this.currentFile,
  });

  final int pendingFiles; // chunks waiting in the outbox
  final int pendingBytes; // total bytes waiting
  final int completedBytes; // bytes uploaded in the current visible batch
  final int totalBytes; // total bytes in the current visible batch
  final bool uploading; // a chunk is being sent right now
  final bool blockedNoWifi; // Wi-Fi-only is on and we're not on Wi-Fi
  final bool autoUpload; // true = queue drains automatically
  final bool waitingForManual; // manual mode with queued files waiting
  final int uploadedChunks; // chunks uploaded this app run
  final String? currentFile; // chunk being uploaded now

  double get passPct => totalBytes <= 0 ? 1 : completedBytes / totalBytes;

  bool get idle =>
      !uploading && !blockedNoWifi && !waitingForManual && pendingFiles == 0;
}

/// Pulls the device's single growing recording file off the SD card
/// incrementally (omi-style) and re-emits it as discrete, complete,
/// epoch-named `.opus_sd` chunk files on Drive — the format the
/// voice_transcribe watcher expects (size-stable, name+size idempotent,
/// session-combined, moved after processing).
///
/// Why not upload one growing file? The Drive-for-desktop mirror re-downloads
/// a changed file whole (no append), the transcriber's size-stable wait never
/// fires on a growing file, and its name+size dedup would reprocess it every
/// update. So the phone acts like omi's backend: it slices the byte stream at
/// Opus frame boundaries into fixed-duration chunks and uploads each once.
///
/// Per device session file we keep a cursor: how many bytes we've fetched
/// (`offset`), bytes pending in the current chunk, and the next chunk index.
/// Chunk k starts at sessionStartEpoch + k*chunkSeconds, named
/// `<startEpoch>.opus_sd`. Deterministic boundaries make re-runs idempotent
/// (uploadIfNew dedups by name+size).
/// Live progress of the incremental SD->Drive sync, for the UI.
class WrSyncProgress {
  const WrSyncProgress({
    required this.fileName,
    required this.committed,
    required this.synced,
    required this.bytesPerSec,
    required this.uploadedChunks,
    this.fetching = false,
  });

  final String? fileName; // device file being synced (null until first status)
  final int committed; // device file's committed size (bytes)
  final int synced; // bytes pulled to the phone so far
  final double bytesPerSec; // recent fetch throughput
  final int uploadedChunks; // chunks uploaded to Drive this session
  final bool fetching; // true while actively pulling a window right now

  /// Un-fetched bytes still on the device (the backlog).
  int get backlogBytes {
    final b = committed - synced;
    return b > 0 ? b : 0;
  }

  bool get caughtUp => backlogBytes == 0;
}

class WrSdSync {
  WrSdSync({
    required this.device,
    required this.uploader,
    this.chunkSeconds = 300, // 5-minute chunks
  });

  final WrBleDevice device;
  final WrDriveUploader uploader;
  final int chunkSeconds;

  static const int _window = 64 * 1024; // reliable per-fetch window
  // Bytes pulled before yielding to the other file (current <-> closed backlog).
  // Kept ~1 MB so the live file and the old-file backlog interleave every
  // ~1-2 min at BLE speed instead of one starving the other for many minutes.
  static const int _maxBytesPerPass = 1 * 1024 * 1024;
  static const int _frameMs = 10; // one [len][frame] record = 10 ms of audio

  int get _framesPerChunk => chunkSeconds * 1000 ~/ _frameMs;

  bool _running = false;
  Duration _idlePoll = const Duration(seconds: 10);
  WrStorageSession? _session;
  int uploadedChunks = 0;

  // Manual-mode trigger: in SyncMode.manual the loop only fetches when the user
  // taps the pull button (sets this via [triggerManualPull]); else it idles.
  bool _manualTrigger = false;

  // Upload (outbox -> Drive) state, decoupled from fetch so the queue is visible
  // in the UI and can be gated by Wi-Fi.
  bool _wifiOnly = false;
  bool _driveUploadAuto = true;
  bool _manualUploadTrigger = false;
  bool _uploadingNow = false;
  bool _blockedNoWifi = false;
  bool _waitingForManualUpload = false;
  String? _curUploadName;
  int _uploadDoneBytes = 0;
  int _uploadTotalBytes = 0;

  // Auto-pull schedule (loaded from prefs when the loop starts).
  SyncSchedule _schedule = const SyncSchedule();
  DateTime? _lastScheduledDate; // scheduledTime: last day a run completed
  DateTime? _lastIntervalRun; // intervalWindow: last completion time
  bool _timedDrainActive = false;

  // Closed files that errored mid-fetch (e.g. SD bad sector -> fs_read -5).
  // Skipped for the rest of this session so one unreadable file can't block the
  // whole backlog; cleared on restart so a transient error gets retried.
  final Set<String> _failedFiles = {};

  /// Latest committed size the device reported for the current file.
  int lastCommitted = 0;

  // Recent-throughput tracking (for the UI rate read-out).
  int _rateRefOffset = 0;
  DateTime _rateRefTime = DateTime.now();
  double _bytesPerSec = 0;

  // Per-current-file cursor state.
  String? _name;
  int _offset = 0; // bytes fetched from the device file
  int _chunkIndex = 0; // next chunk number
  int? _sessionStartEpoch; // parsed from <epoch>.opus_sd, else null
  BytesBuilder _pending = BytesBuilder(copy: false);

  final _events = StreamController<String>.broadcast();
  Stream<String> get events => _events.stream;

  final _progress = StreamController<WrSyncProgress>.broadcast();
  Stream<WrSyncProgress> get progress => _progress.stream;

  final _uploadStatus = StreamController<WrUploadStatus>.broadcast();
  Stream<WrUploadStatus> get uploadStatus => _uploadStatus.stream;

  /// Manually trigger a fetch run (used by the main-screen pull button, and
  /// effective in manual mode). Harmless in the other modes.
  void triggerManualPull() => _manualTrigger = true;

  /// Manually trigger Drive upload of queued chunks.
  void triggerManualUpload() => _manualUploadTrigger = true;

  void _emitProgress({bool fetching = false}) {
    if (_progress.isClosed) return;
    _progress.add(WrSyncProgress(
      fileName: _name,
      committed: lastCommitted,
      synced: _offset,
      bytesPerSec: _bytesPerSec,
      uploadedChunks: uploadedChunks,
      fetching: fetching,
    ));
  }

  /// Starts the continuous catch-up loop. While the device file has un-fetched
  /// bytes the loop pulls back-to-back (no fixed gap) so a backlog drains as
  /// fast as the BLE link allows; once caught up it polls every [idlePoll].
  void start({Duration idlePoll = const Duration(seconds: 10)}) {
    if (_running) return;
    _idlePoll = idlePoll;
    _running = true;
    _loop(); // fetch device -> outbox
    _uploadLoop(); // outbox -> Drive (independent, Wi-Fi gated)
  }

  Future<void> stop() async {
    _running = false;
    try {
      // Flush the trailing partial chunk so the tail isn't lost.
      if (_name != null) {
        await _flushPending(force: true);
        await _persistOffset();
        await _persistPending();
      }
    } catch (_) {}
    await _session?.close();
    _session = null;
  }

  Future<void> dispose() async {
    await stop();
    await _events.close();
    await _progress.close();
    await _uploadStatus.close();
  }

  // ---- persistence (survive app restart / reconnect) --------------------

  Future<File> _pendingFile(String name) async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/pending_$name.bin');
  }

  int? _epochFromName(String name) {
    final m = RegExp(r'^(\d{10})\.opus_sd$').firstMatch(name);
    return m == null ? null : int.tryParse(m.group(1)!);
  }

  Future<void> _loadState(String name) async {
    final prefs = await SharedPreferences.getInstance();
    _name = name;
    _offset = prefs.getInt('wr_sync_off_$name') ?? 0;
    _chunkIndex = prefs.getInt('wr_sync_ci_$name') ?? 0;
    _sessionStartEpoch = _epochFromName(name);
    final pf = await _pendingFile(name);
    _pending = BytesBuilder(copy: false);
    if (await pf.exists()) {
      _pending.add(await pf.readAsBytes());
    }
  }

  /// Cheap checkpoint of just the cursor ints — safe to call every window so a
  /// mid-pass error never loses (or re-fetches) progress.
  Future<void> _persistOffset() async {
    final name = _name;
    if (name == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('wr_sync_off_$name', _offset);
    await prefs.setInt('wr_sync_ci_$name', _chunkIndex);
  }

  /// Writes the pending (not-yet-cut) bytes to disk. Heavier (a file write of up
  /// to one chunk) so it's called on chunk cuts / every few windows, not always.
  Future<void> _persistPending() async {
    final name = _name;
    if (name == null) return;
    final pf = await _pendingFile(name);
    final bytes = _pending.toBytes();
    if (bytes.isEmpty) {
      if (await pf.exists()) {
        await pf.delete();
      }
      return;
    }
    await pf.writeAsBytes(bytes, flush: true);
  }

  // ---- chunk cutting ----------------------------------------------------

  /// Byte length of the first [_framesPerChunk] whole [len][frame] records in
  /// [buf], or -1 if there aren't that many complete frames yet.
  int _chunkBoundary(Uint8List buf) {
    int pos = 0;
    int frames = 0;
    while (frames < _framesPerChunk) {
      if (pos >= buf.length) return -1; // need more
      final len = buf[pos];
      final next = pos + 1 + len;
      if (next > buf.length) return -1; // trailing partial frame
      pos = next;
      frames++;
    }
    return pos;
  }

  String _chunkName(int index) {
    final base = _sessionStartEpoch;
    if (base != null) {
      return '${base + index * chunkSeconds}.opus_sd';
    }
    // rec_NNNN (pre time-sync): approximate start from the phone clock.
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return '${now - chunkSeconds}.opus_sd';
  }

  Future<void> _emitChunk(Uint8List bytes) async {
    final name = _chunkName(_chunkIndex);
    final dir = await _outboxDir();
    final f = File('${dir.path}/$name');
    await f.writeAsBytes(bytes, flush: true);
    _chunkIndex++;
    if (!_events.isClosed) _events.add('queued $name (${bytes.length}B)');
    await _emitUploadStatus();
  }

  Future<Directory> _outboxDir() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/outbox');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<void> _emitUploadStatus() async {
    if (_uploadStatus.isClosed) return;
    try {
      final dir = await _outboxDir();
      final files =
          await dir.list().where((e) => e is File).cast<File>().toList();
      files.sort((a, b) => a.path.compareTo(b.path));
      int totalBytes = 0;
      for (final f in files) {
        try {
          totalBytes += await f.length();
        } catch (_) {}
      }
      _uploadStatus.add(WrUploadStatus(
        pendingFiles: files.length,
        pendingBytes: totalBytes,
        completedBytes: _uploadingNow ? _uploadDoneBytes : 0,
        totalBytes: _uploadingNow ? _uploadTotalBytes : totalBytes,
        uploading: _uploadingNow,
        blockedNoWifi: _blockedNoWifi,
        autoUpload: _driveUploadAuto,
        waitingForManual: _waitingForManualUpload,
        uploadedChunks: uploadedChunks,
        currentFile: _curUploadName,
      ));
    } catch (_) {}
  }

  /// Cuts and uploads every full chunk in [_pending]. With [force], also emits
  /// a final shorter chunk for the remaining bytes (session end). Returns true
  /// if any chunk was emitted (so the caller can checkpoint promptly).
  Future<bool> _flushPending({bool force = false}) async {
    var buf = _pending.toBytes();
    var changed = false;
    while (true) {
      final boundary = _chunkBoundary(buf);
      if (boundary < 0) break;
      await _emitChunk(Uint8List.sublistView(buf, 0, boundary));
      buf = Uint8List.sublistView(buf, boundary);
      changed = true;
    }
    if (force && buf.isNotEmpty) {
      await _emitChunk(buf);
      buf = Uint8List(0);
      changed = true;
    }
    if (changed) {
      _pending = BytesBuilder(copy: false)..add(buf);
    }
    return changed;
  }

  // ---- main loop --------------------------------------------------------

  Future<void> _uploadLoop() async {
    while (_running) {
      final prefs = await SharedPreferences.getInstance();
      _wifiOnly = prefs.getBool(kWifiOnlyKey) ?? false;
      _driveUploadAuto = prefs.getBool(kDriveUploadAutoKey) ?? true;
      _uploadDoneBytes = 0;
      _uploadTotalBytes = 0;

      final dir = await _outboxDir();
      List<({File file, int length})> pending;
      try {
        final files =
            await dir.list().where((e) => e is File).cast<File>().toList();
        files.sort((a, b) => a.path.compareTo(b.path));
        pending = [];
        for (final f in files) {
          try {
            pending.add((file: f, length: await f.length()));
          } catch (_) {}
        }
      } catch (_) {
        await Future<void>.delayed(const Duration(seconds: 5));
        continue;
      }

      if (pending.isEmpty) {
        _waitingForManualUpload = false;
        _uploadingNow = false;
        _curUploadName = null;
        await _emitUploadStatus();
        await Future<void>.delayed(const Duration(seconds: 5));
        continue;
      }

      if (!_driveUploadAuto && !_manualUploadTrigger) {
        _waitingForManualUpload = true;
        _uploadingNow = false;
        _curUploadName = null;
        await _emitUploadStatus();
        await Future<void>.delayed(const Duration(seconds: 5));
        continue;
      }
      _manualUploadTrigger = false;
      _waitingForManualUpload = false;

      if (_wifiOnly) {
        final result = await Connectivity().checkConnectivity();
        final onWifi = result.contains(ConnectivityResult.wifi);
        if (!onWifi) {
          _blockedNoWifi = true;
          _uploadingNow = false;
          await _emitUploadStatus();
          await Future<void>.delayed(const Duration(seconds: 15));
          continue;
        }
      }
      _blockedNoWifi = false;

      _uploadTotalBytes = pending.fold<int>(0, (sum, p) => sum + p.length);
      _uploadDoneBytes = 0;
      for (final item in pending) {
        if (!_running) break;
        if (_wifiOnly) {
          final result = await Connectivity().checkConnectivity();
          if (!result.contains(ConnectivityResult.wifi)) {
            _blockedNoWifi = true;
            _uploadingNow = false;
            await _emitUploadStatus();
            break;
          }
        }
        final f = item.file;
        final name = f.uri.pathSegments.last;
        _uploadingNow = true;
        _curUploadName = name;
        await _emitUploadStatus();
        try {
          final id = await uploader.uploadIfNew(f, name);
          if (id != null) {
            uploadedChunks++;
            if (!_events.isClosed) _events.add('uploaded $name');
          }
          await f.delete();
          _uploadDoneBytes += item.length;
          await _emitUploadStatus();
        } catch (e) {
          if (!_events.isClosed) _events.add('upload error $name: $e');
          await Future<void>.delayed(const Duration(seconds: 5));
          break;
        }
      }
      _uploadingNow = false;
      _curUploadName = null;
      await _emitUploadStatus();
      if (_uploadDoneBytes < _uploadTotalBytes) {
        await Future<void>.delayed(const Duration(seconds: 5));
      }
    }
  }

  /// Continuous driver: drain back-to-back while a backlog remains, otherwise
  /// idle-poll. Runs for the whole connection (only [stop] ends it). A transient
  /// BLE error reopens the cheap storage session (no reconnect) and retries
  /// within seconds instead of stalling a fixed interval — the bug that let the
  /// device out-record the old 64 KB-per-30 s sync.
  Future<void> _loop() async {
    while (_running) {
      _schedule = await SyncSchedule.load();
      final now = DateTime.now();
      if (_manualTrigger) {
        _manualTrigger = false;
      } else if (_schedule.mode == SyncMode.manual) {
        _timedDrainActive = false;
        if (!_manualTrigger) {
          await Future<void>.delayed(const Duration(seconds: 5));
          continue;
        }
      } else if (!_timedDrainActive &&
          !_schedule.shouldStart(now,
              lastScheduledDate: _lastScheduledDate,
              lastIntervalRun: _lastIntervalRun)) {
        // Outside the configured schedule — re-check shortly.
        await Future<void>.delayed(const Duration(seconds: 20));
        continue;
      }

      // Drain the whole backlog (catch up), retrying transient errors so a
      // mid-drain hiccup doesn't abandon the accumulated bytes.
      int pulled = 0;
      try {
        // Alternate one pass of the live current file with one pass of the
        // closed-file backlog (old sessions / rec_*), so neither starves — the
        // oldest data drains in parallel with keeping the live file moving,
        // which is what "drain everything older than ~15 min" needs.
        pulled = await _drainOnce();
        pulled += await _drainClosedFiles();
      } catch (e) {
        if (!_events.isClosed) _events.add('sync error: $e');
        await _reopenSession();
        await Future<void>.delayed(const Duration(seconds: 2));
        continue; // retry without marking this run complete
      }

      if (_schedule.mode != SyncMode.continuous && pulled > 0) {
        // A timed run is only complete once the backlog is empty. Previously an
        // hourly run pulled one small pass, then waited another hour even when
        // more SD audio remained queued on the device.
        _timedDrainActive = true;
        await Future<void>.delayed(const Duration(milliseconds: 200));
        continue;
      }

      _timedDrainActive = false;

      // Record completion (gates the scheduled / interval modes).
      final done = DateTime.now();
      _lastScheduledDate = done;
      _lastIntervalRun = done;

      // While a backlog remains, loop promptly to keep draining; once fully
      // caught up, idle-poll. Timed modes just re-check their trigger.
      if (_schedule.mode == SyncMode.manual) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
      } else {
        await Future<void>.delayed(_schedule.mode != SyncMode.continuous
            ? const Duration(seconds: 20)
            : (pulled > 0 ? const Duration(milliseconds: 200) : _idlePoll));
      }
    }
  }

  Future<void> _reopenSession() async {
    try {
      await _session?.close();
    } catch (_) {}
    _session = null;
  }

  /// One drain pass: refresh status, then pull up to [_maxBytesPerPass] of the
  /// backlog in [_window] windows, cutting/uploading chunks as data arrives.
  /// Returns bytes pulled this pass (0 = caught up / nothing to do).
  Future<int> _drainOnce() async {
    _session ??= await device.openStorageSession();
    final session = _session;
    if (session == null) {
      if (!_events.isClosed) _events.add('storage service unavailable');
      return 0; // no storage service (old firmware)
    }

    final st = await session.status();
    if (st == null) {
      _emitProgress();
      return 0; // not recording / old firmware
    }

    final name = st.name;
    final committed = st.size;
    lastCommitted = committed;

    if (name != _name) {
      // Switched files — flush the previous one's COMPLETE chunks only (never
      // force a partial chunk on a switch: the file may still be growing or be
      // resumed later; partial tails are only flushed when a file is finished).
      if (_name != null) {
        await _flushPending();
        await _persistOffset();
        await _persistPending();
      }
      await _loadState(name);
      _rateRefOffset = _offset;
      _rateRefTime = DateTime.now();
    }

    if (_offset > committed) {
      // Device file shrank (reboot/new file reusing a name): restart it.
      _offset = 0;
      _chunkIndex = 0;
      _pending = BytesBuilder(copy: false);
    }

    if (_offset >= committed) {
      _bytesPerSec = 0;
      _emitProgress();
      return 0; // caught up
    }

    int pulled = 0;
    int windows = 0;
    while (_running && _offset < committed && pulled < _maxBytesPerPass) {
      final res = await session.fetchWindow(name, _offset, _window);
      if (res.bytes.isEmpty) break;
      _pending.add(res.bytes);
      _offset += res.bytes.length;
      pulled += res.bytes.length;
      windows++;

      // Throughput estimate over a ~2 s sliding reference (for the UI).
      final now = DateTime.now();
      final dt = now.difference(_rateRefTime).inMilliseconds;
      if (dt >= 2000) {
        _bytesPerSec = (_offset - _rateRefOffset) * 1000 / dt;
        _rateRefOffset = _offset;
        _rateRefTime = now;
      }

      // Persist the cursor every window (cheap) so a mid-pass error can't lose
      // or re-fetch progress; cut + upload complete chunks as they form.
      await _persistOffset();
      final cut = await _flushPending();
      if (cut || (windows % 8) == 0) await _persistPending();
      _emitProgress(fetching: true);
    }
    await _persistOffset();
    await _persistPending();

    if (pulled > 0) {
      _events.add('synced +${pulled}B of $name @$_offset/$committed');
    }
    _emitProgress();
    return pulled;
  }

  /// Pull the backlog of CLOSED audio files (previous sessions, rec_*). Drains
  /// one pass of one not-yet-finished file per call, so the live current file
  /// keeps priority; a file is flagged done in prefs once fully fetched.
  Future<int> _drainClosedFiles() async {
    final session = _session;
    if (session == null) {
      if (!_events.isClosed) _events.add('storage session not open');
      return 0;
    }
    List<String> files;
    try {
      files = await session.listFiles();
    } catch (e) {
      if (!_events.isClosed) {
        _events.add('list error: $e');
      }
      return 0;
    }
    final prefs = await SharedPreferences.getInstance();
    var totalPulled = 0;
    files = files
        .where((name) =>
            name.endsWith('.opus_sd') &&
            !name.startsWith('battlog') &&
            !_failedFiles.contains(name) &&
            !(prefs.getBool('wr_sync_done_$name') ?? false))
        .toList();
    files.sort((a, b) {
      final ae = _epochFromName(a) ?? -1;
      final be = _epochFromName(b) ?? -1;
      if (ae != be) return be.compareTo(ae);
      return a.compareTo(b);
    });

    for (final name in files) {
      if (!_running) break;
      final pulled = await _drainClosedFile(name);
      totalPulled += pulled;
      if (pulled > 0) break;
    }
    return totalPulled;
  }

  /// Drain one pass (<= [_maxBytesPerPass]) of a closed file, chunking +
  /// uploading like the current file. Marks it done once fully fetched.
  Future<int> _drainClosedFile(String name) async {
    final session = _session;
    if (session == null) return 0;

    if (name != _name) {
      if (_name != null) {
        await _flushPending();
        await _persistOffset();
        await _persistPending();
      }
      await _loadState(name);
      _rateRefOffset = _offset;
      _rateRefTime = DateTime.now();
    }

    int pulled = 0;
    int windows = 0;
    int committed = -1;
    try {
      while (_running && pulled < _maxBytesPerPass) {
        final ({Uint8List bytes, int committedSize}) res;
        try {
          res = await session.fetchWindow(name, _offset, _window);
        } catch (e) {
          if (_offset == 0 && pulled == 0) {
            if (!_events.isClosed) {
              _events.add('legacy fetch $name');
            }
            final legacyBytes = await session.fetchFileLegacy(name);
            if (legacyBytes.isNotEmpty) {
              _pending.add(legacyBytes);
              _offset += legacyBytes.length;
              pulled += legacyBytes.length;
              committed = legacyBytes.length;
              lastCommitted = committed;
              await _persistOffset();
              await _flushPending(force: true);
              await _persistPending();
              _emitProgress(fetching: true);
              break;
            }
          }
          rethrow;
        }
        committed = res.committedSize;
        lastCommitted = committed;
        if (res.bytes.isEmpty &&
            committed == 0 &&
            _offset == 0 &&
            pulled == 0) {
          final legacyBytes = await session.fetchFileLegacy(name);
          if (legacyBytes.isEmpty) {
            break;
          }
          _pending.add(legacyBytes);
          _offset += legacyBytes.length;
          pulled += legacyBytes.length;
          committed = legacyBytes.length;
          lastCommitted = committed;
          await _persistOffset();
          await _flushPending(force: true);
          await _persistPending();
          _emitProgress(fetching: true);
          break;
        }
        if (res.bytes.isEmpty) break;
        _pending.add(res.bytes);
        _offset += res.bytes.length;
        pulled += res.bytes.length;
        windows++;

        final now = DateTime.now();
        final dt = now.difference(_rateRefTime).inMilliseconds;
        if (dt >= 2000) {
          _bytesPerSec = (_offset - _rateRefOffset) * 1000 / dt;
          _rateRefOffset = _offset;
          _rateRefTime = now;
        }

        await _persistOffset();
        final cut = await _flushPending();
        if (cut || (windows % 8) == 0) {
          await _persistPending();
        }
        _emitProgress(fetching: true);
        if (_offset >= committed) {
          break;
        }
      }
    } catch (e) {
      // This file won't read past _offset (e.g. SD bad sector -> fs_read -5).
      // Skip it for the session so it can't block the rest of the backlog;
      // keep the bytes already pulled. Don't rethrow (avoid a tight retry loop).
      _failedFiles.add(name);
      await _persistOffset();
      await _persistPending();
      if (!_events.isClosed) {
        _events.add('skip $name @$_offset (read error): $e');
      }
      _emitProgress();
      return pulled;
    }

    // Fully fetched -> flush the final tail and mark done so it's skipped next.
    if (committed == 0 && _offset == 0 && pulled == 0) {
      if (!_events.isClosed) {
        _events.add('skip $name (empty fetch response)');
      }
    } else if (committed >= 0 && _offset >= committed) {
      await _flushPending(force: true);
      await _persistOffset();
      await _persistPending();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('wr_sync_done_$name', true);
    }
    _emitProgress();
    return pulled;
  }
}
