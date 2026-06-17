import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mojio/pages/wired_rescue_page.dart';
import 'package:mojio/services/wr_drive_uploader.dart';
import 'package:mojio/services/wr_wired_usb.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.temporaryPath);

  final String temporaryPath;

  @override
  Future<String?> getTemporaryPath() async => temporaryPath;
}

class _MockUploader extends Mock implements WrDriveUploader {}

class _FakeWiredUsb extends WrWiredUsb {
  _FakeWiredUsb(this.calls)
      : super(channel: const MethodChannel('unused/wired_usb'));

  final List<String> calls;

  @override
  Future<String> ping() async {
    calls.add('ping');
    return 'mozzy';
  }

  @override
  Future<List<WrWiredFile>> listFiles() async {
    calls.add('listFiles');
    return const [WrWiredFile(name: 'rec_0003.opus_sd', sizeBytes: 2)];
  }

  @override
  Future<int> fetchAndUploadAll({
    required WrDriveUploader uploader,
    void Function(String message)? onProgress,
  }) async {
    calls.add('rescueAll');
    onProgress?.call('Drive送信中: rec_0003.opus_sd');
    await Future<void>.delayed(const Duration(seconds: 1));
    return 1;
  }
}

void main() {
  const channel = MethodChannel('test/wired_usb');
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final originalPathProvider = PathProviderPlatform.instance;

  setUpAll(() {
    registerFallbackValue(File('fallback.opus_sd'));
  });

  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    PathProviderPlatform.instance = originalPathProvider;
  });

  test('listFiles parses native USB file maps', () async {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
        (call) async {
      expect(call.method, 'listFiles');
      return [
        {'name': '1781702641.opus_sd', 'size': 1200366},
        {'name': 'rec_0001.opus_sd', 'size': '42'},
      ];
    });

    final wired = WrWiredUsb(channel: channel);
    final files = await wired.listFiles();

    expect(files.map((f) => f.name), [
      '1781702641.opus_sd',
      'rec_0001.opus_sd',
    ]);
    expect(files.map((f) => f.sizeBytes), [1200366, 42]);
  });

  test('ping returns native response', () async {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
        (call) async {
      expect(call.method, 'ping');
      return 'mozzy';
    });

    final wired = WrWiredUsb(channel: channel);
    expect(await wired.ping(), 'mozzy');
  });

  testWidgets('WiredRescuePage checks USB automatically on open',
      (tester) async {
    final calls = <String>[];
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
        (call) async {
      calls.add(call.method);
      return switch (call.method) {
        'ping' => 'mozzy',
        'listFiles' => [
            {'name': 'rec_0001.opus_sd', 'size': 42},
          ],
        _ => null,
      };
    });

    await tester.pumpWidget(
      MaterialApp(
        home: WiredRescuePage(
          wired: WrWiredUsb(channel: channel),
          prepareExclusiveUsb: () async => calls.add('prepareUsb'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(calls, ['prepareUsb', 'ping', 'listFiles']);
    expect(find.text('接続OK（mozzy）。1件見つかりました'), findsOneWidget);
    expect(find.text('rec_0001.opus_sd'), findsOneWidget);
  });

  test('fetchAndUploadAll pauses, fetches, uploads, and resumes in order',
      () async {
    final tempDir = Directory.systemTemp.createTempSync('wired_usb_test_');
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    final uploader = _MockUploader();
    final calls = <String>[];

    when(() => uploader.uploadIfNew(any(), any())).thenAnswer((_) async {
      calls.add('uploadIfNew');
      return 'drive-id';
    });
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
        (call) async {
      calls.add(call.method);
      return switch (call.method) {
        'ping' => 'mozzy',
        'pauseRecording' => 'paused',
        'resumeRecording' => 'resumed',
        'listFiles' => [
            {'name': 'rec_0001.opus_sd', 'size': 4},
          ],
        'fetchFile' => (() {
            final args = Map<Object?, Object?>.from(call.arguments as Map);
            File(args['path']! as String).writeAsBytesSync([1, 2, 3, 4]);
            return 4;
          })(),
        _ => null,
      };
    });

    final uploaded = await WrWiredUsb(channel: channel)
        .fetchAndUploadAll(uploader: uploader);

    expect(uploaded, 1);
    expect(calls, [
      'ping',
      'pauseRecording',
      'listFiles',
      'fetchFile',
      'uploadIfNew',
      'resumeRecording',
    ]);
    verify(() => uploader.uploadIfNew(any(), 'rec_0001.opus_sd')).called(1);
    expect(File('${tempDir.path}/rec_0001.opus_sd').existsSync(), isFalse);
  });

  test(
      'fetchAndUploadAll resumes recording and cleans temp file on upload error',
      () async {
    final tempDir = Directory.systemTemp.createTempSync('wired_usb_test_');
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    final uploader = _MockUploader();
    final calls = <String>[];

    when(() => uploader.uploadIfNew(any(), any())).thenAnswer((_) async {
      calls.add('uploadIfNew');
      throw StateError('drive down');
    });
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
        (call) async {
      calls.add(call.method);
      return switch (call.method) {
        'ping' => 'mozzy',
        'pauseRecording' => 'paused',
        'resumeRecording' => 'resumed',
        'listFiles' => [
            {'name': 'rec_0002.opus_sd', 'size': 3},
          ],
        'fetchFile' => (() {
            final args = Map<Object?, Object?>.from(call.arguments as Map);
            File(args['path']! as String).writeAsBytesSync([5, 6, 7]);
            return 3;
          })(),
        _ => null,
      };
    });

    await expectLater(
      WrWiredUsb(channel: channel).fetchAndUploadAll(uploader: uploader),
      throwsA(isA<StateError>()),
    );

    expect(calls, [
      'ping',
      'pauseRecording',
      'listFiles',
      'fetchFile',
      'uploadIfNew',
      'resumeRecording',
    ]);
    expect(File('${tempDir.path}/rec_0002.opus_sd').existsSync(), isFalse);
  });

  testWidgets('WiredRescuePage blocks duplicate rescue taps while busy',
      (tester) async {
    final uploader = _MockUploader();
    final calls = <String>[];
    final wired = _FakeWiredUsb(calls);

    await tester.pumpWidget(
      MaterialApp(
        home: WiredRescuePage(
          wired: wired,
          uploader: uploader,
          prepareExclusiveUsb: () async => calls.add('prepareUsb'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.textContaining('Driveへ一括送信（1件'));
    await tester.pump();
    await tester.tap(find.textContaining('Driveへ一括送信（1件'), warnIfMissed: false);
    await tester.pump();

    expect(calls.where((c) => c == 'rescueAll'), hasLength(1));

    await tester.pump(const Duration(seconds: 1));
    await tester.pump();

    expect(find.text('USB救出完了: 1件をDriveへ送信しました'), findsOneWidget);
    expect(calls.where((c) => c == 'rescueAll'), hasLength(1));
  });
}
