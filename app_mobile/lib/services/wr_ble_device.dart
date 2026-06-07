import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:opus_dart/opus_dart.dart';
import 'package:path_provider/path_provider.dart';

import 'wr_audio_packet.dart';
import 'wr_packet_sink.dart';
import 'wr_storage_client.dart';
import 'wr_uuids.dart';

enum _MicGainProtocol { omiLevel, rawPdmGain }

class _MicGainEndpoint {
  const _MicGainEndpoint(this.characteristic, this.protocol);

  final BluetoothCharacteristic characteristic;
  final _MicGainProtocol protocol;
}

/// Single-connection GATT session against a mojizo device.
///
/// Connects, discovers services, finds the audioCodec characteristic,
/// counts notify packets, and dumps each notify (header + payload) to
/// an append-only file under the application documents directory. The
/// dump is consumed by PC-side tooling for offline Opus decode; this
/// client deliberately avoids running Opus in-app.
class WrBleDevice {
  WrBleDevice(this._device, {WrPacketSink? sink}) : _injectedSink = sink;

  static const List<int> _pdmGainByLevel = [0, 20, 30, 40, 46, 50, 60, 70, 80];

  final BluetoothDevice _device;
  final WrPacketSink? _injectedSink;

  StreamSubscription<List<int>>? _notifySub;
  StreamSubscription<BluetoothConnectionState>? _stateSub;

  List<BluetoothService>? _discoveredServices;

  final _packetCount = StreamController<int>.broadcast();
  final _bytesSaved = StreamController<int>.broadcast();
  final _lostPackets = StreamController<int>.broadcast();
  final _batteryLevel = StreamController<int>.broadcast();
  final _audioLevel = StreamController<double>.broadcast();
  StreamSubscription<List<int>>? _batterySub;
  int _count = 0;
  int _lostCount = 0;
  int? _lastPacketId; // null until at least one valid packet has arrived

  // Live mic-level meter: decode incoming Opus frames and emit a normalised
  // 0..1 level (peak-held over a short window, ~10 Hz).
  SimpleOpusDecoder? _meterDecoder;
  double _meterMax = 0.0;
  int _meterCount = 0;

  WrPacketSink? _sink;
  String? _lastDumpPath;

  // Live audio characteristic (19b10001). Subscribed on demand, not on connect.
  BluetoothCharacteristic? _audioDataChar;
  bool _liveMonitor = false;

  /// Filesystem path of the dump file for the current/most-recent session,
  /// or null if no recording has started. Survives [disconnect] so callers
  /// can auto-upload the just-finished file.
  String? get lastDumpPath => _sink?.file.path ?? _lastDumpPath;

  Stream<int> get packetCount => _packetCount.stream;
  Stream<int> get bytesSaved => _bytesSaved.stream;

  /// Cumulative count of dropped packets inferred from gaps in [packetId].
  /// A uint16 rollover (0xFFFF → 0x0000) is treated as a gap of 1 (the next
  /// expected value) and does NOT count as a loss.
  Stream<int> get lostPackets => _lostPackets.stream;

  /// Battery level in percent (0–100) from the BT Battery Service (0x180F).
  /// Emits on connect (initial READ) and whenever the firmware notifies.
  /// No-op if the firmware does not expose the Battery Service.
  Stream<int> get batteryLevel => _batteryLevel.stream;

  /// Live mic level (0..1), decoded from the incoming Opus stream. Emits at
  /// roughly 10 Hz while audio is flowing; useful as a "is it hearing me?"
  /// meter. Scaled so normal speech reaches a visible level.
  Stream<double> get audioLevel => _audioLevel.stream;
  Stream<BluetoothConnectionState> get state => _device.connectionState;

  String get name {
    final n = _device.platformName;
    return n.isEmpty ? WrUuids.defaultDeviceName : n;
  }

  String get id => _device.remoteId.str;

