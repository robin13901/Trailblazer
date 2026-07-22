import 'dart:async';

import 'package:auto_explore/core/db/app_database.dart' hide TripPoint;
import 'package:auto_explore/core/errors/domain_error.dart';
import 'package:auto_explore/features/matching/data/live_tile_prefetch_service.dart';
import 'package:auto_explore/features/matching/data/trip_road_fetch_coordinator.dart';
import 'package:auto_explore/features/trips/data/background_geolocation_facade.dart';
import 'package:auto_explore/features/trips/data/trips_repository.dart';
import 'package:auto_explore/features/trips/domain/haversine.dart';
import 'package:auto_explore/features/trips/domain/live_fix_sample.dart';
import 'package:auto_explore/features/trips/domain/tracking_diagnostics.dart';
import 'package:auto_explore/features/trips/domain/tracking_state.dart';
import 'package:auto_explore/features/trips/domain/trip_fix_batcher.dart';
import 'package:auto_explore/features/trips/domain/trip_fix_ingestor.dart';
import 'package:auto_explore/features/trips/domain/trip_fix_input.dart';
import 'package:auto_explore/features/trips/domain/trip_point.dart';
import 'package:auto_explore/features/trips/domain/trip_status.dart';
import 'package:auto_explore/features/trips/domain/trip_summary.dart';
import 'package:logging/logging.dart';

/// Default ingestor factory — callers can override in tests.
TripFixIngestor _defaultIngestor() => TripFixIngestor();

/// Formats an elapsed [Duration] for the persistent tracking notification.
///
/// Below 1 h → `mm:ss` (matches the pre-04-19 default).
/// 1 h and above → `h:mm:ss` (hours field is NOT zero-padded — a 10 h drive
/// therefore reads `10:03:12`; acceptable for the notification pill).
///
/// Kept at library-scope so unit tests can exercise it directly without
/// spinning up a full [TrackingService]. Plan 04-19 (2026-07-09 drive fix):
/// prior code truncated hours via `d.inMinutes.remainder(60)`, so a
/// 100-min drive rendered `40:xx` instead of `1:40:xx`.
String formatNotificationDuration(Duration d) {
  final h = d.inHours;
  final mm = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final ss = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
}

/// Orchestrates the full trip-recording lifecycle.
///
/// Owns facade stream subscriptions, the active [TripFixIngestor] + [TripFixBatcher],
/// and dwell/resume timers. Emits [TrackingState] on [stateStream] — the Riverpod
/// TrackingNotifier listens to this and forwards to the UI layer.
///
/// No Flutter or Riverpod imports — pure Dart class, injectable and testable.
class TrackingService {
  TrackingService({
    required BackgroundGeolocationFacade facade,
    required TripsRepository repository,
    required TripPointsSink pointsSink,
    TripFixIngestor Function() ingestorFactory = _defaultIngestor,
    Duration autoStopDwell = const Duration(minutes: 2),
    Duration resumeWindow = const Duration(minutes: 15),
    double resumeRadiusMeters = 500,
    Duration notificationInterval = const Duration(seconds: 30),
    TripRoadFetchCoordinator? roadFetchCoordinator,
    LiveTilePrefetchService? tilePrefetch,
  })  : _facade = facade,
        _repository = repository,
        _pointsSink = pointsSink,
        _ingestorFactory = ingestorFactory,
        _autoStopDwell = autoStopDwell,
        _resumeWindow = resumeWindow,
        _resumeRadiusMeters = resumeRadiusMeters,
        _notificationInterval = notificationInterval,
        _roadFetchCoordinator = roadFetchCoordinator,
        _tilePrefetch = tilePrefetch;

  final BackgroundGeolocationFacade _facade;
  final TripsRepository _repository;
  final TripPointsSink _pointsSink;
  final TripFixIngestor Function() _ingestorFactory;
  final Duration _autoStopDwell;
  final Duration _resumeWindow;
  final double _resumeRadiusMeters;
  final Duration _notificationInterval;
  // Optional per Plan 04-15. When present, trips close as `pendingRoadData`
  // and the coordinator drives the transition to `pending` after the
  // Overpass fetch (or on offline-queue drain). When null, TrackingService
  // preserves the pre-04-15 behaviour: close directly to `pending`.
  // This keeps the 141 pre-existing tests (Wave 2 + Phase 3.1) green while
  // the road-fetch flow rolls out.
  final TripRoadFetchCoordinator? _roadFetchCoordinator;

