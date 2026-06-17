import 'dart:async';
import 'dart:io';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'wr_ble_device.dart';
import 'wr_drive_uploader.dart';
import 'wr_sd_sync.dart';

@pragma('vm:entry-point')
void _wrForegroundEntryPoint() {
  FlutterForegroundTask.setTaskHandler(_WrBackgroundSyncHandler());
}

class _WrBackgroundSyncHandler extends TaskHandler {
  WrBleDevice? _device;
  WrSdSync? _sync;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  bool _starting = false;
  String _deviceName = 'mojizo';
  String _lastText = '待機中';

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    await _update('バックグラウンド同期 待機中');
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    FlutterForegroundTask.updateService(
      notificationTitle: 'Mozzy background sync',
      notificationText: _lastText,
    );
  }

  @override
  void onReceiveData(Object data) {
    if (data is! Map) return;
    final cmd = data['cmd'];
    if (cmd == 'startSync') {
      final id = data['deviceId'];
      final name = data['deviceName'];
      if (id is String && id.isNotEmpty) {
        unawaited(_startSync(
            id, name is String && name.isNotEmpty ? name : 'mojizo'));
      }
    } else if (cmd == 'stopSync') {
      unawaited(_stopSync(updateNotification: true));
    }
  }

  @override
  Future<void> onDestroy(DateTime timestamp) async {
    await _stopSync(updateNotification: false);
  }

  Future<void> _startSync(String deviceId, String deviceName) async {
    if (_starting || _sync != null) return;
    _starting = true;
    _deviceName = deviceName;
    await _update('$_deviceName に再接続中');

    try {
      final ble = WrBleDevice(BluetoothDevice.fromId(deviceId));
      await ble.connect(timeout: const Duration(minutes: 2));

      final sync = WrSdSync(device: ble, uploader: WrDriveUploader());
      _subscriptions.add(sync.events.listen((msg) {
        unawaited(_update('$_deviceName: $msg'));
      }));
      _subscriptions.add(sync.progress.listen((p) {
        final backlog = p.backlogBytes / (1024 * 1024);
        final speed = p.bytesPerSec / 1024;
        final text = p.fetching
            ? '$_deviceName: 吸出し中 ${speed.toStringAsFixed(1)} KB/s'
            : p.caughtUp
                ? '$_deviceName: 最新まで吸出し済み'
                : '$_deviceName: ${backlog.toStringAsFixed(1)}MB 未吸出し';
        unawaited(_update(text));
      }));
      _subscriptions.add(sync.uploadStatus.listen((s) {
        if (s.uploading) {
          unawaited(_update('$_deviceName: Drive送信中 ${s.currentFile ?? ''}'));
        } else if (s.pendingFiles > 0) {
          unawaited(_update('$_deviceName: Drive送信待ち ${s.pendingFiles}件'));
        }
      }));

      sync.start();
      _device = ble;
      _sync = sync;
      await _update('$_deviceName: バックグラウンド同期中');
    } catch (e) {
      await _update('$_deviceName: バックグラウンド同期エラー');
      FlutterForegroundTask.sendDataToMain({
        'type': 'wrBackgroundSyncError',
        'message': e.toString(),
      });
      await _stopSync(updateNotification: false);
    } finally {
      _starting = false;
    }
  }

  Future<void> _stopSync({required bool updateNotification}) async {
    final sync = _sync;
    _sync = null;
    if (sync != null) {
      await sync.dispose();
    }
    for (final sub in _subscriptions) {
      await sub.cancel();
    }
    _subscriptions.clear();
    final device = _device;
    _device = null;
    if (device != null) {
      await device.dispose();
    }
    if (updateNotification) {
      await _update('バックグラウンド同期 停止');
    }
  }

  Future<void> _update(String text) async {
    _lastText = text;
    await FlutterForegroundTask.updateService(
      notificationTitle: 'Mozzy background sync',
      notificationText: text,
    );
    FlutterForegroundTask.sendDataToMain({
      'type': 'wrBackgroundSyncStatus',
      'message': text,
    });
  }
}

/// Manages the Android Foreground Service used for long-running sync work.
///
/// All public methods are no-ops on non-Android platforms — call freely
/// from shared UI code without platform guards at the call site.
class WrForegroundService {
  WrForegroundService._();

  static bool get _android => Platform.isAndroid;

  /// Call once in [main] — before [runApp] — to register the isolate port
  /// used to communicate with the service isolate.
  static void init() {
    if (!_android) return;
    FlutterForegroundTask.initCommunicationPort();
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'wr_recording',
        channelName: 'WR Recording',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(60000),
        autoRunOnBoot: false,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
  }

  /// Start the foreground service and show a persistent notification.
  static Future<void> start(String deviceName) async {
    if (!_android) return;
    await FlutterForegroundTask.startService(
      serviceId: 1001,
      notificationTitle: 'Mozzy background sync',
      notificationText: '$deviceName: 接続中',
      callback: _wrForegroundEntryPoint,
    );
  }

  /// Ask the service isolate to take over BLE SD pull + Drive upload.
  static Future<void> startBackgroundSync({
    required String deviceId,
    required String deviceName,
  }) async {
    if (!_android) return;
    final running = await FlutterForegroundTask.isRunningService;
    if (!running) {
      await start(deviceName);
    }
    FlutterForegroundTask.sendDataToTask({
      'cmd': 'startSync',
      'deviceId': deviceId,
      'deviceName': deviceName,
    });
  }

  /// Stop only the service-owned sync worker. The notification may remain until
  /// [stop] is called, which lets UI reconnect without racing the service start.
  static Future<void> stopBackgroundSync() async {
    if (!_android) return;
    FlutterForegroundTask.sendDataToTask({'cmd': 'stopSync'});
  }

  /// Update the notification sub-text (e.g. to show packet count).
  static Future<void> update(String text) async {
    if (!_android) return;
    await FlutterForegroundTask.updateService(notificationText: text);
  }

  /// Stop the foreground service and dismiss the notification.
  static Future<void> stop() async {
    if (!_android) return;
    await FlutterForegroundTask.stopService();
  }
}
