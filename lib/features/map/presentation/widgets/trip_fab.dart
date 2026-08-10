import 'dart:async';

import 'package:auto_explore/features/coverage/data/coverage_overlay_providers.dart';
import 'package:auto_explore/features/map/presentation/widgets/glass_circle.dart';
import 'package:auto_explore/features/trips/domain/tracking_state.dart';
import 'package:auto_explore/features/trips/presentation/providers/inbox_providers.dart';
import 'package:auto_explore/features/trips/presentation/providers/tracking_state_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Bottom-right FAB that morphs between Start, Stop, and post-stop "finishing"
/// variants based on the current [TrackingState].
///
/// - Idle → P2 glass circle with red-dot record icon ("Start trip").
/// - Recording → solid red circle with white square stop icon ("Stop trip").
/// - Finishing (just after Stop, until the coverage line is drawn) → the idle
///   liquid-glass circle but with a centered [CircularProgressIndicator] spinner
///   instead of the record icon. This gives the user immediate feedback that
///   their drive is being matched + rendered (#6, 2026-07-25).
///
/// The finishing state ends once matching for the just-ended trip has completed
/// AND the coverage overlay has emitted (the line is on the map). Readiness is
/// derived from [inFlightCountProvider] (pending + pendingRoadData count) with a
/// "saw-in-flight" latch to bridge the brief race between the Stop tap and the
/// trip reaching a matching state, plus [coverageOverlayDataProvider] having
/// resolved to data.
///
/// Transitions are cross-faded via [AnimatedSwitcher] (~200 ms).
class TripFab extends ConsumerStatefulWidget {
  const TripFab({super.key});

  @override
  ConsumerState<TripFab> createState() => _TripFabState();
}

class _TripFabState extends ConsumerState<TripFab> {
  /// True from the moment Stop is tapped until the coverage line for the ended
  /// trip is drawn (matching done + overlay emitted).
  bool _finishing = false;

  /// Latch: set once we observe matching actually in flight after a Stop, so a
  /// transient `inFlightCount == 0` in the brief race window right after the tap
  /// does not clear [_finishing] prematurely.
  bool _sawInFlight = false;

  void _onStart() {
    unawaited(ref.read(trackingStateProvider.notifier).startManual());
  }

  void _onStop() {
    setState(() {
      _finishing = true;
      _sawInFlight = false;
    });
    unawaited(ref.read(trackingStateProvider.notifier).stopActive());
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(trackingStateProvider);

    // While recording, a previous finishing session is irrelevant — reset it.
    if (state is TrackingRecording && _finishing) {
      // Defer the state mutation out of build.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _finishing) {
          setState(() {
            _finishing = false;
            _sawInFlight = false;
          });
        }
      });
    }

    // Evaluate finishing readiness only while idle + finishing.
    if (_finishing && state is TrackingIdle) {
      final inFlight = ref.watch(inFlightCountProvider).value ?? 0;
      final overlayReady = ref.watch(coverageOverlayDataProvider).hasValue;

      if (inFlight > 0) {
        // Matching is running — remember we saw it so a later 0 means "done".
        if (!_sawInFlight) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _finishing) setState(() => _sawInFlight = true);
          });
        }
      } else if (_sawInFlight && overlayReady) {
        // Matching finished (count dropped back to 0) and the overlay has
        // emitted → the line is drawn. Clear the spinner.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            setState(() {
              _finishing = false;
              _sawInFlight = false;
            });
          }
        });
      }
      // else: race window (count still 0, matching not yet observed) → keep the
      // spinner until matching starts.
    }

    final showFinishing = _finishing && state is TrackingIdle;

    final onTap = switch (state) {
      _ when showFinishing => null, // ignore taps while finishing
      TrackingIdle() => _onStart,
      TrackingRecording() => _onStop,
    };

    final child = switch (state) {
      _ when showFinishing => const _FinishingVariant(
        key: ValueKey('finishing'),
      ),
      TrackingIdle() => const _StartVariant(key: ValueKey('start')),
      TrackingRecording() => const _StopVariant(key: ValueKey('stop')),
    };

    final label = switch (state) {
      _ when showFinishing => 'Fahrt wird abgeglichen',
      TrackingIdle() => 'Fahrt starten',
      TrackingRecording() => 'Fahrt beenden',
    };

    return Semantics(
      button: true,
      label: label,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          child: child,
        ),
      ),
    );
  }
}

/// P2 glass circle with a red-dot record icon — the idle FAB look preserved
/// from Phase 2 (STATE.md 02-05: GlassCircle 64 dp, red record icon).
class _StartVariant extends StatelessWidget {
  const _StartVariant({super.key});

  @override
  Widget build(BuildContext context) {
    return const GlassCircle(
      size: 64,
      overMap: true,
      child: Icon(Icons.fiber_manual_record, size: 30),
    );
  }
}

/// Solid red circle with a white square stop icon — emergency-action
/// affordance (no LiquidGlass wrapper per CONTEXT.md + RESEARCH.md decision).
class _StopVariant extends StatelessWidget {
  const _StopVariant({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 64,
      height: 64,
      decoration: const BoxDecoration(
        color: Color(0xFFD32F2F), // Material red 700
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: Color(0x33000000),
            blurRadius: 8,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: const Center(
        child: Icon(Icons.stop, color: Colors.white, size: 28),
      ),
    );
  }
}

/// Idle-style glass circle with a centered spinner — shown from the Stop tap
/// until the ended trip's coverage line is drawn (#6).
class _FinishingVariant extends StatelessWidget {
  const _FinishingVariant({super.key});

  @override
  Widget build(BuildContext context) {
    return const GlassCircle(
      size: 64,
      overMap: true,
      child: SizedBox(
        width: 26,
        height: 26,
        child: CircularProgressIndicator(strokeWidth: 2.5),
      ),
    );
  }
}
