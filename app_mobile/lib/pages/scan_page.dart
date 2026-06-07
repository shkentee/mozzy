import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/wr_ble_device.dart';
import '../services/wr_ble_scanner.dart';
import 'device_page.dart';

/// SharedPreferences key used to persist / retrieve the last-connected device.
const _kLastDeviceId = 'wr_last_device_id';

/// How long auto-connect waits before giving up and showing the normal list.
const _kAutoConnectTimeout = Duration(seconds: 30);

class ScanPage extends StatefulWidget {
  /// [scannerFactory] is an optional dependency-injection seam used by
  /// widget tests to swap in a fake [WrBleScanner]. Production callers
  /// (main.dart) leave it null and the page constructs a real scanner.
  const ScanPage({super.key, this.scannerFactory});

  final WrBleScanner Function()? scannerFactory;

  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  late final WrBleScanner _scanner =
      widget.scannerFactory?.call() ?? WrBleScanner();
  StreamSubscription<List<ScanResult>>? _sub;
  List<ScanResult> _results = const [];
  String? _error;

  /// Non-null while waiting to auto-connect: the device id we are looking for.
  String? _autoConnectId;

  /// Display name used in the "Auto-connecting to …" indicator.
  String? _autoConnectName;

  Timer? _autoConnectTimer;

  @override
  void initState() {
    super.initState();
    _sub = _scanner.results.listen(
      (rs) {
        setState(() => _results = rs);
        _tryAutoConnect(rs);
      },
      onError: (e) => setState(() => _error = e.toString()),
    );
    _startAutoConnectIfNeeded();
  }

  @override
  void dispose() {
    _autoConnectTimer?.cancel();
    _sub?.cancel();
    _scanner.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Auto-connect logic
  // ---------------------------------------------------------------------------

  Future<void> _startAutoConnectIfNeeded() async {
    final prefs = await SharedPreferences.getInstance();
    final savedId = prefs.getString(_kLastDeviceId);
    if (savedId == null || savedId.isEmpty) {
      await _scan();
      return;
    }

    setState(() {
      _autoConnectId = savedId;
      _autoConnectName = savedId; // will be updated once we see the advert name
    });

    final ok = await _ensurePermissions();
    if (!ok) {
      setState(() {
        _autoConnectId = null;
        _autoConnectName = null;
        _error = 'Bluetooth/location permission denied';
      });
      return;
    }

    try {
      await _scanner.start();
    } catch (e) {
      setState(() {
        _autoConnectId = null;
        _autoConnectName = null;
        _error = 'scan failed: $e';
      });
      return;
    }

    // Give up after [_kAutoConnectTimeout] and fall back to normal scan UI.
    _autoConnectTimer = Timer(_kAutoConnectTimeout, () {
      if (!mounted) return;
      setState(() {
        _autoConnectId = null;
        _autoConnectName = null;
      });
    });
  }

  void _tryAutoConnect(List<ScanResult> results) {
    final targetId = _autoConnectId;
    if (targetId == null) return;

    for (final r in results) {
      if (r.device.remoteId.str == targetId) {
        // Update the display name from the advertisement.
        final advName =
            r.device.platformName.isEmpty ? targetId : r.device.platformName;
        setState(() => _autoConnectName = advName);

        // Cancel the timeout — we found the device; navigate now.
        _autoConnectTimer?.cancel();
        _autoConnectTimer = null;

        // Clear auto-connect state before navigating to avoid a second trigger
        // if the stream fires again while the push is in flight.
        _autoConnectId = null;
        _openResult(r);
        return;
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Manual scan + navigation
  // ---------------------------------------------------------------------------

  Future<void> _scan() async {
    setState(() => _error = null);
    final ok = await _ensurePermissions();
    if (!ok) {
      setState(() => _error = 'Bluetooth/location permission denied');
      return;
    }
    try {
      await _scanner.start();
    } catch (e) {
      setState(() => _error = 'scan failed: $e');
    }
  }

  Future<bool> _ensurePermissions() async {
    final perms = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();
    return perms.values.every((s) => s.isGranted || s.isLimited);
  }

  Future<void> _openResult(ScanResult r) async {
    await _scanner.stop();
    if (!mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => DevicePage(device: WrBleDevice(r.device)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final autoName = _autoConnectName;
    return Scaffold(
      appBar: AppBar(
        title: const Text('mojio'),
        actions: [
          IconButton(
            icon: Icon(_scanner.isScanning ? Icons.stop : Icons.search),
            onPressed: _scan,
            tooltip: 'Scan',
          ),
        ],
      ),
      body: Column(
        children: [
          if (_error != null)
            Container(
              color: Colors.red.shade50,
              padding: const EdgeInsets.all(12),
              child: Text(_error!, style: const TextStyle(color: Colors.red)),
            ),
          if (autoName != null)
            Container(
              color: Colors.blue.shade50,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Auto-connecting to $autoName...',
                      style: const TextStyle(fontStyle: FontStyle.italic),
                    ),
                  ),
                ],
              ),
            ),
          Expanded(
            child: _results.isEmpty
                ? const Center(child: Text('Tap search to scan'))
                : ListView.separated(
                    itemCount: _results.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final r = _results[i];
                      final name = r.device.platformName.isEmpty
                          ? '(unnamed)'
                          : r.device.platformName;
                      return ListTile(
                        title: Text(name),
                        subtitle:
                            Text('${r.device.remoteId.str}  rssi ${r.rssi}'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => _openResult(r),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