  /// Optional live tile-prefetcher (Idea #6 Half A). When set, it warms the
  /// Overpass tile cache for the driven-so-far corridor during recording so the
  /// trip-end match starts cache-hot. Purely an optimization — null in tests /
  /// pre-existing call sites keeps behaviour identical.
  final LiveTilePrefetchService? _tilePrefetch;

  final _log = Logger('tracking');

  // Stream state
  final _stateController = StreamController<TrackingState>.broadcast();
  TrackingState _currentState = const TrackingIdle();

  // Live per-fix broadcast (live-nav). Carries the raw accepted coordinate +
  // heading of each fix for the dashed trail layer and the road-snap heading
  // service, without bloating the equality-compared TrackingState.
  final _liveFixController = StreamController<LiveFixSample>.broadcast();

  // Active trip state
  int? _currentTripId;
  DateTime? _tripStartedAt;
  TripFixIngestor? _ingestor;
  TripFixBatcher? _batcher;
  int _seq = 0;
  FixAccepted? _lastAcceptedFix;

  // Live driving direction (0..360, 0 = N). Preferred from the fix's own
  // course over ground when valid; otherwise computed as the motion-vector
  // bearing between consecutive accepted fixes more than [_headingMinMeters]
  // apart. Kept across fixes so a stationary stretch doesn't reset it. Plan
  // 06-07: emitted on TrackingRecording to drive the map camera rotation.
  double? _currentHeading;

  /// Minimum distance between two accepted fixes before a fresh motion-vector
  /// bearing is computed. Below this, the last heading is retained to avoid
  /// jitter while (nearly) stationary.
  static const double _headingMinMeters = 5;

  // Activity cache (automotive filter)
  String _lastActivityType = 'unknown';
  DateTime? _lastActivityAt;

  // Diagnostics counters — populated on every _onLocation outcome. Read-only
  // via the [diagnostics] getter; consumed by the dev-only HUD (Plan 03-1-01).
  // Live here (not on TripFixIngestor) to keep the ingestor pure — see
  // 03-1-RESEARCH §7.1.
  int _acceptCount = 0;
  int _rejectCount = 0;
  int _gapCount = 0;
  int _splitCount = 0;
  String? _lastRejectedReason;
  DateTime? _lastRejectedAt;
  LastFixSample? _lastAcceptedFixSample;

  // Dwell / resume timers
  Timer? _dwellTimer;
  Timer? _resumeTimer;
  DateTime? _pendingStopAt;
  FixAccepted? _pendingStopFix;

  // Notification updater — fires every ~30 s during recording to keep the
  // Android FGS notification text fresh. Lives here alongside dwell/resume
  // to avoid coupling to widget or Riverpod lifecycles (which can churn on
  // hot reload / background mode).
  Timer? _notificationTicker;

  // Periodic batcher flush during recording. The batcher itself only flushes
  // on its 20-point boundary (~20 s at 1 Hz) or on a motion/gap checkpoint, so
  // up to ~19 accepted fixes can sit in RAM unflushed. If the app is killed
  // (crash, battery death, OS kill) those buffered points are lost. A periodic
  // flush caps that loss window at [_flushInterval] regardless of motion
  // events (a steady straight drive emits none). Owned by the service so it
  // lives across the same lifecycle as the notification ticker.
  Timer? _flushTicker;

  /// How often to force-flush the batcher during recording, capping the
  /// crash-loss window to a few seconds of fixes (vs up to ~20 s otherwise).
  static const Duration _flushInterval = Duration(seconds: 5);

  // Lazy-init flag: facade.ready() is called at most once per service instance,
  // on first tracking use (manual start, auto-trip, or hydrated resume).
  bool _facadeReady = false;

  // Facade subscriptions
  StreamSubscription<FixInput>? _locSub;
  StreamSubscription<MotionChange>? _motionSub;
  StreamSubscription<ActivityChange>? _activitySub;

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// Broadcast stream of [TrackingState] changes. Seeded with current state
  /// on first listen; subsequent events emitted on every state transition.
  Stream<TrackingState> get stateStream => _stateController.stream;

  /// Broadcast stream of accepted fixes (coordinate + heading), one event per
  /// [FixAccepted] outcome during recording. Goes quiet on [TrackingIdle].
  /// Consumed by the live dashed trail layer and the road-snap heading service.
  Stream<LiveFixSample> get liveFixStream => _liveFixController.stream;

