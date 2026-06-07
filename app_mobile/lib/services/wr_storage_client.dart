import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'wr_uuids.dart';

// Protocol byte constants (mirror of wr_storage_service.c)
const _cmdList = 0x00;
const _cmdFetch = 0x01; // [0x01][4B offset LE][4B length LE][filename]
const _cmdStatus = 0x02; // [0x02] -> NOTIF_STATUS
const _cmdAbort = 0xFF;

const _notifFileEntry = 0x01;
const _notifData = 0x02;
const _notifEnd = 0x03;
const _notifFileSize = 0x04; // [4B committed size LE]
const _notifStatus = 0x05; // [4B committed size LE][basename]
const _notifError = 0xFF;

List<int> _le32(int v) =>
    [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF];

T? _firstWhereOrNull<T>(Iterable<T> values, bool Function(T value) test) {
  for (final value in values) {
    if (test(value)) return value;
  }
  return null;
}

/// BLE client for the mojizo Storage GATT service.
///
/// Wraps the storageStream (notify) and storageReadControl (write) GATT
/// characteristics to provide a typed async API for listing and fetching
/// files stored on the device's SD card.
///
/// Obtain an instance via [WrStorageSession.fromServices] (passing the
/// services discovered by [WrBleDevice.connect]) or via the test
/// constructor [WrStorageSession.forTest].
///
/// Every operation subscribes to [BluetoothCharacteristic.onValueReceived]
/// (not `lastValueStream`) to avoid receiving stale cached notifications
/// from a previous operation.
class WrStorageSession {
  WrStorageSession._({
    required BluetoothCharacteristic stream,
    required BluetoothCharacteristic ctrl,
  })  : _stream = stream,
        _ctrl = ctrl;

  /// Test-only constructor — injects characteristic mocks directly.
  WrStorageSession.forTest({
    required BluetoothCharacteristic stream,
    required BluetoothCharacteristic ctrl,
  })  : _stream = stream,
        _ctrl = ctrl;

  final BluetoothCharacteristic _stream;
  final BluetoothCharacteristic _ctrl;

  StreamSubscription<List<int>>? _sub;

  // -------------------------------------------------------------------
  // Factory
  // -------------------------------------------------------------------

  /// Creates a [WrStorageSession] from an already-discovered service list.
  ///
  /// Returns null if the storage service is absent (old / plain-omi firmware).
  static Future<WrStorageSession?> fromServices(
      List<BluetoothService> services) async {
    BluetoothCharacteristic? fallbackStream;
    BluetoothCharacteristic? fallbackCtrl;
    BluetoothCharacteristic? streamChar;
    BluetoothCharacteristic? ctrlChar;

    for (final svc in services.where(
      (s) => s.serviceUuid == Guid(WrUuids.storageService),
    )) {
      final streams = svc.characteristics
          .where((c) => c.characteristicUuid == Guid(WrUuids.storageStream))
          .toList();
      final ctrls = svc.characteristics
          .where(
              (c) => c.characteristicUuid == Guid(WrUuids.storageReadControl))
          .toList();
      if (streams.isEmpty || ctrls.isEmpty) continue;

      final stream =
          _firstWhereOrNull(streams, (c) => c.properties.notify) ?? streams[0];
      final ctrl =
          _firstWhereOrNull(ctrls, (c) => c.properties.writeWithoutResponse) ??
              ctrls[0];
      fallbackStream ??= stream;
      fallbackCtrl ??= ctrl;

      if (stream.properties.notify && ctrl.properties.writeWithoutResponse) {
        streamChar = stream;
        ctrlChar = ctrl;
        break;
      }
    }

    streamChar ??= fallbackStream;
    ctrlChar ??= fallbackCtrl;
    if (streamChar == null || ctrlChar == null) return null;

    await streamChar.setNotifyValue(true);
    return WrStorageSession._(stream: streamChar, ctrl: ctrlChar);
  }

  // -------------------------------------------------------------------
  // Public API
  // -------------------------------------------------------------------

