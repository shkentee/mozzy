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
  _FakePathProvider(this.temporaryPath, {String? supportPath})
      : supportPath = supportPath ?? temporaryPath;

  final String temporaryPath;
  final String supportPath;

  @override
  Future<String?> getTemporaryPath() async => temporaryPath;

  @override
  Future<String?> getApplicationSupportPath() async => supportPath;
}

class _MockUploader extends Mock implements WrDriveUploader {}

class _FakeWiredUsb extends WrWiredUsb {
  _FakeWiredUsb(this.calls)
      : super(channel: const MethodChannel('unused/wired_usb'));

  final List<String> calls;
  int statusReads = 0;

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
  Future<List<WrWiredFile>> listRescueCandidates() async {
    calls.add('listRescueCandidates');
    return const [WrWiredFile(name: 'rec_0003.opus_sd', sizeBytes: 2)];
  }

  @override
  Future<void> setKeepScreenOn(bool enabled) async {
    calls.add(enabled ? 'keepScreenOn' : 'keepScreenOff');
  }

  @override
  Future<void> startQueueAllInBackground() async {
    calls.add('queueAll');
  }

  @override
  Future<WrWiredRescueStatus> getRescueStatus() async {
    calls.add('getRescueStatus');
    statusReads++;
    return WrWiredRescueStatus(
      running: statusReads == 1,
      status: statusReads == 1
          ? 'USB吸出し中: rec_0003.opus_sd'
          : 'USB救出完了: 1件を送信待ちに入れました',
      totalFiles: 1,
      queuedFiles: statusReads == 1 ? 0 : 1,
      totalBytes: 2,
      processedBytes: statusReads == 1 ? 0 : 2,
    );
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

  test('listRescueCandidates parses native USB file maps', () async {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
        (call) async {
      expect(call.method, 'listRescueCandidates');
      return [
        {'name': 'rec_0008.opus_sd', 'size': 647232},
      ];
    });

    final wired = WrWiredUsb(channel: channel);
    final files = await wired.listRescueCandidates();

    expect(files.map((f) => f.name), ['rec_0008.opus_sd']);
    expect(files.single.sizeBytes, 647232);
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
        'listRescueCandidates' => [
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

    expect(calls,
        ['setKeepScreenOn', 'prepareUsb', 'ping', 'listRescueCandidates']);
    expect(find.text('接続OK（mozzy）。未救出 1件見つかりました'), findsOneWidget);
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

  test('fetchAndQueueAll pauses, fetches, queues, and resumes in order',
      () async {
    final tempDir = Directory.systemTemp.createTempSync('wired_usb_test_');
    final supportDir =
        Directory.systemTemp.createTempSync('wired_usb_support_test_');
    PathProviderPlatform.instance =
        _FakePathProvider(tempDir.path, supportPath: supportDir.path);
    final calls = <String>[];

    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
        (call) async {
      calls.add(call.method);
      return switch (call.method) {
        'ping' => 'mozzy',
        'pauseRecording' => 'paused',
        'resumeRecording' => 'resumed',
        'listFiles' => [
            {'name': 'rec_0003.opus_sd', 'size': 2},
          ],
        'fetchFile' => (() {
            final args = Map<Object?, Object?>.from(call.arguments as Map);
            File(args['path']! as String).writeAsBytesSync([8, 9]);
            return 2;
          })(),
        _ => null,
      };
    });

    final queued = await WrWiredUsb(channel: channel).fetchAndQueueAll();

    expect(queued, 1);
    expect(calls, [
      'ping',
      'pauseRecording',
      'listFiles',
      'fetchFile',
      'resumeRecording',
    ]);
    expect(File('${tempDir.path}/rec_0003.opus_sd').existsSync(), isFalse);
    expect(
      File('${supportDir.path}/outbox/rec_0003.opus_sd').readAsBytesSync(),
      [8, 9],
    );
  });

  testWidgets('WiredRescuePage blocks duplicate rescue taps while busy',
      (tester) async {
    final calls = <String>[];
    final wired = _FakeWiredUsb(calls);

    await tester.pumpWidget(
      MaterialApp(
        home: WiredRescuePage(
          wired: wired,
          prepareExclusiveUsb: () async => calls.add('prepareUsb'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.textContaining('未救出だけ吸出して送信待ちに入れる（1件'));
    await tester.pump();
    await tester.tap(find.textContaining('未救出だけ吸出して送信待ちに入れる（1件'),
        warnIfMissed: false);
    await tester.pump();

    expect(calls.where((c) => c == 'queueAll'), hasLength(1));

    await tester.pump(const Duration(seconds: 3));
    await tester.pump();

    expect(
      find.text('USB救出完了: 1件を送信待ちに入れました （0.0MB / 0.0MB）'),
      findsOneWidget,
    );
    expect(calls.where((c) => c == 'queueAll'), hasLength(1));
  });
}