  /// Current state snapshot (synchronous read).
  TrackingState get currentState => _currentState;

  /// Read-only diagnostics snapshot for the dev-only HUD.
  ///
  /// Constructs a fresh [TrackingDiagnostics] each call — no caching, no
  /// stream. The HUD polls this via [Timer.periodic] at ~2 Hz.
  ///
  /// The `facadeCurrentState` field is intentionally `null` — the HUD reads
  /// it directly via [BackgroundGeolocationFacade.currentState] since that
  /// call is async. See 03-1-RESEARCH §7 for the full data-source map.
  TrackingDiagnostics get diagnostics {
    final st = _currentState;
    final currentTripId = st is TrackingRecording ? st.tripId : null;
    return TrackingDiagnostics(
      facadeReadyOutcome: _facade.currentReadyOutcome,
      facadeCurrentState: null,
      lastAcceptedFix: _lastAcceptedFixSample,
      lastRejectedReason: _lastRejectedReason,
      lastRejectedAt: _lastRejectedAt,
      lastActivityType: _lastActivityType,
      lastActivityAt: _lastActivityAt,
      acceptCount: _acceptCount,
      rejectCount: _rejectCount,
      gapCount: _gapCount,
      splitCount: _splitCount,
      currentTripId: currentTripId,
    );
  }

  /// Called once at app boot. Wires event listeners and hydrates state from the
  /// repository if a trip is already in flight.
  ///
  /// [facade.ready()] is deferred: it is called here only if the repository
  /// reveals an in-flight trip (so the FGS notification / nag toast does not
  /// fire on every cold start). For fresh starts the call is deferred until the
  /// user first engages tracking via [startManual] or the auto-trip path.
  Future<void> init() async {
    _locSub = _facade.onLocation.listen(_onLocation, onError: (Object e) {
      _log.severe('onLocation error', e);
    });
    _motionSub = _facade.onMotionChange.listen(_onMotionChange, onError: (Object e) {
      _log.severe('onMotionChange error', e);
    });
    _activitySub =
        _facade.onActivityChange.listen(_onActivityChange, onError: (Object e) {
      _log.severe('onActivityChange error', e);
    });

    // Cold-start hydration — unpack Result<Trip?> without async callback inside
    // when() to avoid discarded-future lint.
    final result = await _repository.activeTrip();
    Trip? trip;
    DomainError? fetchError;
    result.when(ok: (t) => trip = t, err: (e) => fetchError = e);

    if (fetchError != null) {
      _log.severe('activeTrip failed on cold-start: ${fetchError!.message}');
      _emitState(const TrackingIdle());
      return;
    }

    if (trip == null) {
      _emitState(const TrackingIdle());
      return;
    }

    // An in-flight `recording` trip exists from a PREVIOUS process — i.e. the
    // app was killed mid-recording (crash, battery death, OS kill) without a
    // normal Stop. Recover it WITHOUT losing data: replay its already-persisted
    // GPS points through a fresh ingestor and finalize it as a completed
    // (truncated) trip, exactly as a normal Stop would — including the matching
    // hand-off. Only fixes buffered in RAM at the instant of the crash are lost
    // (they never reached the DB); everything flushed survives.
    //
    // This deliberately does NOT resume the trip as live (the pre-2026-07-22
    // behaviour): a manual-only app has no way to re-arm FGB for an old trip,
    // and the old resume path also silently dropped every post-resume point via
    // a seq-collision. Finalize-on-launch is lossless for persisted data and
    // never leaves a trip stuck in `recording` forever.
    await _recoverInterruptedTrip(trip!);
  }

