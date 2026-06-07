import 'package:flutter_test/flutter_test.dart';
import 'package:mojio/services/wr_audio_packet.dart';

void main() {
  group('WrAudioPacket.parse', () {
    test('decodes packet_id as little-endian uint16', () {
      // packet_id = 0x1234 → bytes 0x34, 0x12
      final pkt = WrAudioPacket.parse([0x34, 0x12, 0x07, 0xAA, 0xBB]);
      expect(pkt.packetId, 0x1234);
      expect(pkt.frameId, 0x07);
      expect(pkt.payload, [0xAA, 0xBB]);
    });

    test('decodes max packet_id (0xFFFF)', () {
      final pkt = WrAudioPacket.parse([0xFF, 0xFF, 0x00, 0x01]);
      expect(pkt.packetId, 0xFFFF);
      expect(pkt.frameId, 0);
      expect(pkt.payload, [0x01]);
    });

    test('decodes zero packet_id and frame_id', () {
      final pkt = WrAudioPacket.parse([0x00, 0x00, 0x00, 0x42]);
      expect(pkt.packetId, 0);
      expect(pkt.frameId, 0);
      expect(pkt.payload, [0x42]);
    });

    test('frame_id wraps at 255 (uint8)', () {
      final pkt = WrAudioPacket.parse([0x00, 0x00, 0xFF, 0x99]);
      expect(pkt.frameId, 0xFF);
    });

    test('boundary: exactly headerSize bytes yields empty payload', () {
      final pkt = WrAudioPacket.parse([0x01, 0x00, 0x05]);
      expect(pkt.packetId, 1);
      expect(pkt.frameId, 5);
      expect(pkt.payload, isEmpty);
    });

    test('payload is unmodifiable', () {
      final pkt = WrAudioPacket.parse([0x00, 0x00, 0x00, 0x01, 0x02]);
      expect(() => pkt.payload.add(0x03), throwsUnsupportedError);
    });

    test('throws ArgumentError when shorter than 3 bytes', () {
      expect(() => WrAudioPacket.parse([]), throwsArgumentError);
      expect(() => WrAudioPacket.parse([0x00]), throwsArgumentError);
      expect(() => WrAudioPacket.parse([0x00, 0x01]), throwsArgumentError);
    });

    test('large opus payload is preserved verbatim', () {
      final payload = List<int>.generate(160, (i) => i & 0xFF);
      final raw = <int>[0x10, 0x00, 0x02, ...payload];
      final pkt = WrAudioPacket.parse(raw);
      expect(pkt.packetId, 0x10);
      expect(pkt.frameId, 0x02);
      expect(pkt.payload.length, 160);
      expect(pkt.payload, payload);
    });

    test('toString is informative', () {
      final pkt = WrAudioPacket.parse([0x05, 0x00, 0x01, 0xAA, 0xBB, 0xCC]);
      expect(pkt.toString(), contains('packetId: 5'));
      expect(pkt.toString(), contains('frameId: 1'));
      expect(pkt.toString(), contains('3B'));
    });
  });
}
