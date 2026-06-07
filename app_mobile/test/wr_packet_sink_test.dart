import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mojio/services/wr_packet_sink.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('wr_sink_test_');
  });

  tearDown(() async {
    if (await tmp.exists()) {
      await tmp.delete(recursive: true);
    }
  });

  group('WrPacketSink', () {
    test('writes raw bytes verbatim and tracks bytesWritten', () async {
      final f = File('${tmp.path}/dump.bin');
      final sink = WrPacketSink(f);

      await sink.add([0x01, 0x00, 0x00, 0xAA, 0xBB]);
      await sink.add([0x02, 0x00, 0x01, 0xCC]);
      await sink.close();

      expect(sink.bytesWritten, 9);
      expect(await f.readAsBytes(),
          [0x01, 0x00, 0x00, 0xAA, 0xBB, 0x02, 0x00, 0x01, 0xCC]);
    });

    test('preserves arrival order across un-awaited adds', () async {
      final f = File('${tmp.path}/order.bin');
      final sink = WrPacketSink(f);

      // Fire-and-forget adds; chain inside sink must serialise them.
      // ignore: unawaited_futures
      sink.add([0xAA]);
      // ignore: unawaited_futures
      sink.add([0xBB]);
      // ignore: unawaited_futures
      sink.add([0xCC]);
      await sink.add([0xDD]);
      await sink.close();

      expect(await f.readAsBytes(), [0xAA, 0xBB, 0xCC, 0xDD]);
    });

    test('creates parent directory lazily', () async {
      final nested = File('${tmp.path}/a/b/c/dump.bin');
      final sink = WrPacketSink(nested);

      expect(await nested.parent.exists(), isFalse);
      await sink.add([0x42]);
      await sink.close();

      expect(await nested.exists(), isTrue);
      expect(await nested.readAsBytes(), [0x42]);
    });

    test('appends to existing file rather than overwriting', () async {
      final f = File('${tmp.path}/append.bin');
      await f.writeAsBytes([0xFF]);

      final sink = WrPacketSink(f);
      await sink.add([0x11, 0x22]);
      await sink.close();

      expect(await f.readAsBytes(), [0xFF, 0x11, 0x22]);
    });

    test('add after close is a no-op (does not throw)', () async {
      final f = File('${tmp.path}/closed.bin');
      final sink = WrPacketSink(f);
      await sink.add([0x01]);
      await sink.close();

      expect(sink.isClosed, isTrue);
      await sink.add([0x02]); // should silently drop
      expect(sink.bytesWritten, 1);
      expect(await f.readAsBytes(), [0x01]);
    });

    test('empty add is ignored', () async {
      final f = File('${tmp.path}/empty.bin');
      final sink = WrPacketSink(f);
      await sink.add([]);
      await sink.close();

      expect(sink.bytesWritten, 0);
      // File never opened, so it shouldn't exist.
      expect(await f.exists(), isFalse);
    });

    test('close is idempotent', () async {
      final f = File('${tmp.path}/idem.bin');
      final sink = WrPacketSink(f);
      await sink.add([0xAB]);
      await sink.close();
      await sink.close(); // must not throw
      expect(sink.isClosed, isTrue);
    });
  });
}