  Future<void> connect({Duration timeout = const Duration(seconds: 30)}) async {
    // autoConnect: true on Android avoids the GATT_ERROR (0x85 / 133) that
    // otherwise hits first-time connections to never-bonded peripherals.
    // It queues the connection at the OS level and retries until cancel,
    // which is more tolerant of address-type / param mismatches than the
    // direct-connect path. The trade-off is that `connect()` returns as
    // soon as the request is queued — not when the link is actually up —
    // so we have to wait for the connectionState transition before any
    // GATT operation, otherwise discoverServices throws fbp-code 6
    // "device is not connected".
    // autoConnect requires mtu == null at connect time (flutter_blue_plus
    // asserts they are mutually exclusive — the default mtu is 512). We
    // negotiate the larger MTU explicitly once the link is up.
    await _device.connect(timeout: timeout, autoConnect: true, mtu: null);
    await _device.connectionState
        .firstWhere((s) => s == BluetoothConnectionState.connected)
        .timeout(timeout);
    if (Platform.isAndroid) {
      // 247-byte MTU lets Opus audio notifications arrive unfragmented.
      try {
        await _device.requestMtu(247);
      } catch (_) {
        // Non-fatal: fall back to the default 23-byte MTU.
      }
      // High connection priority shortens the connection interval (~15 ms vs
      // ~50 ms balanced), multiplying storage-fetch throughput so the SD
      // backlog drains several times faster.
      try {
        await _device.requestConnectionPriority(
            connectionPriorityRequest: ConnectionPriority.high);
      } catch (_) {
        // Non-fatal: stay at the default balanced interval.
      }
      // Prefer the 2M PHY: doubles the radio bitrate (1→2 Mbps) when both ends
      // support it, ~doubling storage-fetch throughput. No-op if unsupported.
      try {
        await _device.setPreferredPhy(
          txPhy: Phy.le2m.mask,
          rxPhy: Phy.le2m.mask,
          option: PhyCoding.noPreferred,
        );
      } catch (_) {
        // Non-fatal: stay on the 1M PHY.
      }
    }
    final services = await _device.discoverServices();
    _discoveredServices = services;
    final audio = services.firstWhere(
      (s) => s.serviceUuid == Guid(WrUuids.audioService),
      orElse: () =>
          throw StateError('audio service ${WrUuids.audioService} not found'),
    );
    // Audio packets stream on audioData (19b10001, NOTIFY). audioCodec
    // (19b10002) is READ-only and only carries the codec id, so subscribing
    // to it yields zero packets.
    final dataChar = audio.characteristics.firstWhere(
      (c) => c.characteristicUuid == Guid(WrUuids.audioData),
      orElse: () =>
          throw StateError('audioData ${WrUuids.audioData} not found'),
    );
    _audioDataChar = dataChar;
    // Live audio is OFF by default to save power: continuous BLE audio
    // notifications are a major battery drain and the SD-chunk sync doesn't
    // need them. The UI turns it on with setLiveMonitor() when the user wants
    // the mic-level meter. Tests that inject a sink keep the old behaviour.
    if (_injectedSink != null) {
      await setLiveMonitor(true);
    }
    // D7: send current epoch so firmware uses wall-clock filenames.
    await _trySendTimeSync(services);
    // Battery Service: subscribe for level updates (best-effort).
    await _trySubscribeBattery(services);
  }

  /// Subscribes to the BT Battery Service (0x180F) if the firmware exposes it.
  /// Reads the initial value, then listens for NOTIFY updates.
  Future<void> _trySubscribeBattery(List<BluetoothService> services) async {
    try {
      final svc = services.firstWhere(
        (s) => s.serviceUuid == Guid(WrUuids.batteryService),
      );
      final char = svc.characteristics.firstWhere(
        (c) => c.characteristicUuid == Guid(WrUuids.batteryLevel),
      );
      // Initial read so the UI shows a value immediately.
      final raw = await char.read();
      if (raw.isNotEmpty) _batteryLevel.add(raw[0].clamp(0, 100));
      // Subscribe for incremental updates (firmware notifies every 60 s).
      if (char.properties.notify) {
        await char.setNotifyValue(true);
        _batterySub = char.lastValueStream.listen((raw) {
          if (raw.isNotEmpty) _batteryLevel.add(raw[0].clamp(0, 100));
        });
      }
    } catch (_) {
      // Firmware without Battery Service (plain omi builds) — continue.
    }
  }

  /// Whether the live audio stream (mic-level meter + packet dump) is active.
  bool get liveMonitor => _liveMonitor;

  /// Subscribes to / unsubscribes from the live audio characteristic on demand.
  /// OFF by default to save power — continuous BLE audio notifications are a
  /// major battery drain, and the SD-chunk → Drive sync does not need them.
  /// The BLE connection itself stays up either way (SD sync uses it).
  Future<void> setLiveMonitor(bool on) async {
    final c = _audioDataChar;
    if (c == null || on == _liveMonitor) return;
    if (on) {
      _sink ??= _injectedSink ?? await _defaultSink();
      _lastDumpPath = _sink?.file.path;
      await c.setNotifyValue(true);
      _notifySub = c.lastValueStream.listen(_onPacket);
      _liveMonitor = true;
    } else {
      await _notifySub?.cancel();
      _notifySub = null;
      try {
        await c.setNotifyValue(false);
      } catch (_) {
        // Best-effort; link may be dropping.
      }
      _liveMonitor = false;
      if (!_audioLevel.isClosed) _audioLevel.add(0.0);
    }
  }

