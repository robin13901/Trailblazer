import 'package:auto_explore/core/theme/liquid_glass_settings.dart';
import 'package:flutter/material.dart';
import 'package:liquid_glass_renderer/liquid_glass_renderer.dart' as lg;

/// Rounded glass "pill" container. Branches on the G1 gate flag:
///
///  - If the platform supports blur over the map view (per the
///    Plan 02-01 spike), render a real `LiquidGlass` wrapped in a
///    `LiquidGlassLayer`.
///  - Otherwise render a semi-transparent tinted container with a hairline
///    border — the documented G1 fallback (no BackdropFilter over map).
///
/// This widget is the shared primitive used by `BottomNavShell`,
/// `FocusAreaPill`, and any other chrome elements that need a "pill" shape.
class GlassPill extends StatelessWidget {
  const GlassPill({
    required this.child,
    this.padding = const EdgeInsets.symmetric(vertical: 12, horizontal: 20),
    this.borderRadius,
    super.key,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  /// Override the pill corner radius. Defaults to
  /// [LiquidGlassSettings.pillBorderRadius].
  final double? borderRadius;

  @override
  Widget build(BuildContext context) {
    const settings = LiquidGlassSettings.instance;
    final radius = borderRadius ?? settings.pillBorderRadius;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final tint = isDark ? settings.darkGlassTint : settings.lightGlassTint;
    final border = isDark
        ? settings.darkGlassBorder
        : settings.lightGlassBorder;

    if (settings.platformSupportsBlurOverMap) {
      return lg.LiquidGlassLayer(
        settings: lg.LiquidGlassSettings(
          thickness: settings.glassThickness,
          blur: settings.glassBlurSigma,
          saturation: settings.glassSaturation,
        ),
        child: lg.LiquidGlass(
          shape: lg.LiquidRoundedSuperellipse(borderRadius: radius),
          child: Padding(padding: padding, child: child),
        ),
      );
    }

    return GlassPillFallback(
      padding: padding,
      borderRadius: radius,
      tint: tint,
      borderColor: border,
      child: child,
    );
  }
}

/// Fallback tinted pill used when [LiquidGlassSettings.platformSupportsBlurOverMap]
/// is `false`.
///
/// Exposed as a public class so that widget tests can find it in the tree
/// without relying on private implementation types.
///
/// Deliberately does NOT use [BackdropFilter] — Flutter issue #185497 (OPEN)
/// means BackdropFilter produces no blur over MapLibre's PlatformView on
/// Android. Fallback uses a solid tint + border instead.
class GlassPillFallback extends StatelessWidget {
  const GlassPillFallback({
    required this.child,
    required this.padding,
    required this.borderRadius,
    required this.tint,
    required this.borderColor,
    super.key,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double borderRadius;
  final Color tint;
  final Color borderColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: tint,
        border: Border.all(color: borderColor, width: 0.5),
        borderRadius: BorderRadius.circular(borderRadius),
        boxShadow: const [
          BoxShadow(
            color: Color(0x25000000),
            blurRadius: 12,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: child,
    );
  }
}