  /// Finalizes an interrupted `recording` trip (from a killed prior process)
  /// as a completed, truncated trip. Replays stored points through a fresh
  /// ingestor to rebuild the summary, then runs the shared close + matching
  /// hand-off. Emits [TrackingIdle] at the end (recovered trips are never live).
  ///
  /// A single trip's stored points can never contain a mid-trip split boundary
  /// (a split during recording already opened a separate trip row), so replay
  /// only ever yields `FixAccepted` / `GapObserved` — the summary math matches a
  /// normal stop exactly. Micro-trips below the keeper threshold are discarded,
  /// same as a normal stop.
  Future<void> _recoverInterruptedTrip(Trip trip) async {
    final fixesResult = await _repository.loadFixInputs(trip.id);
    var fixes = const <FixInput>[];
    DomainError? loadError;
    fixesResult.when(ok: (f) => fixes = f, err: (e) => loadError = e);

    if (loadError != null) {
      _log.severe(
        'crash-recovery: loadFixInputs failed for trip ${trip.id}: '
        '${loadError!.message}',
      );
      // Leave the trip as-is; a later launch retries. Do not crash startup.
      _emitState(const TrackingIdle());
      return;
    }

    final ingestor = _ingestorFactory();
    // Replay is order-preserving and split-free (see doc above); we only care
    // about the running-stat side effects, not each per-fix outcome. A plain
    // loop (not forEach+tear-off) since ingest() returns a value we discard.
    // ignore: prefer_foreach
    for (final fix in fixes) {
      ingestor.ingest(fix);
    }
    final summary = ingestor.finalize(startedAt: trip.startedAt);

    _log.info(
      'crash-recovery: finalizing interrupted trip ${trip.id} '
      '(${fixes.length} persisted fixes)',
    );

    // No live batcher/ingestor to flush — the points are already in the DB.
    // Route through the shared close path (same as a normal Stop).
    await _closeWithSummary(trip.id, summary, autoStopped: false);
  }

  /// Manual start (FAB tap). Opens a new recording trip with manuallyStarted=true.
  /// No-op if already recording.
  Future<void> startManual() async {
    if (_currentState is TrackingRecording) return;
    // Initialise the facade on first tracking use so the FGB nag toast does
    // not fire on every cold start — only when the user first engages tracking.
    await _ensureFacadeReady();
    // H1 fix (Plan 03-1-02): kick FGB into the "enabled" state. Without this,
    // `ready()` alone leaves the plugin configured-but-dark and no location
    // events flow. Idempotent per FGB 5.3.0 docs.
    await _facade.start();
    final now = DateTime.now();
    final result = await _repository.openTrip(
      startedAt: now,
      manuallyStarted: true,
    );
    result.when(
      ok: (id) {
        _currentTripId = id;
        _tripStartedAt = now;
        _seq = 0;
        _lastAcceptedFix = null;
        _ingestor = _ingestorFactory();
        _batcher = TripFixBatcher(tripId: id, sink: _pointsSink);
        _emitState(TrackingRecording(
          tripId: id,
          startedAt: now,
          distanceMeters: 0,
          pointCount: 0,
          manuallyStarted: true,
        ));
        _startNotificationTicker();
        _startFlushTicker();
        _tilePrefetch?.start(id);
      },
      err: (e) {
        _log.severe('startManual openTrip failed: ${e.message}');
      },
    );

    // Tell FGB we are moving — best-effort (fire-and-forget).
    try {
      await _facade.changePace(moving: true);
    } on Exception catch (e) {
      _log.warning('changePace(true) failed: $e');
    }
  }

  /// Universal stop (FAB stop). Flushes batcher, finalises summary,
  /// applies keeper threshold, transitions to Idle, and stops FGB so the
  /// foreground service + notification end when the manual trip ends
  /// (Plan 06-08 — no idle notification when not recording).
  Future<void> stopActive() async {
    if (_currentState is! TrackingRecording) return;
    final tripId = _currentTripId;
    if (tripId == null) return;

    _cancelDwellTimers();
    _stopNotificationTicker();
    _stopFlushTicker();
    _tilePrefetch?.stop();

    await _finalizeAndClose(tripId, autoStopped: false);

    try {
      await _facade.changePace(moving: false);
    } on Exception catch (e) {
      _log.warning('changePace(false) failed: $e');
    }

    // Plan 06-08: fully stop FGB so the foreground service + sticky
    // notification end with the manual trip. Previously the service stayed
    // alive (only paced to non-moving), leaving an idle notification and the
    // background wake path active. Best-effort — errors are logged.
    try {
      await _facade.stop();
    } on Object catch (e, st) {
      _log.warning('facade.stop() failed: $e', e, st);
    }
  }

  /// Release resources. Call when the service is being disposed.
  Future<void> dispose() async {
    _cancelDwellTimers();
    _stopNotificationTicker();
    _stopFlushTicker();
    _tilePrefetch?.stop();
    await _locSub?.cancel();
    await _motionSub?.cancel();
    await _activitySub?.cancel();
    await _stateController.close();
    await _liveFixController.close();
  }

  // ---------------------------------------------------------------------------
  // Event handlers
  // ---------------------------------------------------------------------------