  /// Writes the current Unix epoch (seconds) to the D7 time-sync characteristic.
  ///
  /// Best-effort: silently skips if the firmware doesn't expose the time-sync
  /// service (bare omi builds, old firmware).
  Future<void> _trySendTimeSync(List<BluetoothService> services) async {
    try {
      final svc = services.firstWhere(
        (s) => s.serviceUuid == Guid(WrUuids.timeSyncService),
      );
      final char = svc.characteristics.firstWhere(
        (c) => c.characteristicUuid == Guid(WrUuids.timeSyncChar),
      );
      final epochSecs = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      await char.write(epochToBytes(epochSecs), withoutResponse: true);
    } catch (_) {
      // Old firmware or service not present — continue without time-sync.
    }
  }

  /// Encodes [epochSecs] as a little-endian 8-byte list (LE64).
  ///
  /// Exposed as a static for unit-testing. The firmware's `wr_time_sync_write()`
  /// expects exactly 8 bytes in little-endian order.
  static List<int> epochToBytes(int epochSecs) {
    final bytes = List<int>.filled(8, 0);
    var v = epochSecs;
    for (var i = 0; i < 8; i++) {
      bytes[i] = v & 0xff;
      v >>= 8;
    }
    return bytes;
  }

  Future<WrPacketSink> _defaultSink() async {
    final dir = await getApplicationDocumentsDirectory();
    final stamp = DateTime.now().toUtc().millisecondsSinceEpoch;
    final file = File('${dir.path}/wr_dumps/$id-$stamp.bin');
    return WrPacketSink(file);
  }

  void _onPacket(List<int> bytes) {
    if (bytes.isEmpty) return;
    // Validate header by attempting a parse — surfaces malformed
    // notifies in the count stream as a debugging aid. We don't keep
    // the parsed payload around; the sink stores raw bytes for PC-side
    // tooling.
    final WrAudioPacket packet;
    try {
      packet = WrAudioPacket.parse(bytes);
    } on ArgumentError {
      return; // drop malformed packet, don't count it
    }

    // Packet-loss detection: compare against the previous packet id.
    // The id is a uint16 that wraps from 0xFFFF back to 0x0000.
    final prev = _lastPacketId;
    if (prev != null) {
      final expected = (prev + 1) & 0xFFFF;
      if (packet.packetId != expected) {
        // Compute gap, accounting for wrap-around.
        final gap = (packet.packetId - expected) & 0xFFFF;
        _lostCount += gap;
        _lostPackets.add(_lostCount);
      }
    }
    _lastPacketId = packet.packetId;

    _count++;
    _packetCount.add(_count);
    final sink = _sink;
    if (sink != null) {
      sink.add(bytes).then((_) => _bytesSaved.add(sink.bytesWritten));
    }
    _updateMeter(packet.payload);
  }

  /// Decodes one Opus frame and folds its RMS into the live level meter,
  /// emitting a peak-held, normalised level every few frames. Best-effort:
  /// any decode hiccup is ignored so the meter never disrupts capture.
  void _updateMeter(List<int> opusFrame) {
    if (opusFrame.isEmpty || _audioLevel.isClosed) return;
    try {
      _meterDecoder ??= SimpleOpusDecoder(sampleRate: 16000, channels: 1);
      final Int16List pcm =
          _meterDecoder!.decode(input: Uint8List.fromList(opusFrame));
      if (pcm.isEmpty) return;
      double sumSq = 0;
      for (final s in pcm) {
        sumSq += (s * s).toDouble();
      }
      final rms = math.sqrt(sumSq / pcm.length);
      if (rms > _meterMax) _meterMax = rms;
      if (++_meterCount >= 8) {
        // Scale so ordinary speech (~rms 2700) fills the bar; clamp to 1.
        final level = (_meterMax / 32767.0 * 12.0).clamp(0.0, 1.0);
        if (!_audioLevel.isClosed) _audioLevel.add(level);
        _meterMax = 0.0;
        _meterCount = 0;
      }
    } catch (_) {
      // Ignore — meter is non-essential.
    }
  }

  /// Opens a [WrStorageSession] against the device's storage GATT service.
  ///
  /// Returns null if the firmware does not expose the storage service (e.g.
  /// plain omi builds). Must be called after [connect].
  Future<WrStorageSession?> openStorageSession() async {
    final svcs = _discoveredServices;
    if (svcs == null) return null;
    return WrStorageSession.fromServices(svcs);
  }

