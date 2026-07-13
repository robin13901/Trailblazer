// Trailblazer Phase 7, Plan 07-07:
// REN-04 stress verification screen — debug-only.
//
// Loads 50,000 synthetic CoverageWays through the SAME production
// CoverageOverlayApplier path (07-04), measures P90 frame time via Flutter's
// WidgetsBinding.addTimingsCallback, and displays derived fps against the
// >= 30 fps gate (33.3 ms threshold).
//
// Architecture:
//   - ConsumerStatefulWidget (needs ref.read(coverageOverlayApplierProvider)).
//   - Positioned.fill MapWidget — inherits MAPTILER_KEY from env.
//     Map is blank without --dart-define-from-file=env/dev.json (expected).
//   - onStyleLoaded fires the 50k load (once, guarded by _loaded flag):
//       1. await buildSyntheticFeatureCollection(50000) on a compute isolate.
//       2. Construct CoverageOverlayData from syntheticCoverageWays.
//       3. Call coverageOverlayApplierProvider.apply(..., preset: amber).
//   - addTimingsCallback / removeTimingsCallback in initState / dispose.
//   - Banner overlay: loaded count, P90 ms, fps, PASS/FAIL.
//
// Intentionally no unit test — live MapLibre + FrameTiming = device territory.
// The actual on-device 50k fps read is a deferred manual checkpoint (see SUMMARY).
//
// IMPORTANT: This file must only be imported inside a `if (kDebugMode)` guard
// in app_router.dart. The `kDebugMode` const causes the Dart tree-shaker to
// eliminate this import (and all transitive deps) from release builds.

import 'dart:ui' as ui;

import 'package:auto_explore/features/coverage/data/coverage_overlay_data.dart';
import 'package:auto_explore/features/coverage/domain/coverage_color_preset.dart';
import 'package:auto_explore/features/coverage/presentation/coverage_overlay_layers.dart';
import 'package:auto_explore/features/coverage/presentation/stress/frame_timing_meter.dart';
import 'package:auto_explore/features/coverage/presentation/stress/synthetic_coverage_generator.dart';
import 'package:auto_explore/features/map/presentation/widgets/map_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

/// Debug-only screen that loads 50k synthetic driven ways through the
/// production coverage overlay and measures P90 frame time.
///
/// Registered only in debug builds — see `app_router.dart` `kDebugMode` block.
class StressCoverageScreen extends ConsumerStatefulWidget {
  const StressCoverageScreen({super.key});

  @override
  ConsumerState<StressCoverageScreen> createState() =>
      _StressCoverageScreenState();
}

class _StressCoverageScreenState extends ConsumerState<StressCoverageScreen> {
  final FrameTimingMeter _meter = FrameTimingMeter();

  MapLibreMapController? _controller;

  /// Guard: heavy load runs exactly once per screen lifecycle.
  bool _loaded = false;

  /// Count of features successfully applied (non-null after apply).
  int? _featureCount;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addTimingsCallback(_onFrameTimings);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeTimingsCallback(_onFrameTimings);
    super.dispose();
  }

  void _onFrameTimings(List<ui.FrameTiming> timings) {
    _meter.addTimings(timings);
    if (mounted) setState(() {});
  }

  Future<void> _onStyleLoaded() async {
    if (_loaded) return;
    _loaded = true;

    final controller = _controller;
    if (controller == null) return;

    // Build the FeatureCollection on a compute isolate (Pitfall 4).
    final fc = await buildSyntheticFeatureCollection(50000);

    // Also build the CoverageWay list for CoverageOverlayData construction.
    // syntheticCoverageWays with the default seed is fast here since
    // buildSyntheticFeatureCollection already ran it in the isolate.
    // We run it again on the UI isolate only for the data wrapper — the
    // FeatureCollection (the expensive part) is already off-isolate above.
    final ways = syntheticCoverageWays();

    final data = CoverageOverlayData(ways);
    final brightness = ui.PlatformDispatcher.instance.platformBrightness;

    // Apply through the PRODUCTION applier — this is the whole point of the
    // stress test: validate the real render path, not a bespoke one.
    await ref.read(coverageOverlayApplierProvider).apply(
          controller,
          data: data,
          preset: CoverageColorPreset.amber,
          brightness: brightness,
        );

    if (mounted) {
      setState(() {
        _featureCount = (fc['features'] as List<dynamic>?)?.length ?? 0;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final p90 = _meter.p90FrameMs;
    final fps = _meter.fps;
    final passes = _meter.passes;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Abdeckung Stresstest'),
        backgroundColor: Colors.black87,
        foregroundColor: Colors.white,
      ),
      body: Stack(
        children: [
          // Production MapWidget — inherits MAPTILER_KEY from dart-define env.
          // Without the key the map is blank (expected; debug-only tool).
          Positioned.fill(
            child: MapWidget(
              onMapCreated: (controller) {
                _controller = controller;
              },
              onStyleLoaded: _onStyleLoaded,
            ),
          ),
          // Banner overlay — shows metrics at top of screen.
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: _BannerOverlay(
              featureCount: _featureCount,
              p90Ms: p90,
              fps: fps,
              passes: passes,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Banner overlay widget
// ---------------------------------------------------------------------------

class _BannerOverlay extends StatelessWidget {
  const _BannerOverlay({
    required this.featureCount,
    required this.p90Ms,
    required this.fps,
    required this.passes,
  });

  final int? featureCount;
  final double p90Ms;
  final double fps;
  final bool passes;

  @override
  Widget build(BuildContext context) {
    final passLabel = p90Ms == 0
        ? 'MEASURING...'
        : passes
            ? 'PASS'
            : 'FAIL';
    final passColor = p90Ms == 0
        ? Colors.grey
        : passes
            ? Colors.green
            : Colors.red;

    return Container(
      color: Colors.black.withValues(alpha: 0.75),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Geladen: ${featureCount == null ? '---' : '$featureCount Features'}',
            style: const TextStyle(color: Colors.white, fontSize: 12),
          ),
          const SizedBox(height: 2),
          Row(
            children: [
              Expanded(
                child: Text(
                  'P90: ${p90Ms == 0 ? '---' : '${p90Ms.toStringAsFixed(1)} ms'}  '
                  'FPS: ${fps == 0 ? '---' : fps.toStringAsFixed(1)}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              Text(
                passLabel,
                style: TextStyle(
                  color: passColor,
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          const Text(
            'Zum Testen 10 s schwenken / zoomen; P90 / fps oben ablesen.',
            style: TextStyle(color: Colors.white70, fontSize: 11),
          ),
        ],
      ),
    );
  }
}
