import 'package:auto_explore/core/theme/liquid_glass_settings.dart';
import 'package:flutter/material.dart';
import 'package:liquid_glass_renderer/liquid_glass_renderer.dart' as lg;

/// Circular glass container. Branches on the G1 gate flag just like
/// `GlassPill`:
///
///  - Platform supports blur → `LiquidGlass` + `LiquidGlassLayer`.
///  - Otherwise → [GlassCircleFallback] (tinted circle, no BackdropFilter).
///
/// Used for the `TripFab` (size 60) and `SettingsGlassButton` (size 44).
class GlassCircle extends StatelessWidget {
  const GlassCircle({
    required this.size,
    required this.child,
    super.key,
  });

  /// Diameter of the circle in logical pixels.
  final double size;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    const settings = LiquidGlassSettings.instance;
    final radius = size / 2;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final tint = isDark ? settings.darkGlassTint : settings.lightGlassTint;
    final border = isDark
        ? settings.darkGlassBorder
        : settings.lightGlassBorder;

    if (settings.platformSupportsBlurOverMap) {
      // Guard against 0-dim constraints. `liquid_glass_renderer` calls
      // `Picture.toImageSync(w, h)` during paint; if either dim is 0 that
      // throws "Invalid image dimensions" and crashes the app.
      if (size <= 0) return const SizedBox.shrink();
      return SizedBox(
        width: size,
        height: size,
        child: lg.LiquidGlassLayer(
          settings: lg.LiquidGlassSettings(
            thickness: settings.glassThickness,
            blur: settings.glassBlurSigma,
            saturation: settings.glassSaturation,
          ),
          child: lg.LiquidGlass(
            shape: lg.LiquidRoundedSuperellipse(borderRadius: radius),
            child: SizedBox(
              width: size,
              height: size,
              child: Center(child: child),
            ),
          ),
        ),
      );
    }

    return GlassCircleFallback(
      size: size,
      tint: tint,
      borderColor: border,
      child: child,
    );
  }
}

/// Fallback circular container used when [LiquidGlassSettings.platformSupportsBlurOverMap]
/// is `false`.
///
/// Exposed as a public class so widget tests can locate it without relying on
/// private implementation types.
class GlassCircleFallback extends StatelessWidget {
  const GlassCircleFallback({
    required this.size,
    required this.tint,
    required this.borderColor,
    required this.child,
    super.key,
  });

  final double size;
  final Color tint;
  final Color borderColor;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: tint,
        border: Border.all(color: borderColor, width: 0.5),
        shape: BoxShape.circle,
        boxShadow: const [
          BoxShadow(
            color: Color(0x25000000),
            blurRadius: 12,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Center(child: child),
    );
  }
}