  /// Finds the recording-control characteristic (D9), or null on firmware that
  /// doesn't expose it.
  BluetoothCharacteristic? _recControlChar() {
    final svcs = _discoveredServices;
    if (svcs == null) return null;
    try {
      final svc = svcs
          .firstWhere((s) => s.serviceUuid == Guid(WrUuids.recControlService));
      return svc.characteristics.firstWhere(
          (c) => c.characteristicUuid == Guid(WrUuids.recControlChar));
    } catch (_) {
      return null;
    }
  }

  /// Reads whether the device is currently recording to SD. Returns null if
  /// the firmware doesn't support recording control (older builds).
  Future<bool?> readRecordingState() async {
    final c = _recControlChar();
    if (c == null) return null;
    try {
      final v = await c.read();
      return v.isNotEmpty && v[0] != 0;
    } catch (_) {
      return null;
    }
  }

  /// Turns the device's SD recording on ([on]=true) or off. No-op if the
  /// firmware doesn't expose recording control.
  Future<void> setRecording(bool on) async {
    final c = _recControlChar();
    if (c == null) return;
    await c.write([on ? 1 : 0], withoutResponse: false);
  }

  static int _rawPdmGainToLevel(int rawGain) {
    var best = 0;
    var bestDelta = 1 << 30;
    for (var i = 0; i < _pdmGainByLevel.length; i++) {
      final delta = (rawGain - _pdmGainByLevel[i]).abs();
      if (delta < bestDelta) {
        best = i;
        bestDelta = delta;
      }
    }
    return best;
  }

  /// Finds mic-gain characteristic, supporting both Omi level gain and mojizo
  /// raw PDM gain. Returns null on firmware that doesn't expose either.
  _MicGainEndpoint? _gainEndpoint() {
    final svcs = _discoveredServices;
    if (svcs == null) return null;
    try {
      final svc = svcs
          .firstWhere((s) => s.serviceUuid == Guid(WrUuids.settingsService));
      final c = svc.characteristics
          .firstWhere((c) => c.characteristicUuid == Guid(WrUuids.micGainChar));
      return _MicGainEndpoint(c, _MicGainProtocol.omiLevel);
    } catch (_) {
      // Try mojizo raw PDM gain below.
    }
    try {
      final svc = svcs.firstWhere(
        (s) => s.serviceUuid == Guid(WrUuids.rawGainService),
      );
      final c = svc.characteristics
          .firstWhere((c) => c.characteristicUuid == Guid(WrUuids.rawGainChar));
      return _MicGainEndpoint(c, _MicGainProtocol.rawPdmGain);
    } catch (_) {
      return null;
    }
  }

  /// Reads the current mic gain as UI level 0..8. Returns null if the firmware
  /// doesn't support gain control.
  Future<int?> readMicGainLevel() async {
    final endpoint = _gainEndpoint();
    if (endpoint == null) return null;
    try {
      final v = await endpoint.characteristic.read();
      if (v.isEmpty) return null;
      return switch (endpoint.protocol) {
        _MicGainProtocol.omiLevel => v[0].clamp(0, 8),
        _MicGainProtocol.rawPdmGain => _rawPdmGainToLevel(v[0]),
      };
    } catch (_) {
      return null;
    }
  }

  /// Sets the current mic gain from UI level 0..8. No-op if the firmware
  /// doesn't expose gain control.
  Future<void> setMicGainLevel(int level) async {
    final endpoint = _gainEndpoint();
    if (endpoint == null) return;
    final g = level.clamp(0, 8);
    final raw = switch (endpoint.protocol) {
      _MicGainProtocol.omiLevel => g,
      _MicGainProtocol.rawPdmGain => _pdmGainByLevel[g],
    };
    await endpoint.characteristic.write([raw], withoutResponse: false);
  }

  /// Tells the device to enter deep sleep (powers down; wakes on a button
  /// press). Returns true if the command was sent. No-op on old firmware.
  Future<bool> sleepDevice() async {
    final c = _recControlChar();
    if (c == null) return false;
    await c.write([2], withoutResponse: false);
    return true;
  }

  Future<void> disconnect() async {
    await _notifySub?.cancel();
    _notifySub = null;
    _liveMonitor = false;
    _audioDataChar = null;
    await _batterySub?.cancel();
    _batterySub = null;
    await _stateSub?.cancel();
    _stateSub = null;
    await _sink?.close();
    _sink = null;
    _meterDecoder?.destroy();
    _meterDecoder = null;
    _meterMax = 0.0;
    _meterCount = 0;
    if (_device.isConnected) {
      await _device.disconnect();
    }
  }

  Future<void> dispose() async {
    await disconnect();
    await _packetCount.close();
    await _bytesSaved.close();
    await _lostPackets.close();
    await _batteryLevel.close();
    await _audioLevel.close();
  }
}