  void _onLocation(FixInput fix) {
    if (_currentState is! TrackingRecording) return;
    final tripId = _currentTripId;
    if (tripId == null || _ingestor == null || _batcher == null) return;

    final outcome = _ingestor!.ingest(fix);

    switch (outcome) {
      case FixAccepted():
        final point = TripPoint(
          tripId: tripId,
          seq: _seq++,
          ts: outcome.ts,
          lat: outcome.lat,
          lon: outcome.lon,
          speedKmh: outcome.speedKmh,
          accuracyMeters: outcome.accuracyMeters,
          altitudeMeters: outcome.altitudeMeters,
          motionType: outcome.motionType,
        );
        // Motion-vector heading (Plan 06-07). Prefer the fix's own course
        // over ground when valid (>= 0); otherwise compute the initial
        // bearing from the previous accepted fix to this one, but only when
        // the two are far enough apart to avoid stationary jitter. Keep the
        // last heading otherwise.
        final prevFix = _lastAcceptedFix;
        final fixHeading = fix.headingDegrees;
        if (fixHeading != null && fixHeading >= 0) {
          _currentHeading = fixHeading % 360.0;
        } else if (prevFix != null) {
          final moved = haversineMeters(
            prevFix.lat,
            prevFix.lon,
            outcome.lat,
            outcome.lon,
          );
          if (moved > _headingMinMeters) {
            _currentHeading = bearingDegrees(
              prevFix.lat,
              prevFix.lon,
              outcome.lat,
              outcome.lon,
            );
          }
        }
        _lastAcceptedFix = outcome;
        _acceptCount++;
        _lastAcceptedFixSample = LastFixSample(
          ts: outcome.ts,
          lat: outcome.lat,
          lon: outcome.lon,
          accuracyMeters: outcome.accuracyMeters,
          speedKmh: outcome.speedKmh,
        );
        // Live per-fix broadcast for the dashed trail + road-snap heading.
        // Fire-and-forget on a broadcast controller — no-op when unlistened.
        _liveFixController.add(LiveFixSample(
          ts: outcome.ts,
          lat: outcome.lat,
          lon: outcome.lon,
          headingDegrees: _currentHeading,
        ));
        // Batcher.add is async but we don't await here — the method returns
        // Future<void> which means the batcher auto-flush may happen later.
        // We use unawaited intentionally; errors are swallowed by the sink.
        unawaited(_batcher!.add(point));

        // Update state with fresh stats from the ingestor.
        final current = _currentState;
        if (current is TrackingRecording) {
          _emitState(TrackingRecording(
            tripId: tripId,
            startedAt: current.startedAt,
            distanceMeters: _ingestor!.totalDistanceMeters,
            pointCount: _ingestor!.pointCount,
            manuallyStarted: current.manuallyStarted,
            currentSpeedKmh: outcome.speedKmh,
            headingDegrees: _currentHeading,
          ));
        }

      case FixRejected():
        _rejectCount++;
        _lastRejectedReason = outcome.reason;
        _lastRejectedAt = DateTime.now();
        _log.fine('fix rejected: ${outcome.reason}');

      case GapObserved():
        _gapCount++;
        // Natural checkpoint — flush batcher.
        unawaited(_batcher!.flush());

      case SplitRequired():
        _splitCount++;
        // Close current trip, open a new one with the recovered fix.
        unawaited(_handleSplit(outcome));
    }
  }

