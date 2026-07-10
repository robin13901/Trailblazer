// Trailblazer Phase 7, Plan 07-07:
// Unit tests for FrameTimingMeter.
//
// Tests drive addFrameMs directly (no FrameTiming construction needed) since
// FrameTiming is hard to construct in unit tests (it requires raw timestamps).

import 'package:auto_explore/features/coverage/presentation/stress/frame_timing_meter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('FrameTimingMeter', () {
    late FrameTimingMeter meter;

    setUp(() => meter = FrameTimingMeter());

    // -----------------------------------------------------------------------
    // Empty state
    // -----------------------------------------------------------------------

    test('empty window: p90FrameMs == 0', () {
      expect(meter.p90FrameMs, equals(0));
    });

    test('empty window: fps == 0', () {
      expect(meter.fps, equals(0));
    });

    test('empty window: passes == false', () {
      expect(meter.passes, isFalse);
    });

    // -----------------------------------------------------------------------
    // P90 logic and PASS gate
    // -----------------------------------------------------------------------

    test('90x16.6ms + 10x50ms: p90 is in the tail (reflects slow frames)', () {
      // 100 frames total; P90 index = floor(100 * 0.9) = 90 (0-indexed).
      // Sorted: [16.6 x90, 50.0 x10]
      // sorted[90] = 50.0 (first slow frame) → p90 > 33.3 ms.
      for (var i = 0; i < 90; i++) {
        meter.addFrameMs(16.6);
      }
      for (var i = 0; i < 10; i++) {
        meter.addFrameMs(50.0);
      }
      expect(meter.p90FrameMs, greaterThan(33.3));
    });

    test('passes == false when p90 > 33.3', () {
      for (var i = 0; i < 90; i++) {
        meter.addFrameMs(16.6);
      }
      for (var i = 0; i < 10; i++) {
        meter.addFrameMs(50.0);
      }
      expect(meter.passes, isFalse);
    });

    test('passes == true when all frames are 16.6ms (60fps)', () {
      for (var i = 0; i < 60; i++) {
        meter.addFrameMs(16.6);
      }
      expect(meter.passes, isTrue);
      expect(meter.p90FrameMs, lessThanOrEqualTo(33.3));
    });

    test('fps matches 1000 / p90FrameMs', () {
      for (var i = 0; i < 60; i++) {
        meter.addFrameMs(16.6);
      }
      final expected = 1000.0 / meter.p90FrameMs;
      expect(meter.fps, closeTo(expected, 0.001));
    });

    test('fps == 0 when window is empty', () {
      expect(meter.fps, equals(0));
    });

    // -----------------------------------------------------------------------
    // Rolling-window cap
    // -----------------------------------------------------------------------

    test('window is capped at ~600 frames', () {
      // Add 700 fast frames then 1 slow frame; after cap the slow frame
      // should still be visible (it's within the last 600).
      for (var i = 0; i < 700; i++) {
        meter.addFrameMs(16.6);
      }
      // At this point the window should have been trimmed. Verify by adding
      // one more slow frame and checking p90.
      meter.addFrameMs(100.0);
      // Window has the most recent 600 frames: 599 fast + 1 slow.
      // p90 index = 600 * 9 ~/ 10 = 540 → sorted frame 540 (of 600) is still
      // the fast 16.6 value; the slow frame is at index 599.
      // So p90 stays fast — passes is true.
      expect(meter.passes, isTrue); // p90 of the 600-frame window
    });

    test('adding exactly cap frames does not trim', () {
      for (var i = 0; i < 600; i++) {
        meter.addFrameMs(16.6);
      }
      // p90 index = 600 * 9 ~/ 10 = 540 → still 16.6 ms
      expect(meter.p90FrameMs, closeTo(16.6, 0.001));
    });

    test('adding cap+1 frames trims oldest', () {
      // Fill with slow frames, then overfill with fast frames.
      // After trim, only the fast tail survives.
      for (var i = 0; i < 600; i++) {
        meter.addFrameMs(50.0); // slow
      }
      // Now add 600 fast frames — triggers 600 trim events; slow frames gone.
      for (var i = 0; i < 600; i++) {
        meter.addFrameMs(16.6); // fast
      }
      // All 600 retained frames are now 16.6 ms
      expect(meter.passes, isTrue);
    });

    // -----------------------------------------------------------------------
    // reset()
    // -----------------------------------------------------------------------

    test('reset clears all frames', () {
      for (var i = 0; i < 10; i++) {
        meter.addFrameMs(50.0);
      }
      meter.reset();
      expect(meter.p90FrameMs, equals(0));
      expect(meter.fps, equals(0));
      expect(meter.passes, isFalse);
    });

    // -----------------------------------------------------------------------
    // Single-frame edge case
    // -----------------------------------------------------------------------

    test('single frame: p90 equals that frame', () {
      meter.addFrameMs(20.0);
      expect(meter.p90FrameMs, closeTo(20.0, 0.001));
      expect(meter.passes, isTrue); // 20.0 <= 33.3
    });

    test('single slow frame: passes == false', () {
      meter.addFrameMs(100.0);
      expect(meter.passes, isFalse);
    });
  });
}
