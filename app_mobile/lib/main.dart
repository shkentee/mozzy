import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'pages/scan_page.dart';
import 'services/wr_foreground_service.dart';
import 'services/wr_opus_decoder.dart';

const _kThemeModeKey = 'wr_theme_mode';

/// App-wide theme mode: dark / light / follow-system. Persisted across launches;
/// defaults to dark (the brand's primary look). Set via [setThemeMode].
final ValueNotifier<ThemeMode> themeModeNotifier =
    ValueNotifier(ThemeMode.dark);

ThemeMode themeModeFromString(String? s) => switch (s) {
      'light' => ThemeMode.light,
      'system' => ThemeMode.system,
      _ => ThemeMode.dark,
    };

String themeModeToString(ThemeMode m) => switch (m) {
      ThemeMode.light => 'light',
      ThemeMode.system => 'system',
      _ => 'dark',
    };

/// 日本語ラベル（設定画面用）。
String themeModeLabelJa(ThemeMode m) => switch (m) {
      ThemeMode.light => 'ライト',
      ThemeMode.system => '本体に合わせる',
      _ => 'ダーク',
    };

Future<void> setThemeMode(ThemeMode m) async {
  themeModeNotifier.value = m;
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_kThemeModeKey, themeModeToString(m));
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  WrForegroundService.init();
  // Load libopus up-front so in-app playback has no first-tap stall. Best
  // effort — the Recordings page also calls ensureInit() lazily.
  try {
    await WrOpusDecoder.ensureInit();
  } catch (_) {
    // Opus unavailable (e.g. unsupported platform) — playback will surface it.
  }
  final prefs = await SharedPreferences.getInstance();
  themeModeNotifier.value =
      themeModeFromString(prefs.getString(_kThemeModeKey));
  runApp(const WrApp());
}

/// mojio palette — the brand's teal→blue gradient accent over a dark "fintech"
/// canvas (or a clean light canvas), rounded cards and pill buttons.
class WrColors {
  // Brand accent (shared by both themes): the mojio green→blue sweep.
  static const green = Color(0xFF16DEAA); // gradient start (logo, green-teal)
  static const blue = Color(0xFF2E8BFF); // gradient end (logo, blue)
  static const teal = green; // legacy alias
  static const mint = green; // legacy alias
  static const danger = Color(0xFFFF6B6B);

  /// mojio brand gradient (green → blue) — for hero elements / the wordmark /
  /// the primary call-to-action, mirroring the logo and the design mockups.
  static const brandGradient = LinearGradient(
    colors: [green, blue],
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
  );

  // Dark theme surfaces.
  static const darkBg = Color(0xFF0A0F1E);
  static const darkSurface = Color(0xFF121A2C);
  static const darkSurfaceHi = Color(0xFF1B2440);
  static const onDark = Colors.white;
  static const onDarkDim = Color(0xFF8B95A7);

  // Light theme surfaces.
  static const lightBg = Color(0xFFF6F8FC);
  static const lightSurface = Colors.white;
  static const lightSurfaceHi = Color(0xFFEDF1F8);
  static const onLight = Color(0xFF1E2A44);
  static const onLightDim = Color(0xFF6B7689);
}

ThemeData _buildTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final bg = dark ? WrColors.darkBg : WrColors.lightBg;
  final surface = dark ? WrColors.darkSurface : WrColors.lightSurface;
  final surfaceHi = dark ? WrColors.darkSurfaceHi : WrColors.lightSurfaceHi;
  final onSurface = dark ? WrColors.onDark : WrColors.onLight;

  final scheme = ColorScheme(
    brightness: brightness,
    primary:
        WrColors.blue, // solid accent; the gradient is used in hero widgets
    onPrimary: Colors.white,
    secondary: WrColors.teal,
    onSecondary: dark ? const Color(0xFF06222B) : Colors.white,
    error: WrColors.danger,
    onError: Colors.white,
    surface: surface,
    onSurface: onSurface,
    surfaceContainerHighest: surfaceHi,
  );

  final base = ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: bg,
    fontFamily: GoogleFonts.notoSansJp().fontFamily,
  );

  return base.copyWith(
    appBarTheme: AppBarTheme(
      backgroundColor: bg,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
      systemOverlayStyle:
          dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
      titleTextStyle: GoogleFonts.notoSansJp(
        color: onSurface,
        fontSize: 20,
        fontWeight: FontWeight.w700,
      ),
      iconTheme: IconThemeData(color: onSurface),
    ),
    cardTheme: CardTheme(
      color: surface,
      surfaceTintColor: Colors.transparent,
      elevation: dark ? 0 : 1,
      shadowColor: dark ? Colors.transparent : Colors.black.withOpacity(0.06),
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: WrColors.blue,
        foregroundColor: Colors.white,
        elevation: 0,
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
        shape: const StadiumBorder(),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: WrColors.blue,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
        shape: const StadiumBorder(),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: WrColors.blue,
        side: const BorderSide(color: WrColors.blue, width: 1.5),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
        shape: const StadiumBorder(),
      ),
    ),
    floatingActionButtonTheme: const FloatingActionButtonThemeData(
      backgroundColor: WrColors.blue,
      foregroundColor: Colors.white,
      elevation: 2,
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) =>
          s.contains(WidgetState.selected) ? WrColors.teal : Colors.grey),
      trackColor: WidgetStateProperty.resolveWith((s) =>
          s.contains(WidgetState.selected)
              ? WrColors.teal.withOpacity(0.35)
              : surfaceHi),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: WrColors.blue,
      linearTrackColor: surfaceHi,
      circularTrackColor: surfaceHi,
    ),
    listTileTheme: const ListTileThemeData(iconColor: WrColors.teal),
    dividerTheme: DividerThemeData(
      color: dark ? const Color(0xFF24304C) : const Color(0xFFE3E8F0),
      thickness: 1,
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: dark ? WrColors.darkSurfaceHi : const Color(0xFF2A3450),
      contentTextStyle: const TextStyle(color: Colors.white),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: surfaceHi,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
    ),
    textTheme: GoogleFonts.notoSansJpTextTheme(base.textTheme).apply(
      bodyColor: onSurface,
      displayColor: onSurface,
    ),
  );
}

class WrApp extends StatelessWidget {
  const WrApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeModeNotifier,
      builder: (context, mode, _) {
        return MaterialApp(
          title: 'mojio',
          debugShowCheckedModeBanner: false,
          theme: _buildTheme(Brightness.light),
          darkTheme: _buildTheme(Brightness.dark),
          themeMode: mode,
          home: const ScanPage(),
        );
      },
    );
  }
}