  Future<void> _handleSplit(SplitRequired split) async {
    final oldTripId = _currentTripId;
    if (oldTripId == null) return;

    // 1. Flush before closing so all points land before the trip is closed.
    await _batcher?.flush();

    // 2. Finalize the old ingestor.
    final summary = _ingestor?.finalize(startedAt: _tripStartedAt ?? DateTime.now());

    // 3. Close or delete the old trip.
    if (summary != null && summary.passesKeeperThreshold) {
      final tripSummary = TripSummary(
        startedAt: summary.startedAt,
        endedAt: summary.endedAt,
        durationSeconds: summary.durationSeconds,
        distanceMeters: summary.distanceMeters,
        avgSpeedKmh: summary.avgSpeedKmh,
        maxSpeedKmh: summary.maxSpeedKmh,
        pointCount: summary.pointCount,
        bboxMinLat: summary.bboxMinLat,
        bboxMinLon: summary.bboxMinLon,
        bboxMaxLat: summary.bboxMaxLat,
        bboxMaxLon: summary.bboxMaxLon,
        autoStopped: true,
      );
      final closeStatus = _roadFetchCoordinator == null
          ? TripStatus.pending
          : TripStatus.pendingRoadData;
      final closeResult = await _repository.closeTrip(
        oldTripId,
        tripSummary,
        status: closeStatus,
      );
      closeResult.when(ok: (_) {}, err: (e) {
        _log.severe('closeTrip failed on split: ${e.message}');
      });
      final coord = _roadFetchCoordinator;
      if (coord != null) {
        unawaited(
          coord.onTripStopped(
            oldTripId,
            bbox: (
              minLat: tripSummary.bboxMinLat,
              minLon: tripSummary.bboxMinLon,
              maxLat: tripSummary.bboxMaxLat,
              maxLon: tripSummary.bboxMaxLon,
            ),
          ),
        );
      }
    } else {
      final deleteResult = await _repository.deleteTrip(oldTripId);
      deleteResult.when(ok: (_) {}, err: (e) {
        _log.severe('deleteTrip failed on split: ${e.message}');
      });
    }

    // 4. Open a new trip.
    final now = DateTime.now();
    final openResult = await _repository.openTrip(
      startedAt: now,
      manuallyStarted: false,
    );
    openResult.when(
      ok: (newId) {
        _currentTripId = newId;
        _tripStartedAt = now;
        _seq = 0;
        _lastAcceptedFix = null;
        _ingestor = _ingestorFactory();
        _batcher = TripFixBatcher(tripId: newId, sink: _pointsSink);
        // Re-key the tile prefetcher to the new trip id (the flush + notification
        // tickers keep running across the split; prefetch is tripId-scoped).
        _tilePrefetch?.start(newId);

        // 5. Feed recovered fix into the new ingestor.
        final recovered = split.recovered;
        final recoveredInput = FixInput(
          ts: recovered.ts,
          lat: recovered.lat,
          lon: recovered.lon,
          accuracyMeters: recovered.accuracyMeters,
          speedMps: recovered.speedKmh / 3.6,
          altitudeMeters: recovered.altitudeMeters,
          activityType: recovered.motionType,
        );
        _onLocation(recoveredInput);

        _emitState(TrackingRecording(
          tripId: newId,
          startedAt: now,
          distanceMeters: 0,
          pointCount: 0,
          manuallyStarted: false,
        ));
      },
      err: (e) {
        _log.severe('openTrip failed on split: ${e.message}');
        _emitState(const TrackingIdle());
      },
    );
  }

  void _onMotionChange(MotionChange mc) {
    if (mc.isMoving) {
      // -----------------------------------------------------------------------
      // Plan 06-08: automatic background recording REMOVED. Trips are now
      // manual-only (FAB). The former TRK-01 automotive-filter branch that
      // opened an auto-trip on `motion=true` while idle is gone — motion
      // events while idle are ignored. The motion/activity listeners stay
      // wired for potential future use / the diagnostics HUD, but they never
      // open a trip.
      // -----------------------------------------------------------------------

      // While recording: flush on any motion change (natural checkpoint).
      if (_currentState is TrackingRecording) {
        unawaited(_batcher?.flush());

        // Resume-window check: if we had a pending stop and we're in vehicle,
        // cancel the timer and resume if within radius.
        if (_pendingStopAt != null &&
            _lastActivityType == 'in_vehicle') {
          final stopFix = _pendingStopFix;
          final currentFix = _lastAcceptedFix;
          if (stopFix != null && currentFix != null) {
            final dist = haversineMeters(
              stopFix.lat, stopFix.lon,
              currentFix.lat, currentFix.lon,
            );
            if (dist <= _resumeRadiusMeters) {
              _cancelDwellTimers();
              _pendingStopAt = null;
              _pendingStopFix = null;
              _log.fine('resume window: in_vehicle motion within radius → trip continues');
            }
          }
        }
      }
    } else {
      // motion=false: flush batcher (natural checkpoint).
      if (_currentState is TrackingRecording) {
        unawaited(_batcher?.flush());
      }
    }
  }

