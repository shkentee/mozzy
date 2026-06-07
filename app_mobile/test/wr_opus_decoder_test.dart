import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mojio/services/wr_opus_decoder.dart';

/// Builds a synthetic raw dump: for each payload, a 3-byte omi header
/// [pidLo, pidHi, frameId=0] followed by the payload bytes. Payloads must
/// start with the fixed TOC byte 0xB0, mirroring the real encoder.
Uint8List buildDump(List<List<int>> payloads,
    {int startPid = 0, int step = 1}) {
  final b = <int>[];
  var pid = startPid;
  for (final p in payloads) {
    b.add(pid & 0xff);
    b.add((pid >> 8) & 0xff);
    b.add(0); // frameId
    b.addAll(p);
    pid = (pid + step) & 0xFFFF;
  }
  return Uint8List.fromList(b);
}

void main() {
  group('WrOpusDecoder.framesFromDump', () {
    test('splits concatenated notifies back into frames', () {
      final payloads = [
        [0xB0, 0x11, 0x22],
        [0xB0, 0x33],
        [0xB0, 0x44, 0x55, 0x66, 0x77],
      ];
      final frames = WrOpusDecoder.framesFromDump(buildDump(payloads));
      expect(frames.map((f) => f.toList()).toList(), payloads);
    });

    test('recovers the final frame (no trailing header)', () {
      final payloads = [
        [0xB0, 1, 2, 3],
        [0xB0, 9],
      ];
      final frames = WrOpusDecoder.framesFromDump(buildDump(payloads));
      expect(frames.length, 2);
      expect(frames.last.toList(), [0xB0, 9]);
    });

    test('tolerates a dropped packet (pid gap)', () {
      // pid jumps 0 -> 2 (one packet lost) -> 3.
      final b = <int>[];
      void pkt(int pid, List<int> p) {
        b
          ..add(pid & 0xff)
          ..add((pid >> 8) & 0xff)
          ..add(0)
          ..addAll(p);
      }

      pkt(0, [0xB0, 0xAA]);
      pkt(2, [0xB0, 0xBB, 0xCC]);
      pkt(3, [0xB0, 0xDD]);
      final frames = WrOpusDecoder.framesFromDump(Uint8List.fromList(b));
      expect(frames.length, 3);
      expect(frames[0].toList(), [0xB0, 0xAA]);
      expect(frames[1].toList(), [0xB0, 0xBB, 0xCC]);
      expect(frames[2].toList(), [0xB0, 0xDD]);
    });

    test('wraps packet id at 0xFFFF', () {
      final frames = WrOpusDecoder.framesFromDump(buildDump([
        [0xB0, 1],
        [0xB0, 2],
      ], startPid: 0xFFFF));
      expect(frames.length, 2);
      expect(frames[0].toList(), [0xB0, 1]);
      expect(frames[1].toList(), [0xB0, 2]);
    });

    test('empty / too-short input yields no frames', () {
      expect(WrOpusDecoder.framesFromDump(Uint8List(0)), isEmpty);
      expect(WrOpusDecoder.framesFromDump(Uint8List.fromList([1, 2])), isEmpty);
    });
  });
}
