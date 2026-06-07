import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mojio/pages/scan_page.dart';
import 'package:mojio/services/wr_ble_scanner.dart';

/// Mocktail mock of our thin BLE scanner wrapper. We mock the wrapper
/// rather than [FlutterBluePlus] / [BluetoothDevice] directly so the
/// test never touches platform channels.
class _MockScanner extends Mock implements WrBleScanner {}

ScanResult _result(String id, String name, int rssi) {
  // ScanResult is a plain Dart value type in flutter_blue_plus 1.x —
  // safe to construct directly in tests, no platform calls involved.
  return ScanResult(
    device: BluetoothDevice.fromId(id),
    advertisementData: AdvertisementData(
      advName: name,
      txPowerLevel: null,
      appearance: null,
      connectable: true,
      manufacturerData: const {},
      serviceData: const {},
      serviceUuids: const [],
    ),
    rssi: rssi,
    timeStamp: DateTime.utc(2026, 1, 1),
  );
}

void main() {
  late _MockScanner scanner;
  late StreamController<List<ScanResult>> controller;

  setUp(() {
    // Stub SharedPreferences so _startAutoConnectIfNeeded() resolves with no
    // saved address and never touches the real platform channel.
    SharedPreferences.setMockInitialValues({});
    scanner = _MockScanner();
    controller = StreamController<List<ScanResult>>.broadcast();
    when(() => scanner.results).thenAnswer((_) => controller.stream);
    when(() => scanner.isScanning).thenReturn(false);
    when(() => scanner.dispose()).thenAnswer((_) async {});
    when(() => scanner.stop()).thenAnswer((_) async {});
  });

  tearDown(() async {
    await controller.close();
  });

  Widget hostedScanPage() {
    return MaterialApp(
      home: ScanPage(scannerFactory: () => scanner),
    );
  }

  testWidgets('initial state shows the empty-state hint', (tester) async {
    await tester.pumpWidget(hostedScanPage());
    expect(find.text('Tap search to scan'), findsOneWidget);
    expect(find.byType(ListTile), findsNothing);
  });

  testWidgets('renders one ListTile per ScanResult emitted on the stream',
      (tester) async {
    await tester.pumpWidget(hostedScanPage());

    controller.add([
      _result('aa:bb:cc:dd:ee:01', 'Omi DK1', -42),
      _result('aa:bb:cc:dd:ee:02', 'Other', -78),
    ]);
    await tester.pump(); // flush stream listener + setState

    expect(find.byType(ListTile), findsNWidgets(2));
    // BluetoothDevice.platformName always reports '' for devices we
    // never connected to (it reads from an internal cache populated by
    // real connection events), so the page falls back to '(unnamed)'
    // for both tiles regardless of the advertised name.
    expect(find.text('(unnamed)'), findsNWidgets(2));
    // Subtitle includes the remote id and the rssi — the way we tell
    // the two tiles apart in the test.
    expect(find.textContaining('aa:bb:cc:dd:ee:01'), findsOneWidget);
    expect(find.textContaining('aa:bb:cc:dd:ee:02'), findsOneWidget);
    expect(find.textContaining('rssi -42'), findsOneWidget);
    expect(find.textContaining('rssi -78'), findsOneWidget);

    // Empty-state hint is gone once results arrive.
    expect(find.text('Tap search to scan'), findsNothing);
  });

  testWidgets('renders a red error banner when the scan stream errors',
      (tester) async {
    await tester.pumpWidget(hostedScanPage());

    controller.addError(StateError('bluetooth off'));
    await tester.pump();

    expect(find.textContaining('bluetooth off'), findsOneWidget);
  });

  testWidgets(
      'updates the list when a second batch of results replaces the first',
      (tester) async {
    await tester.pumpWidget(hostedScanPage());

    controller.add([_result('aa:bb:cc:dd:ee:01', 'Omi DK1', -42)]);
    await tester.pump();
    expect(find.byType(ListTile), findsOneWidget);

    controller.add([
      _result('aa:bb:cc:dd:ee:01', 'Omi DK1', -42),
      _result('aa:bb:cc:dd:ee:02', 'Other', -55),
      _result('aa:bb:cc:dd:ee:03', 'Third', -90),
    ]);
    await tester.pump();
    expect(find.byType(ListTile), findsNWidgets(3));
  });
}
