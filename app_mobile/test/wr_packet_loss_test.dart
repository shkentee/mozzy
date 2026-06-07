import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mojio/services/wr_audio_packet.dart';

// ---------------------------------------------------------------------------
// Minimal WrBleDevice clone for testing _onPacket loss detection logic.
//
// Rather than wire up the real WrBleDevice (which requires BluetoothDevice,
// path_provider, etc.) we test the pure packet-id tracking logic in
// isolation via a thin helper class that reproduces the exact same algorithm.
// ---------------------------------------------------------------------------

/// Reproduces the packet-loss detection logic from WrBleDevice._onPacket.
/// Call [feed] to push raw notify bytes; read [lostCount] afterwards.
class _PacketLossTracker {
  int? _lastPacketId;
  int _lostCount = 0;
  // sync: true so add() delivers events immediately — avoids event-loop
  // timing issues in tests that collect emissions before cancelling.
  final _controller = StreamController<int>.broadcast(sync: true);

  Stream<int> get stream => _controller.stream;
  int get lostCount => _lostCount;

  void feed(List<int> bytes) {
    final WrAudioPacket packet;
    try {
      packet = WrAudioPacket.parse(bytes);
    } on ArgumentError {
      return;
    }
    final prev = _lastPacketId;
    if (prev != null) {
      final expected = (prev + 1) & 0xFFFF;
      if (packet.packetId != expected) {
        final gap = (packet.packetId - expected) & 0xFFFF;
        _lostCount += gap;
        _controller.add(_lostCount);
      }
    }
    _lastPacketId = packet.packetId;
  }

  Future<void> close() => _controller.close();
}

/// Builds a minimal audioCodec notify payload with the given [packetId].
/// frameId = 0, payload = [0xAB] (1 byte of fake Opus data).
List<int> _pkt(int packetId) => [
      packetId & 0xFF,
      (packetId >> 8) & 0xFF,
      0x00, // frameId
      0xAB, // 1-byte fake payload
    ];

void main() {
  group('packet-loss detection', () {
    late _PacketLossTracker tracker;

    setUp(() {
      tracker = _PacketLossTracker();
    });

    tearDown(() async {
      await tracker.close();
    });

    test('no loss when packets arrive in order', () {
      for (var i = 0; i < 10; i++) {
        tracker.feed(_pkt(i));
      }
      expect(tracker.lostCount, 0);
    });

    test('detects a gap of 1 between consecutive packets', () {
      tracker.feed(_pkt(0));
      tracker.feed(_pkt(2)); // id 1 is missing → gap = 1
      expect(tracker.lostCount, 1);
    });

    test('detects a gap of 3 in a single jump', () {
      tracker.feed(_pkt(5));
      tracker.feed(_pkt(9)); // 6, 7, 8 missing → gap = 3
      expect(tracker.lostCount, 3);
    });

    test('accumulates loss over multiple gaps', () {
      tracker.feed(_pkt(0));
      tracker.feed(_pkt(2)); // 1 lost → total 1
      tracker.feed(_pkt(5)); // 3, 4 lost → total 3
      tracker.feed(_pkt(7)); // 6 lost → total 4
      expect(tracker.lostCount, 4);
    });

    test('no loss counted before at least two packets arrive', () {
      tracker.feed(_pkt(42)); // first packet — no previous id to compare
      expect(tracker.lostCount, 0);
    });

    test('uint16 rollover 0xFFFF → 0x0000 is NOT counted as a loss', () {
      tracker.feed(_pkt(0xFFFE));
      tracker.feed(_pkt(0xFFFF));
      tracker.feed(_pkt(0x0000)); // expected next after rollover
      expect(tracker.lostCount, 0);
    });

    test('detects loss immediately after rollover', () {
      tracker.feed(_pkt(0xFFFF));
      tracker.feed(_pkt(0x0002)); // 0x0000 and 0x0001 missing → gap = 2
      expect(tracker.lostCount, 2);
    });

    test('stream emits updated cumulative count on each gap', () async {
      final emitted = <int>[];
      final sub = tracker.stream.listen(emitted.add);

      tracker.feed(_pkt(0));
      tracker.feed(_pkt(2)); // gap 1 → emits 1
      tracker.feed(_pkt(3)); // no gap → no emit
      tracker.feed(_pkt(6)); // gap 2 → emits 3

      await sub.cancel();
      expect(emitted, [1, 3]);
    });

    test('malformed packet (too short) is silently dropped, no loss counted',
        () {
      tracker.feed(_pkt(0));
      tracker.feed([0x01]); // only 1 byte — shorter than 3-byte header
      tracker.feed(_pkt(1)); // id 1 follows id 0 — no gap
      expect(tracker.lostCount, 0);
    });
  });
}