  void _onActivityChange(ActivityChange ac) {
    _lastActivityType = ac.activityType;
    _lastActivityAt = DateTime.now();

    if (_currentState is! TrackingRecording) return;
    final current = _currentState as TrackingRecording;

    // Manual trips do NOT auto-stop (TRK-03).
    if (current.manuallyStarted) return;

    final isAutomotive = ac.activityType == 'in_vehicle';

    if (isAutomotive) {
      // Cancel any pending dwell timer — vehicle is moving again.
      if (_dwellTimer != null) {
        _dwellTimer?.cancel();
        _dwellTimer = null;
        _log.fine('dwell timer cancelled: in_vehicle resumed');
      }

      // Resume-window: if we had a pending stop, check distance within radius.
      if (_pendingStopAt != null) {
        final stopFix = _pendingStopFix;
        final currentFix = _lastAcceptedFix;
        if (stopFix != null && currentFix != null) {
          final dist = haversineMeters(
            stopFix.lat, stopFix.lon,
            currentFix.lat, currentFix.lon,
          );
          if (dist <= _resumeRadiusMeters) {
            _cancelDwellTimers();
            _pendingStopAt = null;
            _pendingStopFix = null;
            _log.fine('resume window: in_vehicle activity within radius → trip continues');
          }
        }
      }
    } else {
      // Non-automotive: start dwell timer (only once; ignore if already running).
      if (_dwellTimer == null && _pendingStopAt == null) {
        _dwellTimer = Timer(_autoStopDwell, _onDwellExpired);
        _log.fine('dwell timer started: activity=${ac.activityType}');
      }
    }
  }

  void _onDwellExpired() {
    _dwellTimer = null;
    // Record the pending stop position and start the resume window.
    _pendingStopAt = DateTime.now();
    _pendingStopFix = _lastAcceptedFix;
    _log.fine('dwell expired — starting resume window');
    _resumeTimer = Timer(_resumeWindow, _closeAutoTrip);
  }

