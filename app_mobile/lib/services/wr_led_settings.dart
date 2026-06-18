import 'package:shared_preferences/shared_preferences.dart';

const kLedEnabledKey = 'wr_led_enabled';
const kLedBrightnessKey = 'wr_led_brightness_pct';
const kLedIntervalKey = 'wr_led_interval_sec';

class WrLedSettings {
  const WrLedSettings({
    required this.enabled,
    required this.brightnessPct,
    required this.intervalSec,
  });

  static const defaults = WrLedSettings(
    enabled: true,
    brightnessPct: 6,
    intervalSec: 4,
  );

  final bool enabled;
  final int brightnessPct;
  final int intervalSec;

  int get modeByte => enabled ? 1 : 0;

  List<int> toPayload() => [
        modeByte,
        brightnessPct.clamp(1, 30),
        intervalSec.clamp(1, 10),
        0,
      ];

  WrLedSettings copyWith({
    bool? enabled,
    int? brightnessPct,
    int? intervalSec,
  }) {
    return WrLedSettings(
      enabled: enabled ?? this.enabled,
      brightnessPct: (brightnessPct ?? this.brightnessPct).clamp(1, 30),
      intervalSec: (intervalSec ?? this.intervalSec).clamp(1, 10),
    );
  }

  static WrLedSettings fromPayload(List<int> payload) {
    if (payload.length < 3) return defaults;
    return WrLedSettings(
      enabled: payload[0] != 0,
      brightnessPct: payload[1].clamp(1, 30),
      intervalSec: payload[2].clamp(1, 10),
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
    );
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kLedEnabledKey, enabled);
    await prefs.setInt(kLedBrightnessKey, brightnessPct.clamp(1, 30));
    await prefs.setInt(kLedIntervalKey, intervalSec.clamp(1, 10));
  }
}
