import 'package:auto_explore/features/map/presentation/widgets/glass_circle.dart';
import 'package:auto_explore/features/trips/domain/tracking_state.dart';
import 'package:auto_explore/features/trips/presentation/providers/tracking_state_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Bottom-right FAB that morphs between Start and Stop variants based on
/// the current [TrackingState].
///
/// - Idle → P2 glass circle with red-dot record icon ("Start trip").
/// - Recording → solid red circle with white square stop icon ("Stop trip").
///
/// Transitions are cross-faded via [AnimatedSwitcher] (~200 ms). Semantics
/// label flips to reflect the action the button will perform.
class TripFab extends ConsumerWidget {
  const TripFab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(trackingStateProvider);
    final onTap = switch (state) {
      TrackingIdle() =>
          () => ref.read(trackingStateProvider.notifier).startManual(),
      TrackingRecording() =>
          () => ref.read(trackingStateProvider.notifier).stopActive(),
    };
    final child = switch (state) {
      TrackingIdle() => const _StartVariant(key: ValueKey('start')),
      TrackingRecording() => const _StopVariant(key: ValueKey('stop')),
    };

    return Semantics(
      button: true,
      label: state is TrackingIdle ? 'Start trip' : 'Stop trip',
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
