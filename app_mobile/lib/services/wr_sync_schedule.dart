import 'package:shared_preferences/shared_preferences.dart';

/// How the app decides WHEN to pull (drain) the device's recordings to Drive.
///
///  * [continuous]      — keep up in near-real-time while connected.
///  * [scheduledTime]   — once per day at a set time (e.g. 23:00).
///  * [intervalWindow]  — every N minutes, only within a daily time window
///                        (e.g. every 30 min between 09:00 and 18:00).
enum SyncMode { continuous, scheduledTime, intervalWindow, manual }

String syncModeLabelJa(SyncMode m) => switch (m) {
      SyncMode.scheduledTime => '毎日この時刻',
      SyncMode.intervalWindow => '時間帯 × 間隔',
      SyncMode.manual => '手動',
      _ => '常時同期',
    };

/// User-configured auto-pull schedule, persisted in SharedPreferences.
class SyncSchedule {
  const SyncSchedule({
    this.mode = SyncMode.manual,
    this.timeMinutes = 23 * 60, // 23:00
    this.intervalMin = 30,
    this.windowStartMin = 9 * 60, // 09:00
    this.windowEndMin = 18 * 60, // 18:00
  });

  final SyncMode mode;
  final int timeMinutes; // scheduledTime: minutes since midnight
  final int intervalMin; // intervalWindow: every N minutes
  final int windowStartMin; // intervalWindow: window start (min since midnight)
  final int windowEndMin; // intervalWindow: window end (min since midnight)

  static const _kMode = 'wr_sched_mode';
  static const _kTime = 'wr_sched_time';
  static const _kInterval = 'wr_sched_interval';
  static const _kWinStart = 'wr_sched_winstart';
  static const _kWinEnd = 'wr_sched_winend';

  SyncSchedule copyWith({
    SyncMode? mode,
    int? timeMinutes,
    int? intervalMin,
    int? windowStartMin,
    int? windowEndMin,
  }) =>
      SyncSchedule(
        mode: mode ?? this.mode,
        timeMinutes: timeMinutes ?? this.timeMinutes,
        intervalMin: intervalMin ?? this.intervalMin,
        windowStartMin: windowStartMin ?? this.windowStartMin,
        windowEndMin: windowEndMin ?? this.windowEndMin,
      );

  static Future<SyncSchedule> load() async {
    final p = await SharedPreferences.getInstance();
    final mi = (p.getInt(_kMode) ?? SyncMode.manual.index)
        .clamp(0, SyncMode.values.length - 1);
    return SyncSchedule(
      mode: SyncMode.values[mi],
      timeMinutes: p.getInt(_kTime) ?? 23 * 60,
      intervalMin: p.getInt(_kInterval) ?? 30,
      windowStartMin: p.getInt(_kWinStart) ?? 9 * 60,
      windowEndMin: p.getInt(_kWinEnd) ?? 18 * 60,
    );
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(_kMode, mode.index);
    await p.setInt(_kTime, timeMinutes);
    await p.setInt(_kInterval, intervalMin);
    await p.setInt(_kWinStart, windowStartMin);
    await p.setInt(_kWinEnd, windowEndMin);
  }

  static String fmtHm(int minutes) {
    final h = (minutes ~/ 60) % 24;
    final m = minutes % 60;
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
  }

  /// A one-line human description of the active schedule (for the UI).
  String describeJa() => switch (mode) {
        SyncMode.scheduledTime => '毎日 ${fmtHm(timeMinutes)} に自動吸出し',
        SyncMode.intervalWindow =>
          '${fmtHm(windowStartMin)}〜${fmtHm(windowEndMin)} に $intervalMin分おきで吸出し',
        SyncMode.manual => '手動（ボタンで吸出し）',
        _ => '常時（接続中はリアルタイムで吸出し）',
      };

  /// Whether a full drain should start now, given when the last drain finished.
  bool shouldStart(
    DateTime now, {
    DateTime? lastScheduledDate,
    DateTime? lastIntervalRun,
  }) {
    final nowMin = now.hour * 60 + now.minute;
    switch (mode) {
      case SyncMode.continuous:
        return true;
      case SyncMode.scheduledTime:
        final ranToday = lastScheduledDate != null &&
            lastScheduledDate.year == now.year &&
            lastScheduledDate.month == now.month &&
            lastScheduledDate.day == now.day;
        return !ranToday && nowMin >= timeMinutes;
      case SyncMode.intervalWindow:
        final inWindow = windowStartMin <= windowEndMin
            ? (nowMin >= windowStartMin && nowMin <= windowEndMin)
            : (nowMin >= windowStartMin || nowMin <= windowEndMin);
        if (!inWindow) return false;
        if (lastIntervalRun == null) return true;
        return now.difference(lastIntervalRun).inMinutes >= intervalMin;
      case SyncMode.manual:
        return false; // _loop() handles manual separately via _manualTrigger
    }
  }
}
