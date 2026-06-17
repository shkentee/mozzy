import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mojio/services/wr_wired_usb.dart';

void main() {
  const channel = MethodChannel('test/wired_usb');
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
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
}
