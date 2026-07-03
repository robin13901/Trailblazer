// SPIKE SCREEN — not wired into router; see docs/G1_SPIKE.md
// Temporary bypass in main.dart during Task 3 checkpoint (NOT committed).

import 'dart:ui' as ui;

import 'package:auto_explore/core/theme/liquid_glass_settings.dart';
import 'package:flutter/material.dart';
import 'package:liquid_glass_renderer/liquid_glass_renderer.dart' as lg;
import 'package:maplibre_gl/maplibre_gl.dart';

/// One-off spike screen for Gate G1. NOT wired into the router.
///
/// Manually navigate to it during the checkpoint (see Task 3 in
/// docs/G1_SPIKE.md). Renders a MapLibreMap (remote demo style) with THREE
/// overlaid glass-candidate widgets so the human tester can compare on real
/// hardware:
///
/// 1. [lg.LiquidGlass] pill (from liquid_glass_renderer)   — label "LiquidGlass"
/// 2. [BackdropFilter] + [ClipRRect] pill                  — label "BackdropFilter"
/// 3. Semi-transparent tinted [Container], NO blur         — label "Fallback (no blur)"
///
/// NOTE: All renderer types are prefixed `lg.` to avoid name collision with
/// our own [LiquidGlassSettings] class exported from
/// `package:auto_explore/core/theme/liquid_glass_settings.dart`.
class SpikeG1Screen extends StatelessWidget {
  const SpikeG1Screen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // MapLibreMap is not const — its internal AnnotationType list prevents it.
          // styleString defaults to MapLibreStyles.demo = demotiles.maplibre.org
          MapLibreMap(
            initialCameraPosition: const CameraPosition(
              target: LatLng(52.52, 13.40), // Berlin
              zoom: 12,
            ),
          ),
          // Column of three candidate overlays over the map.
          const Positioned(
            top: 80,
            left: 20,
            right: 20,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _LiquidGlassCandidate(),
                SizedBox(height: 12),
                _BackdropFilterCandidate(),
                SizedBox(height: 12),
                _FallbackCandidate(),
              ],
            ),
          ),
          // Diagnostic footer.
          Positioned(
            bottom: 32,
            left: 20,
            right: 20,
            child: Container(
              padding: const EdgeInsets.all(12),
              color: Colors.black87,
              child: const Text(
                'G1 spike — compare blur/frost quality across the three overlays.\n'
                'On Android, BackdropFilter is expected to look identical to Fallback '
                '(no blur). If it does, set platformBlurEnabled = false.',
                style: TextStyle(color: Colors.white, fontSize: 12),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LiquidGlassCandidate extends StatelessWidget {
  const _LiquidGlassCandidate();

  @override
  Widget build(BuildContext context) {
    // Use liquid_glass_renderer's LiquidGlass widget with sensible defaults.
    // Reference: pub.dev/packages/liquid_glass_renderer 0.2.0-dev.4 source.
    //
    // NOTE: All renderer types are prefixed `lg.` to avoid colliding with
    // our own `LiquidGlassSettings` class from
    // `package:auto_explore/core/theme/liquid_glass_settings.dart`.
    //
    // Deviation from plan sketch: LiquidRoundedSuperellipse.borderRadius is
    // a plain `double` (28), not `Radius.circular(28)`.
    const settings = LiquidGlassSettings.instance;
    return lg.LiquidGlassLayer(
      settings: lg.LiquidGlassSettings(
        thickness: settings.glassThickness,
        blur: settings.glassBlurSigma,
        saturation: settings.glassSaturation,
      ),
      child: lg.LiquidGlass(
        shape: lg.LiquidRoundedSuperellipse(
          borderRadius: settings.pillBorderRadius,
        ),
        child: const Padding(
          padding: EdgeInsets.symmetric(vertical: 16, horizontal: 20),
          child: Center(
            child: Text(
              'LiquidGlass',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
          ),
        ),
      ),
    );
  }
}

class _BackdropFilterCandidate extends StatelessWidget {
  const _BackdropFilterCandidate();

  @override
  Widget build(BuildContext context) {
    const settings = LiquidGlassSettings.instance;
    return ClipRRect(
      borderRadius: BorderRadius.circular(settings.pillBorderRadius),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(
          sigmaX: settings.glassBlurSigma,
          sigmaY: settings.glassBlurSigma,
        ),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.28),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.50),
              width: 0.5,
            ),
            borderRadius: BorderRadius.circular(settings.pillBorderRadius),
          ),
          child: const Center(
            child: Text(
              'BackdropFilter',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
          ),
        ),
      ),
    );
  }
}

class _FallbackCandidate extends StatelessWidget {
  const _FallbackCandidate();

  @override
  Widget build(BuildContext context) {
    const settings = LiquidGlassSettings.instance;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.28),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.50),
          width: 0.5,
        ),
        borderRadius: BorderRadius.circular(settings.pillBorderRadius),
      ),
      child: const Center(
        child: Text(
          'Fallback (no blur)',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}
