import 'dart:async';

import 'package:auto_explore/core/db/app_database.dart' hide TripPoint;
import 'package:auto_explore/core/errors/domain_error.dart';
import 'package:auto_explore/features/trips/data/background_geolocation_facade.dart';
import 'package:auto_explore/features/trips/data/trips_repository.dart';
import 'package:auto_explore/features/trips/domain/haversine.dart';
import 'package:auto_explore/features/trips/domain/tracking_state.dart';
import 'package:auto_explore/features/trips/domain/trip_fix_batcher.dart';
import 'package:auto_explore/features/trips/domain/trip_fix_ingestor.dart';
import 'package:auto_explore/features/trips/domain/trip_fix_input.dart';
import 'package:auto_explore/features/trips/domain/trip_point.dart';
import 'package:auto_explore/features/trips/domain/trip_summary.dart';
import 'package:logging/logging.dart';

/// Default ingestor factory — callers can override in tests.
TripFixIngestor _defaultIngestor() => TripFixIngestor();

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
    Duration activityFreshness = const Duration(seconds: 10),
    Duration notificationInterval = const Duration(seconds: 30),
  })  : _facade = facade,
        _repository = repository,
        _pointsSink = pointsSink,
        _ingestorFactory = ingestorFactory,
        _autoStopDwell = autoStopDwell,
        _resumeWindow = resumeWindow,
        _resumeRadiusMeters = resumeRadiusMeters,
        _activityFreshness = activityFreshness,
        _notificationInterval = notificationInterval;

  final BackgroundGeolocationFacade _facade;
  final TripsRepository _repository;
  final TripPointsSink _pointsSink;
  final TripFixIngestor Function() _ingestorFactory;
  final Duration _autoStopDwell;
  final Duration _resumeWindow;
  final double _resumeRadiusMeters;
  final Duration _activityFreshness;
  final Duration _notificationInterval;

  final _log = Logger('tracking');

  // Stream state
  final _stateController = StreamController<TrackingState>.broadcast();
  TrackingState _currentState = const TrackingIdle();

  // Active trip state
  int? _currentTripId;
  DateTime? _tripStartedAt;
  TripFixIngestor? _ingestor;
  TripFixBatcher? _batcher;
  int _seq = 0;
  FixAccepted? _lastAcceptedFix;

  // Activity cache (automotive filter)
  String _lastActivityType = 'unknown';
  DateTime? _lastActivityAt;

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

  /// Current state snapshot (synchronous read).
  TrackingState get currentState => _currentState;

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

    // An in-flight trip exists — initialise the facade so FGB can resume
    // delivering location events and the FGS notification is updated.
    await _ensureFacadeReady();
    _currentTripId = trip!.id;
    _tripStartedAt = trip!.startedAt;
    _ingestor = _ingestorFactory();
    _batcher = TripFixBatcher(tripId: trip!.id, sink: _pointsSink);
    _emitState(
      TrackingRecording(
        tripId: trip!.id,
        startedAt: trip!.startedAt,
        distanceMeters: trip!.distanceMeters ?? 0,
        pointCount: trip!.pointCount ?? 0,
        manuallyStarted: trip!.manuallyStarted,
      ),
    );
    // Resume the notification updater for the hydrated trip.
    _startNotificationTicker();
  }

  /// Manual start (FAB tap). Opens a new recording trip with manuallyStarted=true.
  /// No-op if already recording.
  Future<void> startManual() async {
    if (_currentState is TrackingRecording) return;
    // Initialise the facade on first tracking use so the FGB nag toast does
    // not fire on every cold start — only when the user first engages tracking.
    await _ensureFacadeReady();
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

  /// Universal stop (FAB stop / auto-stop). Flushes batcher, finalises summary,
  /// applies keeper threshold, transitions to Idle.
  Future<void> stopActive() async {
    if (_currentState is! TrackingRecording) return;
    final tripId = _currentTripId;
    if (tripId == null) return;

    _cancelDwellTimers();
    _stopNotificationTicker();

    await _finalizeAndClose(tripId, autoStopped: false);

    try {
      await _facade.changePace(moving: false);
    } on Exception catch (e) {
      _log.warning('changePace(false) failed: $e');
    }
  }

  /// Release resources. Call when the service is being disposed.
  Future<void> dispose() async {
    _cancelDwellTimers();
    _stopNotificationTicker();
    await _locSub?.cancel();
    await _motionSub?.cancel();
    await _activitySub?.cancel();
    await _stateController.close();
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
        _lastAcceptedFix = outcome;
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
          ));
        }

      case FixRejected():
        _log.fine('fix rejected: ${outcome.reason}');

      case GapObserved():
        // Natural checkpoint — flush batcher.
        unawaited(_batcher!.flush());

      case SplitRequired():
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
      final closeResult = await _repository.closeTrip(
        oldTripId,
        TripSummary(
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
        ),
      );
      closeResult.when(ok: (_) {}, err: (e) {
        _log.severe('closeTrip failed on split: ${e.message}');
      });
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
      // TRK-01 automotive filter
      // -----------------------------------------------------------------------
      if (_currentState is TrackingIdle) {
        final activityFresh = _lastActivityAt != null &&
            DateTime.now().difference(_lastActivityAt!) <= _activityFreshness;
        if (_lastActivityType != 'in_vehicle' || !activityFresh) {
          _log.fine(
            'motion=true discarded: '
            'activity=$_lastActivityType, fresh=$activityFresh',
          );
          return;
        }

        // Open an auto-trip.
        unawaited(_openAutoTrip(mc.ts));
      }

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

  Future<void> _openAutoTrip(DateTime ts) async {
    // Initialise the facade on first auto-trip so the FGB nag toast does not
    // fire on every cold start — only when motion is actually detected.
    await _ensureFacadeReady();
    final result = await _repository.openTrip(
      startedAt: ts,
      manuallyStarted: false,
    );
    result.when(
      ok: (id) {
        _currentTripId = id;
        _tripStartedAt = ts;
        _seq = 0;
        _lastAcceptedFix = null;
        _ingestor = _ingestorFactory();
        _batcher = TripFixBatcher(tripId: id, sink: _pointsSink);
        _emitState(TrackingRecording(
          tripId: id,
          startedAt: ts,
          distanceMeters: 0,
          pointCount: 0,
          manuallyStarted: false,
        ));
        _startNotificationTicker();
      },
      err: (e) {
        _log.severe('openTrip failed on auto-start: ${e.message}');
      },
    );
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

    if (summary != null && summary.passesKeeperThreshold) {
      final result = await _repository.closeTrip(
        tripId,
        TripSummary(
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
        ),
      );
      result.when(
        ok: (_) {},
        err: (e) => _log.severe('closeTrip failed: ${e.message}'),
      );
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
      final mm = d.inMinutes.remainder(60).toString().padLeft(2, '0');
      final ss = d.inSeconds.remainder(60).toString().padLeft(2, '0');
      final km = (s.distanceMeters / 1000).toStringAsFixed(1);
      final spd = s.currentSpeedKmh?.round().toString() ?? '—';
      // Fire-and-forget — errors logged inside the facade.
      unawaited(_facade.setNotificationText(
        'Recording · $mm:$ss · $km km · $spd km/h',
      ));
    });
  }

  /// Cancels the notification updater.
  void _stopNotificationTicker() {
    _notificationTicker?.cancel();
    _notificationTicker = null;
  }

  /// Calls [BackgroundGeolocationFacade.ready] exactly once per service
  /// instance. Idempotent — subsequent calls are no-ops (the facade itself
  /// also guards with its own `_ready` flag, but we avoid the extra await).
  Future<void> _ensureFacadeReady() async {
    if (_facadeReady) return;
    await _facade.ready();
    _facadeReady = true;
  }

  void _emitState(TrackingState state) {
    _currentState = state;
    if (!_stateController.isClosed) {
      _stateController.add(state);
    }
  }
}