  void _closeAutoTrip() {
    _resumeTimer = null;
    _pendingStopAt = null;
    _pendingStopFix = null;
    _stopNotificationTicker();
    _stopFlushTicker();
    _tilePrefetch?.stop();
    final tripId = _currentTripId;
    if (tripId == null) return;
    unawaited(_finalizeAndClose(tripId, autoStopped: true));
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  Future<void> _finalizeAndClose(int tripId, {required bool autoStopped}) async {
    final ingestor = _ingestor;
    final startedAt = _tripStartedAt;

    // Flush any pending points first.
    await _batcher?.flush();

    // Finalize the ingestor.
    final summary = startedAt != null
        ? ingestor?.finalize(startedAt: startedAt)
        : null;

    // Reset active-trip state BEFORE the async repo calls so re-entrant
    // events don't open another trip against the same ID.
    _clearActiveTrip();

    await _closeWithSummary(tripId, summary, autoStopped: autoStopped);
  }

  /// Shared close path: given a computed [summary], either close [tripId] as a
  /// keeper (writing summary fields, flipping status, handing off to the road
  /// fetch/matching coordinator) or delete it as a below-threshold micro-trip.
  /// Emits [TrackingIdle] at the end.
  ///
  /// Extracted from [_finalizeAndClose] so crash-recovery
  /// ([_recoverInterruptedTrip]) reuses the EXACT same keeper gate, close, and
  /// matching hand-off as a normal Stop — the only difference being that
  /// recovery has no live batcher/ingestor to flush first.
  Future<void> _closeWithSummary(
    int tripId,
    TripSummaryDraft? summary, {
    required bool autoStopped,
  }) async {
    if (summary != null && summary.passesKeeperThreshold) {
      final tripSummary = TripSummary(
        startedAt: summary.startedAt,
        endedAt: summary.endedAt,
        durationSeconds: summary.durationSeconds,
        distanceMeters: summary.distanceMeters,
        avgSpeedKmh: summary.avgSpeedKmh,
        maxSpeedKmh: summary.maxSpeedKmh,
        pointCount: summary.pointCount,
        bboxMinLat: summary.bboxMinLat,
        bboxMinLon: summary.bboxMinLon,
        bboxMaxLat: summary.bboxMaxLat,
        bboxMaxLon: summary.bboxMaxLon,
        autoStopped: autoStopped,
      );
      // Plan 04-15: if the coordinator is wired, close as `pendingRoadData`
      // so the trip is parked while the Overpass fetch runs. The coordinator
      // then flips to `pending` on success or enqueues on failure.
      // Without a coordinator, keep the pre-04-15 shape (close → pending).
      final closeStatus = _roadFetchCoordinator == null
          ? TripStatus.pending
          : TripStatus.pendingRoadData;
      final result = await _repository.closeTrip(
        tripId,
        tripSummary,
        status: closeStatus,
      );
      result.when(
        ok: (_) {},
        err: (e) => _log.severe('closeTrip failed: ${e.message}'),
      );
      // Hand off to the coordinator AFTER the row lands so the fetch can
      // race the DB write without stepping on it.
      final coord = _roadFetchCoordinator;
      if (coord != null) {
        unawaited(
          coord.onTripStopped(
            tripId,
            bbox: (
              minLat: tripSummary.bboxMinLat,
              minLon: tripSummary.bboxMinLon,
              maxLat: tripSummary.bboxMaxLat,
              maxLon: tripSummary.bboxMaxLon,
            ),
          ),
        );
      }
    } else {
      // Below keeper threshold → delete the row (micro-trip).
      final result = await _repository.deleteTrip(tripId);
      result.when(
        ok: (_) {},
        err: (e) => _log.severe('deleteTrip failed: ${e.message}'),
      );
    }

    _emitState(const TrackingIdle());
  }

  void _clearActiveTrip() {
    _currentTripId = null;
    _tripStartedAt = null;
    _ingestor = null;
    _batcher = null;
    _seq = 0;
    _lastAcceptedFix = null;
    _currentHeading = null;
  }

  void _cancelDwellTimers() {
    _dwellTimer?.cancel();
    _dwellTimer = null;
    _resumeTimer?.cancel();
    _resumeTimer = null;
  }

  /// Starts (or restarts) the periodic notification updater.
  ///
  /// Fires every [_notificationInterval] during a recording trip. On each tick
  /// it formats the current elapsed time, distance, and speed and calls
  /// [BackgroundGeolocationFacade.setNotificationText] — fire-and-forget.
  ///
  /// Lives here alongside [_dwellTimer] / [_resumeTimer] so the timer is
  /// owned by the long-lived service, not a widget or Riverpod notifier
  /// (which can be recreated on hot reload or while the app is backgrounded).
  void _startNotificationTicker() {
    _notificationTicker?.cancel();
    _notificationTicker = Timer.periodic(_notificationInterval, (_) {
      final s = _currentState;
      if (s is! TrackingRecording) return;
      final now = DateTime.now();
      final d = s.duration(now);
      final timeStr = formatNotificationDuration(d);
      final km = (s.distanceMeters / 1000).toStringAsFixed(1);
      final spd = s.currentSpeedKmh?.round().toString() ?? '—';
      // Fire-and-forget — errors logged inside the facade.
      unawaited(_facade.setNotificationText(
        'Aufnahme · $timeStr · $km km · $spd km/h',
      ));
    });
  }

  /// Cancels the notification updater.
  void _stopNotificationTicker() {
    _notificationTicker?.cancel();
    _notificationTicker = null;
  }

  /// Starts (or restarts) the periodic batcher flush during recording. Caps
  /// the crash-loss window to [_flushInterval] of buffered fixes. Fire-and-
  /// forget; the sink swallows and logs any write error.
  void _startFlushTicker() {
    _flushTicker?.cancel();
    _flushTicker = Timer.periodic(_flushInterval, (_) {
      if (_currentState is! TrackingRecording) return;
      unawaited(_batcher?.flush());
    });
  }

  /// Cancels the periodic batcher flush.
  void _stopFlushTicker() {
    _flushTicker?.cancel();
    _flushTicker = null;
  }

  /// Calls [BackgroundGeolocationFacade.ready] exactly once per service
  /// instance. Idempotent — subsequent calls are no-ops (the facade itself
  /// also guards with its own `_ready` flag, but we avoid the extra await).
  ///
  /// A `ready()` failure previously disappeared silently (03-1-RESEARCH §2.4
  /// — no log line above `Level.INFO` was ever emitted). Plan 03-1-02 wraps
  /// the call in a `try`/`on Object catch` block: the error is logged at
  /// `severe`, `_facadeReady` stays false (so a subsequent call retries),
  /// and the exception is rethrown as a [DomainError] via [DomainError.wrap]
  /// so the caller (currently the FAB path via `TrackingNotifier`) can
  /// surface it. The facade's `currentReadyOutcome` (Plan 03-1-01) has
  /// already recorded the failed state — the debug HUD picks that up on
  /// its next poll.
  Future<void> _ensureFacadeReady() async {
    if (_facadeReady) return;
    try {
      await _facade.ready();
      _facadeReady = true;
    } on Object catch (e, st) {
      _log.severe('FGB ready() failed: $e', e, st);
      throw DomainError.wrap(e, st);
    }
  }

  void _emitState(TrackingState state) {
    _currentState = state;
    if (!_stateController.isClosed) {
      _stateController.add(state);
    }
  }
}
