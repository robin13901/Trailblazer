// Trailblazer Phase 7, Plan 07-07:
// FrameTimingMeter — rolling P90 frame-time meter for the REN-04 stress harness.
//
// Collects Flutter FrameTiming callbacks and computes the 90th-percentile frame
// time over a capped rolling window (~600 frames = 10s @ 60fps).
//
// Design:
//   - Plain Dart class — no Widget dependencies beyond dart:ui FrameTiming.
//     Pure enough to unit-test without a Flutter binding.
//   - Internal addFrameMs(double) bypasses FrameTiming construction so tests
//     can feed synthetic values directly.
//   - P90 definition: sorted[(len * 0.9).floor()]; 0 when empty (avoids
//     divide-by-zero in fps computation).
//   - Pass gate: p90FrameMs > 0 && p90FrameMs <= 33.3 ms (>= 30 fps, REN-04).

import 'dart:ui' show FrameTiming;

/// Rolling P90 frame-time meter.
///
/// Feed production frames via [addTimings] (from
/// `WidgetsBinding.instance.addTimingsCallback`). Drive tests via the
/// internal [addFrameMs] seam.
///
/// Example:
/// ```dart
/// final meter = FrameTimingMeter();
///
/// // Register in initState:
/// WidgetsBinding.instance.addTimingsCallback(meter.addTimings);
///
/// // Read metrics:
/// print(meter.p90FrameMs);  // 16.7
/// print(meter.fps);          // 59.9
/// print(meter.passes);       // true
///
/// // Remove in dispose:
/// WidgetsBinding.instance.removeTimingsCallback(meter.addTimings);
/// ```
class FrameTimingMeter {
  /// Rolling window cap — ~600 frames ≈ 10 s at 60 fps.
  static const int _kCap = 600;

  final List<double> _frames = [];

  /// Appends each [FrameTiming]'s total span to the rolling window and trims
  /// to [_kCap].
  ///
  /// Called by `WidgetsBinding.instance.addTimingsCallback`.
  void addTimings(List<FrameTiming> timings) {
    for (final t in timings) {
      addFrameMs(t.totalSpan.inMicroseconds / 1000.0);
    }
  }

  /// Internal seam for unit tests — appends [ms] directly to the window.
  void addFrameMs(double ms) {
    _frames.add(ms);
    if (_frames.length > _kCap) {
      _frames.removeRange(0, _frames.length - _kCap);
    }
  }

  /// 90th-percentile frame time in milliseconds over the rolling window.
  ///
  /// Returns 0.0 when no frames have been recorded yet.
  double get p90FrameMs {
    if (_frames.isEmpty) return 0;
    final sorted = List<double>.from(_frames)..sort();
    // P90 index: floor(len * 0.9). Clamp to [0, len-1] guards against
    // edge-case rounding (e.g. length==1 → 0.9*1=0.9 → floor=0, which is fine;
    // clamp is a safety net, not the primary logic).
    final idx = (sorted.length * 9 ~/ 10).clamp(0, sorted.length - 1);
    return sorted[idx];
  }

  /// Frames per second derived from [p90FrameMs].
  ///
  /// Returns 0.0 when [p90FrameMs] is 0 (empty window).
  double get fps => p90FrameMs > 0 ? 1000 / p90FrameMs : 0;

  /// Whether the P90 frame time meets the REN-04 gate (>= 30 fps == <= 33.3 ms).
  ///
  /// Returns false when the window is empty.
  bool get passes => p90FrameMs > 0 && p90FrameMs <= 33.3;

  /// Clears all recorded frames.
  void reset() => _frames.clear();
}
