import 'dart:async';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mojio/services/wr_storage_client.dart';

class _MockCharacteristic extends Mock implements BluetoothCharacteristic {}

void main() {
  late _MockCharacteristic mockStream;
  late _MockCharacteristic mockCtrl;
  late StreamController<List<int>> streamCtrl;

  setUp(() {
    mockStream = _MockCharacteristic();
    mockCtrl = _MockCharacteristic();
    streamCtrl = StreamController<List<int>>.broadcast();

    when(() => mockStream.setNotifyValue(true)).thenAnswer((_) async => true);
    when(() => mockStream.setNotifyValue(false)).thenAnswer((_) async => true);
    when(() => mockStream.onValueReceived).thenAnswer((_) => streamCtrl.stream);
    when(() => mockCtrl.write(any(),
            withoutResponse: any(named: 'withoutResponse')))
        .thenAnswer((_) async {});
  });

  tearDown(() async {
    await streamCtrl.close();
  });

  WrStorageSession makeSession() => WrStorageSession.forTest(
        stream: mockStream,
        ctrl: mockCtrl,
      );

  group('listFiles', () {
    test('returns filenames from FILE_ENTRY notifies then END', () async {
      final session = makeSession();
      final future = session.listFiles();

      await Future.microtask(() {}); // let subscription register
      streamCtrl.add([0x01, ...('1700000000.opus'.codeUnits)]);
      streamCtrl.add([0x01, ...('unsynced_ab12_00000.opus'.codeUnits)]);
      streamCtrl.add([0x03]); // END

      final files = await future;
      expect(files, [
        '1700000000.opus',
        'unsynced_ab12_00000.opus',
      ]);
    });

    test('sends LIST command byte 0x00', () async {
      final session = makeSession();
      final future = session.listFiles();
      await Future.microtask(() {});
      streamCtrl.add([0x03]);
      await future;

      final captured = verify(
        () => mockCtrl.write(captureAny(),
            withoutResponse: any(named: 'withoutResponse')),
      ).captured;
      expect(captured.first, [0x00]);
    });

    test('returns empty list when no files before END', () async {
      final session = makeSession();
      final future = session.listFiles();
      await Future.microtask(() {});
      streamCtrl.add([0x03]);
      expect(await future, isEmpty);
    });

    test('throws StateError on ERROR notify', () async {
      final session = makeSession();
      final future = session.listFiles();
      await Future.microtask(() {});
      streamCtrl.add([0xFF]);
      expect(future, throwsA(isA<StateError>()));
    });
  });

  group('fetchFile', () {
    test('concatenates DATA chunks until END', () async {
      final session = makeSession();
      final future = session.fetchFile('1700000000.opus');
      await Future.microtask(() {});

      // Two data chunks of 3 bytes each.
      streamCtrl.add([0x02, 0x01, 0x02, 0x03]);
      streamCtrl.add([0x02, 0x04, 0x05, 0x06]);
      streamCtrl.add([0x03]); // END

      final bytes = await future;
      expect(bytes, [0x01, 0x02, 0x03, 0x04, 0x05, 0x06]);
    });

    test('sends FETCH command with filename bytes', () async {
      final session = makeSession();
      final future = session.fetchFile('test.opus');
      await Future.microtask(() {});
      streamCtrl.add([0x03]);
      await future;

      final captured = verify(
        () => mockCtrl.write(captureAny(),
            withoutResponse: any(named: 'withoutResponse')),
      ).captured;
      expect(captured.first, [
        0x01,
        0x00, 0x00, 0x00, 0x00, // offset = 0
        0x00, 0x00, 0x00, 0x00, // length = 0 means read to EOF
        ...'test.opus'.codeUnits,
      ]);
    });

    test('sends legacy FETCH command when requested', () async {
      final session = makeSession();
      final future = session.fetchFileLegacy('test.opus');
      await Future.microtask(() {});
      streamCtrl.add([0x03]);
      await future;

      final captured = verify(
        () => mockCtrl.write(captureAny(),
            withoutResponse: any(named: 'withoutResponse')),
      ).captured;
      expect(captured.first, [
        0x01,
        ...'test.opus'.codeUnits,
      ]);
    });

    test('reports progress via onProgress callback', () async {
      final session = makeSession();
      final progress = <int>[];
      final future = session.fetchFile(
        'f.opus',
        onProgress: progress.add,
      );
      await Future.microtask(() {});
      streamCtrl.add([0x02, 0xAA, 0xBB]); // 2 bytes
      streamCtrl.add([0x02, 0xCC]); // 1 byte
      streamCtrl.add([0x03]);
      await future;

      expect(progress, [2, 3]);
    });

    test('throws StateError when device sends ERROR', () async {
      final session = makeSession();
      final future = session.fetchFile('missing.opus');
      await Future.microtask(() {});
      streamCtrl.add([0xFF]);
      expect(future, throwsA(isA<StateError>()));
    });
  });

  group('abort', () {
    test('sends ABORT command byte 0xFF', () async {
      final session = makeSession();
      await session.abort();

      final captured = verify(
        () => mockCtrl.write(captureAny(),
            withoutResponse: any(named: 'withoutResponse')),
      ).captured;
      expect(captured.first, [0xFF]);
    });
  });
}
