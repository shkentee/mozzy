import 'dart:async';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'wr_uuids.dart';

/// Thin wrapper around FlutterBluePlus that scans for mojizo
/// devices and filters results by device name and service UUID.
///
/// Xiaomi/Android can suppress unfiltered BLE advertisements before they
/// reach Dart. Supplying the mojizo/omi-compatible service UUIDs keeps the
/// native scan broad enough for our firmware while avoiding OS-side drops.
class WrBleScanner {
  static const Duration defaultTimeout = Duration(seconds: 12);

  StreamSubscription<List<ScanResult>>? _subscription;
  final _resultsController = StreamController<List<ScanResult>>.broadcast();

  Stream<List<ScanResult>> get results => _resultsController.stream;

  bool get isScanning => FlutterBluePlus.isScanningNow;

  Future<void> start({Duration timeout = defaultTimeout}) async {
    if (FlutterBluePlus.isScanningNow) {
      return;
    }
    _subscription?.cancel();
    _subscription = FlutterBluePlus.scanResults.listen(
      (rs) {
        final filtered = rs.where((r) {
          // platformName is the OS-cached friendly name and stays empty
          // for never-bonded devices on Android. Fall back through every
          // name source flutter_blue_plus exposes so a fresh "mojizo"
          // advertisement still gets matched.
          final candidates = <String>[
            r.device.platformName,
            r.device.advName,
            r.advertisementData.advName,
          ];
          final namesMatch = candidates.any(
            (n) =>
                n == WrUuids.defaultDeviceName ||
                n.toLowerCase().startsWith('mojizo') ||
                n.startsWith('Omi') ||
                n.startsWith('Friend'),
          );
          if (namesMatch) return true;

          final services =
              r.advertisementData.serviceUuids.map((u) => u.str.toLowerCase());
          return services.contains(WrUuids.audioService) ||
              services.contains(WrUuids.storageService) ||
              services.contains(WrUuids.settingsService) ||
              services.contains(WrUuids.dfuService);
        }).toList();
        _resultsController.add(filtered);
      },
      onError: (e) => _resultsController.addError(e),
    );
    await FlutterBluePlus.startScan(
      timeout: timeout,
      withServices: [
        // Firmware advertises the standard Battery Service in the advertising
        // packet; the custom services are discovered after connection.
        Guid(WrUuids.batteryService),
      ],
      androidUsesFineLocation: true,
    );
  }

  Future<void> stop() async {
    if (FlutterBluePlus.isScanningNow) {
      await FlutterBluePlus.stopScan();
    }
    await _subscription?.cancel();
    _subscription = null;
  }

  Future<void> dispose() async {
    await stop();
    await _resultsController.close();
  }
}
