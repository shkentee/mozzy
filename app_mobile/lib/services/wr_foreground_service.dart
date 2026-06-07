import 'dart:io';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';

// Top-level entry point for the Android Foreground Service isolate.
// Must be annotated @pragma('vm:entry-point') so the release-mode tree
// shaker doesn't remove it. It only needs to register the task handler —
// we use ForegroundTaskEventAction.nothing() so onRepeatEvent never fires.
@pragma('vm:entry-point')
void _wrForegroundEntryPoint() {
  FlutterForegroundTask.setTaskHandler(_WrKeepAliveHandler());
}

class _WrKeepAliveHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp) async {}
}

/// Manages the Android Foreground Service that prevents the OS from killing
/// the process while the BLE session is active.
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
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: false,
        allowWakeLock: true,
      ),
    );
  }

  /// Start the foreground service and show a persistent notification.
  ///
  /// [deviceName] is displayed as the notification sub-text so the user
  /// knows which device is keeping the session open.
  static Future<void> start(String deviceName) async {
    if (!_android) return;
    await FlutterForegroundTask.startService(
      serviceId: 1001,
      notificationTitle: 'Recording active',
      notificationText: deviceName,
      callback: _wrForegroundEntryPoint,
    );
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