  /// Lists all completed `.opus` files on the device SD card.
  ///
  /// Sends a LIST command and collects [_notifFileEntry] notifications
  /// until an [_notifEnd] or [_notifError] is received.
  /// Throws [StateError] on device-side error.
  /// Throws [TimeoutException] if no END is received within [timeout].
  Future<List<String>> listFiles({
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final files = <String>[];
    final completer = Completer<void>();

    _sub?.cancel();
    _sub = _stream.onValueReceived.listen((data) {
      if (data.isEmpty) return;
      switch (data[0]) {
        case _notifFileEntry:
          if (data.length > 1) {
            files.add(String.fromCharCodes(data.sublist(1)));
          }
        case _notifEnd:
          if (!completer.isCompleted) completer.complete();
        case _notifError:
          if (!completer.isCompleted) {
            completer
                .completeError(StateError('Storage service error during LIST'));
          }
      }
    });

    await _ctrl.write([_cmdList], withoutResponse: true);
    await completer.future.timeout(timeout);
    return files;
  }

  /// Fetches the named file from the device SD card and returns its bytes.
  ///
  /// Sends the current mojizo FETCH command and collects [_notifData] chunks
  /// until [_notifEnd]. Throws [StateError] if the device reports an error
  /// (e.g. file not found). Throws [TimeoutException] if the transfer stalls.
  Future<Uint8List> fetchFile(
    String filename, {
    Duration idleTimeout = const Duration(seconds: 20),
    void Function(int bytes)? onProgress,
  }) {
    return _fetchFileWithCommand(
      filename,
      [_cmdFetch, ..._le32(0), ..._le32(0), ...filename.codeUnits],
      idleTimeout: idleTimeout,
      onProgress: onProgress,
    );
  }

  /// Fetches a whole file using the legacy verification-firmware command.
  ///
  /// Older flashed builds accepted `[0x01][filename]` and do not understand
  /// offset/length windows. Keep this as a compatibility fallback so the app
  /// does not mark those files as synced after receiving an empty response.
  Future<Uint8List> fetchFileLegacy(
    String filename, {
    Duration idleTimeout = const Duration(seconds: 20),
    void Function(int bytes)? onProgress,
  }) {
    return _fetchFileWithCommand(
      filename,
      [_cmdFetch, ...filename.codeUnits],
      idleTimeout: idleTimeout,
      onProgress: onProgress,
    );
  }

  Future<Uint8List> _fetchFileWithCommand(
    String filename,
    List<int> command, {
    required Duration idleTimeout,
    void Function(int bytes)? onProgress,
  }) async {
    final chunks = <List<int>>[];
    int totalBytes = 0;
    final completer = Completer<void>();

    // Inactivity watchdog: a multi-MB recording can take many minutes over
    // BLE (~6 KB/s), so a fixed total timeout wrongly aborts large files.
    // Instead we only fail if no chunk arrives for [idleTimeout] — large
    // transfers complete as long as data keeps flowing, and genuine stalls
    // are caught quickly.
    Timer? watchdog;
    void resetWatchdog() {
      watchdog?.cancel();
      watchdog = Timer(idleTimeout, () {
        if (!completer.isCompleted) {
          completer.completeError(TimeoutException(
              'storage fetch stalled: no data for ${idleTimeout.inSeconds}s '
              'after $totalBytes bytes'));
        }
      });
    }

    _sub?.cancel();
    _sub = _stream.onValueReceived.listen((data) {
      if (data.isEmpty) return;
      resetWatchdog(); // any traffic (incl. the 0x04 size tag) keeps us alive
      switch (data[0]) {
        case _notifData:
          if (data.length > 1) {
            final payload = data.sublist(1);
            chunks.add(payload);
            totalBytes += payload.length;
            onProgress?.call(totalBytes);
          }
        case _notifEnd:
          if (!completer.isCompleted) completer.complete();
        case _notifError:
          if (!completer.isCompleted) {
            completer.completeError(
                StateError('File not found on device: $filename'));
          }
      }
    });

    resetWatchdog();
    await _ctrl.write(command, withoutResponse: true);
    try {
      await completer.future;
    } finally {
      watchdog?.cancel();
    }

    // Concatenate chunks into a single Uint8List.
    final result = Uint8List(totalBytes);
    var offset = 0;
    for (final chunk in chunks) {
      result.setRange(offset, offset + chunk.length, chunk);
      offset += chunk.length;
    }
    return result;
  }

  /// Queries the current (growing) recording file and its committed size.
  ///
  /// Returns null if the device isn't recording / has nothing yet, or on a
  /// firmware too old to support CMD_STATUS (no NOTIF_STATUS arrives → timeout
  /// → null). Used by the omi-style incremental sync.
  Future<({String name, int size})?> status({
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final completer = Completer<({String name, int size})?>();

    _sub?.cancel();
    _sub = _stream.onValueReceived.listen((data) {
      if (data.isEmpty) return;
      if (data[0] == _notifStatus && data.length >= 5) {
        final size =
            data[1] | (data[2] << 8) | (data[3] << 16) | (data[4] << 24);
        final name =
            data.length > 5 ? String.fromCharCodes(data.sublist(5)) : '';
        if (!completer.isCompleted) {
          completer.complete(name.isEmpty ? null : (name: name, size: size));
        }
      } else if (data[0] == _notifError) {
        if (!completer.isCompleted) completer.complete(null);
      }
    });

    await _ctrl.write([_cmdStatus], withoutResponse: true);
    try {
      return await completer.future.timeout(timeout);
    } on TimeoutException {
      return null;
    }
  }

  /// Fetches a bounded window [offset, offset+length) of [filename].
  ///
  /// Reading in small windows (e.g. 64 KB) is the reliable transfer pattern —
  /// a single multi-MB fetch can stall/hang the BLE link. Returns the bytes
  /// actually read (may be shorter than [length] if EOF/committed size is
  /// reached). The device also reports the file's total committed size via
  /// [_notifFileSize]; that value is returned in [committedSize].
  Future<({Uint8List bytes, int committedSize})> fetchWindow(
    String filename,
    int offset,
    int length, {
    Duration idleTimeout = const Duration(seconds: 15),
  }) async {
    final chunks = <List<int>>[];
    int totalBytes = 0;
    int committed = 0;
    final completer = Completer<void>();

    Timer? watchdog;
    void resetWatchdog() {
      watchdog?.cancel();
      watchdog = Timer(idleTimeout, () {
        if (!completer.isCompleted) {
          completer.completeError(TimeoutException(
              'window fetch stalled: no data for ${idleTimeout.inSeconds}s '
              'after $totalBytes bytes'));
        }
      });
    }

    _sub?.cancel();
    _sub = _stream.onValueReceived.listen((data) {
      if (data.isEmpty) return;
      resetWatchdog();
      switch (data[0]) {
        case _notifFileSize:
          if (data.length >= 5) {
            committed =
                data[1] | (data[2] << 8) | (data[3] << 16) | (data[4] << 24);
          }
        case _notifData:
          if (data.length > 1) {
            final payload = data.sublist(1);
            chunks.add(payload);
            totalBytes += payload.length;
          }
        case _notifEnd:
          if (!completer.isCompleted) completer.complete();
        case _notifError:
          if (!completer.isCompleted) {
            completer.completeError(
                StateError('Storage error fetching $filename @$offset'));
          }
      }
    });

    resetWatchdog();
    await _ctrl.write(
        [_cmdFetch, ..._le32(offset), ..._le32(length), ...filename.codeUnits],
        withoutResponse: true);
    try {
      await completer.future;
    } finally {
      watchdog?.cancel();
    }

    final result = Uint8List(totalBytes);
    var o = 0;
    for (final chunk in chunks) {
      result.setRange(o, o + chunk.length, chunk);
      o += chunk.length;
    }
    return (bytes: result, committedSize: committed);
  }

  /// Sends an ABORT command and cancels the current subscription.
  Future<void> abort() async {
    await _ctrl.write([_cmdAbort], withoutResponse: true);
    _sub?.cancel();
    _sub = null;
  }

  /// Aborts any ongoing transfer and unsubscribes from notifications.
  Future<void> close() async {
    _sub?.cancel();
    _sub = null;
    try {
      await _ctrl.write([_cmdAbort], withoutResponse: true);
      await _stream.setNotifyValue(false);
    } catch (_) {
      // Best-effort on disconnect.
    }
  }
}
