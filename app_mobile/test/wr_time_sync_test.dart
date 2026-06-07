import 'package:flutter_test/flutter_test.dart';
import 'package:mojio/services/wr_ble_device.dart';
import 'package:mojio/services/wr_uuids.dart';

void main() {
  group('WrUuids time-sync constants', () {
    const expectedUuid = '19b10005-e8f2-537e-4f6c-d104768a1214';

    test('timeSyncService matches firmware UUID', () {
      expect(WrUuids.timeSyncService, expectedUuid);
    });

    test('timeSyncChar matches firmware UUID', () {
      expect(WrUuids.timeSyncChar, expectedUuid);
    });

    test('timeSyncService == timeSyncChar (single-characteristic service)', () {
      expect(WrUuids.timeSyncService, WrUuids.timeSyncChar);
    });

    test('epochToBytes encodes bsim test epoch as expected LE64', () {
      // Firmware bsim test uses WR_LINK_TIME_SYNC_EPOCH = 0x0102030405060708ULL.
      // LE64: least-significant byte first → [0x08, 0x07, …, 0x01].
      expect(
        WrBleDevice.epochToBytes(0x0102030405060708),
        [0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01],
      );
    });
  });

  group('WrBleDevice.epochToBytes', () {
    test('encodes 0 as 8 zero bytes', () {
      expect(WrBleDevice.epochToBytes(0), List.filled(8, 0));
    });

    test('encodes 1 as little-endian [1, 0, …, 0]', () {
      expect(WrBleDevice.epochToBytes(1), [1, 0, 0, 0, 0, 0, 0, 0]);
    });

    test('encodes 256 (0x100) into byte 1', () {
      expect(WrBleDevice.epochToBytes(256), [0, 1, 0, 0, 0, 0, 0, 0]);
    });

    test('encodes 0x01020304 correctly', () {
      // 0x01020304 = 16909060
      // LE bytes: [0x04, 0x03, 0x02, 0x01, 0x00, 0x00, 0x00, 0x00]
      expect(
        WrBleDevice.epochToBytes(0x01020304),
        [0x04, 0x03, 0x02, 0x01, 0x00, 0x00, 0x00, 0x00],
      );
    });

    test('encodes 2^32 (0x100000000) into byte 4', () {
      expect(
        WrBleDevice.epochToBytes(0x100000000),
        [0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00],
      );
    });

    test('always produces exactly 8 bytes', () {
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      expect(WrBleDevice.epochToBytes(now).length, 8);
    });
  });
}
