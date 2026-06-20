import 'package:shared_preferences/shared_preferences.dart';

const kLedEnabledKey = 'wr_led_enabled';
const kLedBrightnessKey = 'wr_led_brightness_pct';
const kLedIntervalKey = 'wr_led_interval_sec';
const kLedRecordingColorKey = 'wr_led_recording_color';
const kLedIdleColorKey = 'wr_led_idle_color';

enum WrLedColor {
  green(1, '緑'),
  white(2, '白'),
  blue(3, '青'),
  red(4, '赤'),
  cyan(5, '水色'),
  amber(6, '黄'),
  magenta(7, '紫');

  const WrLedColor(this.id, this.label);

  final int id;
  final String label;

  static WrLedColor fromId(int id, WrLedColor fallback) {
    for (final color in values) {
      if (color.id == id) return color;
    }
    return fallback;
  }
}

class WrLedSettings {
  const WrLedSettings({
    required this.enabled,
    required this.brightnessPct,
    required this.intervalSec,
    required this.recordingColor,
    required this.idleColor,
  });

  static const defaults = WrLedSettings(
    enabled: true,
    brightnessPct: 6,
    intervalSec: 4,
    recordingColor: WrLedColor.white,
    idleColor: WrLedColor.green,
  );

  final bool enabled;
  final int brightnessPct;
  final int intervalSec;
  final WrLedColor recordingColor;
  final WrLedColor idleColor;

  int get modeByte => enabled ? 1 : 0;

  List<int> toPayload() => [
        modeByte,
        brightnessPct.clamp(1, 30),
        intervalSec.clamp(1, 10),
        recordingColor.id,
        idleColor.id,
        0,
      ];

  WrLedSettings copyWith({
    bool? enabled,
    int? brightnessPct,
    int? intervalSec,
    WrLedColor? recordingColor,
    WrLedColor? idleColor,
  }) {
    return WrLedSettings(
      enabled: enabled ?? this.enabled,
      brightnessPct: (brightnessPct ?? this.brightnessPct).clamp(1, 30),
      intervalSec: (intervalSec ?? this.intervalSec).clamp(1, 10),
      recordingColor: recordingColor ?? this.recordingColor,
      idleColor: idleColor ?? this.idleColor,
    );
  }

  static WrLedSettings fromPayload(List<int> payload) {
    if (payload.length < 3) return defaults;
    return WrLedSettings(
      enabled: payload[0] != 0,
      brightnessPct: payload[1].clamp(1, 30),
      intervalSec: payload[2].clamp(1, 10),
      recordingColor: payload.length >= 5
          ? WrLedColor.fromId(payload[3], defaults.recordingColor)
          : defaults.recordingColor,
      idleColor: payload.length >= 5
          ? WrLedColor.fromId(payload[4], defaults.idleColor)
          : defaults.idleColor,
    );
  }

  static Future<WrLedSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    return WrLedSettings(
      enabled: prefs.getBool(kLedEnabledKey) ?? defaults.enabled,
      brightnessPct: (prefs.getInt(kLedBrightnessKey) ?? defaults.brightnessPct)
          .clamp(1, 30),
      intervalSec:
          (prefs.getInt(kLedIntervalKey) ?? defaults.intervalSec).clamp(1, 10),
      recordingColor: WrLedColor.fromId(
        prefs.getInt(kLedRecordingColorKey) ?? defaults.recordingColor.id,
        defaults.recordingColor,
      ),
      idleColor: WrLedColor.fromId(
        prefs.getInt(kLedIdleColorKey) ?? defaults.idleColor.id,
        defaults.idleColor,
      ),
    );
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kLedEnabledKey, enabled);
    await prefs.setInt(kLedBrightnessKey, brightnessPct.clamp(1, 30));
    await prefs.setInt(kLedIntervalKey, intervalSec.clamp(1, 10));
    await prefs.setInt(kLedRecordingColorKey, recordingColor.id);
    await prefs.setInt(kLedIdleColorKey, idleColor.id);
  }
}
