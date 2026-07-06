// Immutable snapshot of every private observability field on TrackingService.
// Consumed by the debug HUD (kDebugMode-only) at ~2 Hz.
//
// Do NOT expose FGB or Drift types through this DTO — it must stay
// domain-pure so the HUD can render on any platform without native deps.
// The one type this DTO does reference — [FgbState] — is already the
// facade's public shape; it carries only two bools (enabled + isMoving)
// and no FGB import leaks through it.

import 'package:auto_explore/features/trips/data/background_geolocation_facade.dart'
    show FgbState;

/// Outcome of the most recent `BackgroundGeolocationFacade.ready` invocation.
///
/// Starts as [FacadeReadyPending] before the first call; transitions to
/// [FacadeReadySuccess] on completion, or [FacadeReadyFailed] with the
/// stringified error if the call throws.
sealed class FacadeReadyOutcome {
  const FacadeReadyOutcome();
}

final class FacadeReadyPending extends FacadeReadyOutcome {
  const FacadeReadyPending();
}

final class FacadeReadySuccess extends FacadeReadyOutcome {
  const FacadeReadySuccess();
}

final class FacadeReadyFailed extends FacadeReadyOutcome {
  const FacadeReadyFailed(this.message);
  final String message;
}

/// Minimal projection of the last accepted GPS fix, safe to render in the HUD
/// without dragging Drift / FGB types through the domain layer.
class LastFixSample {
  const LastFixSample({
    required this.ts,
    required this.lat,
    required this.lon,
    required this.accuracyMeters,
    required this.speedKmh,
  });

  final DateTime ts;
  final double lat;
  final double lon;
  final double accuracyMeters;
  final double speedKmh;
}

/// Read-only snapshot of every observability field the debug HUD needs.
///
/// Constructed fresh on each call to `TrackingService.diagnostics`; the HUD
/// polls at ~2 Hz via a `Timer.periodic` inside a `ConsumerStatefulWidget`.
///
/// See `.planning/phases/03-1-tracking-fixes/03-1-RESEARCH.md` §7 for the
/// full data-source mapping and the rationale for pushing counters onto
/// TrackingService (not TripFixIngestor).
class TrackingDiagnostics {
  const TrackingDiagnostics({
    required this.facadeReadyOutcome,
    required this.facadeCurrentState,
    required this.lastAcceptedFix,
    required this.lastRejectedReason,
    required this.lastRejectedAt,
    required this.lastActivityType,
    required this.lastActivityAt,
    required this.acceptCount,
    required this.rejectCount,
    required this.gapCount,
    required this.splitCount,
    required this.currentTripId,
  });

  final FacadeReadyOutcome facadeReadyOutcome;
  final FgbState? facadeCurrentState;
  final LastFixSample? lastAcceptedFix;
  final String? lastRejectedReason;
  final DateTime? lastRejectedAt;

  /// FGB activity classifier string; `'unknown'` when no activity event has
  /// fired yet.
  final String lastActivityType;
  final DateTime? lastActivityAt;

  final int acceptCount;
  final int rejectCount;
  final int gapCount;
  final int splitCount;

  final int? currentTripId;
}
