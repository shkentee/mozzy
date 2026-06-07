import 'package:flutter/material.dart';

import '../main.dart' show WrColors;

/// The "mojio" wordmark, painted with the brand green→blue gradient via a
/// ShaderMask so it reads as the logo, not flat text.
class MojioWordmark extends StatelessWidget {
  const MojioWordmark({super.key, this.fontSize = 24});

  final double fontSize;

  @override
  Widget build(BuildContext context) {
    return ShaderMask(
      shaderCallback: (rect) => WrColors.brandGradient.createShader(rect),
      blendMode: BlendMode.srcIn,
      child: Text(
        'mojio',
        style: TextStyle(
          fontSize: fontSize,
          fontWeight: FontWeight.w800,
          letterSpacing: -0.5,
          color: Colors.white, // masked by the gradient
        ),
      ),
    );
  }
}

/// A pill button filled with the brand green→blue gradient (the mockup's
/// primary call-to-action style), with a soft glow.
class GradientButton extends StatelessWidget {
  const GradientButton({
    super.key,
    required this.onPressed,
    required this.label,
    this.icon,
  });

  final VoidCallback? onPressed;
  final String label;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: WrColors.brandGradient,
          borderRadius: BorderRadius.circular(30),
          boxShadow: [
            BoxShadow(
              color: WrColors.blue.withOpacity(0.35),
              blurRadius: 18,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(30),
            onTap: onPressed,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 15),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (icon != null) ...[
                    Icon(icon, color: Colors.white, size: 20),
                    const SizedBox(width: 10),
                  ],
                  Text(
                    label,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 15,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Live audio waveform — symmetric gradient bars that rise with the mic level,
/// mirroring the "ライブ録音" visual in the design mockups. Feed it a rolling
/// buffer of recent amplitudes (0..1, newest last).
class WaveformBars extends StatelessWidget {
  const WaveformBars({super.key, required this.levels, this.height = 64});

  final List<double> levels;
  final double height;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(painter: _WavePainter(levels)),
    );
  }
}

class _WavePainter extends CustomPainter {
  _WavePainter(this.levels);

  final List<double> levels;

  @override
  void paint(Canvas canvas, Size size) {
    const barW = 3.0;
    const gap = 4.0;
    const slot = barW + gap;
    final n = (size.width / slot).floor();
    if (n <= 0) return;

    final paint = Paint()
      ..shader = WrColors.brandGradient.createShader(Offset.zero & size)
      ..style = PaintingStyle.fill;

    final cy = size.height / 2;
    for (int i = 0; i < n; i++) {
      // Align the newest sample to the right edge.
      final li = levels.length - n + i;
      final v = (li >= 0 && li < levels.length) ? levels[li] : 0.0;
      final h = (v.clamp(0.0, 1.0)) * size.height;
      final bh = h < 3.0 ? 3.0 : h;
      final x = i * slot;
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(x, cy - bh / 2, barW, bh),
        const Radius.circular(2),
      );
      canvas.drawRRect(rect, paint);
    }
  }

  @override
  bool shouldRepaint(_WavePainter oldDelegate) => true;
}

/// A clear, color-coded volume level meter for gain tuning: green in the safe
/// range, amber as it gets hot, red near clipping. Easier to read precisely
/// than the decorative waveform when setting the mic gain.
class LevelMeter extends StatelessWidget {
  const LevelMeter({super.key, required this.level, this.height = 14});

  final double level; // 0..1
  final double height;

  @override
  Widget build(BuildContext context) {
    final track = Theme.of(context).colorScheme.surfaceContainerHighest;
    final v = level.clamp(0.0, 1.0);
    final color = v > 0.85
        ? WrColors.danger
        : v > 0.6
            ? const Color(0xFFFFC24B)
            : WrColors.green;
    return ClipRRect(
      borderRadius: BorderRadius.circular(height / 2),
      child: Stack(
        children: [
          Container(height: height, width: double.infinity, color: track),
          FractionallySizedBox(
            widthFactor: v,
            child: Container(height: height, color: color),
          ),
        ],
      ),
    );
  }
}

/// A thin progress bar whose fill is the brand green→blue gradient.
class GradientProgressBar extends StatelessWidget {
  const GradientProgressBar({super.key, required this.value, this.height = 8});

  final double value; // 0..1
  final double height;

  @override
  Widget build(BuildContext context) {
    final track = Theme.of(context).colorScheme.surfaceContainerHighest;
    return ClipRRect(
      borderRadius: BorderRadius.circular(height),
      child: Stack(
        children: [
          Container(height: height, width: double.infinity, color: track),
          FractionallySizedBox(
            widthFactor: value.clamp(0.0, 1.0),
            child: Container(
              height: height,
              decoration: const BoxDecoration(gradient: WrColors.brandGradient),
            ),
          ),
        ],
      ),
    );
  }
}
