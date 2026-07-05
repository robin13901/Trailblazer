import 'package:auto_explore/features/trips/data/tracking_service_providers.dart';
import 'package:auto_explore/features/trips/domain/tracking_service.dart';
import 'package:auto_explore/features/trips/domain/tracking_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Thin Riverpod adapter over [TrackingService].
///
/// [build] wires a stream listener on [TrackingService.stateStream] and
/// fires init() once (fire-and-forget — hydration emits via the stream).
/// The notifier does NOT own the service lifecycle (the service Provider does).
///
/// Plain NotifierProvider — no @Riverpod codegen (STATE.md 01-01 decision).
class TrackingNotifier extends Notifier<TrackingState> {
  late final TrackingService _svc;

  @override
  TrackingState build() {
    _svc = ref.watch(trackingServiceProvider);
    final sub = _svc.stateStream.listen((s) => state = s);
    ref.onDispose(sub.cancel);

    // Fire-and-forget init — hydration flips state via the stream if needed.
    // ignore: discarded_futures
    _svc.init();

    return _svc.currentState;
  }

  /// Start a manual trip (FAB tap).
  Future<void> startManual() => _svc.startManual();

  /// Stop the active trip (FAB stop tap).
  Future<void> stopActive() => _svc.stopActive();
}

/// The singleton Riverpod provider for [TrackingState].
///
/// Wave 3 (Plan 03-06) reads this to wire the FAB and the live-tracking panel.
final trackingStateProvider =
    NotifierProvider<TrackingNotifier, TrackingState>(TrackingNotifier.new);
