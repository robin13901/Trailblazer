import 'dart:async';

import 'package:auto_explore/features/onboarding/data/permission_service.dart';
import 'package:auto_explore/features/onboarding/data/permission_service_provider.dart';
import 'package:auto_explore/features/settings/data/diagnostics_metrics_provider.dart';
import 'package:auto_explore/features/trips/data/background_geolocation_facade.dart';
import 'package:auto_explore/features/trips/data/background_geolocation_facade_provider.dart';
import 'package:auto_explore/features/trips/domain/tracking_diagnostics.dart';
import 'package:auto_explore/features/trips/presentation/providers/tracking_diagnostics_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart'
    show PermissionStatus;

/// Diagnostics HUD for the tracking subsystem (Plan 03-1-01).
///
/// Reachable when the `kShowDiagnosticsHud` AppPrefs toggle is ON (Plan 09-03
/// / 09-07), via a ListTile in the Settings screen. Route:
/// `/settings/diagnostics`. The screen renders in both debug and release
/// builds — the kDebugMode gate was removed in Plan 09-06.
///
/// Refreshes at ~2 Hz via `Timer.periodic` + `setState` — no stream or
/// Riverpod watch, per 03-1-RESEARCH §7.2. Reads:
///   * [TrackingDiagnostics] via `ref.read(trackingDiagnosticsProvider)`
///   * `FgbState` via `_facade.currentState()` (async, cached in state)
///   * 5 permission-ladder rungs via [PermissionService]
///   * Matcher queue depth + Overpass cache hit rate via
///     [readDiagnosticsMetrics] (Plan 09-06)
///
/// The screen intentionally does NOT use LiquidGlass or any glass chrome —
/// this is functional, not decorative.
class TrackingDiagnosticsScreen extends ConsumerStatefulWidget {
  const TrackingDiagnosticsScreen({super.key});

  @override
  ConsumerState<TrackingDiagnosticsScreen> createState() =>
      _TrackingDiagnosticsScreenState();
}

class _TrackingDiagnosticsScreenState
    extends ConsumerState<TrackingDiagnosticsScreen> {
  static const _pollInterval = Duration(milliseconds: 500);

  Timer? _timer;
  FgbState? _facadeState;
  _PermissionSnapshot? _permissions;
  DiagnosticsMetrics? _metrics;

  @override
  void initState() {
    super.initState();
    unawaited(_refreshAsync());
    _timer = Timer.periodic(_pollInterval, (_) {
      if (!mounted) return;
      setState(() {}); // re-read trackingDiagnosticsProvider synchronously
      unawaited(_refreshAsync());
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }

  /// Fetch the async-only fields (FgbState, permission statuses, and matcher /
  /// Overpass metrics) off the polling tick. Kept off the synchronous rebuild
  /// so the widget tree isn't blocked on platform-channel calls.
  Future<void> _refreshAsync() async {
    final facade = ref.read(backgroundGeolocationFacadeProvider);
    final perms = ref.read(permissionServiceProvider);

    FgbState? facadeState;
    try {
      facadeState = await facade.currentState();
    } on Object {
      // Swallow — currentState may throw on iOS before ready(); the HUD
      // just displays `—` when null.
      facadeState = null;
    }

    final snapshot = _PermissionSnapshot(
      whenInUse: await _safeStatus(perms.statusWhenInUse),
      always: await _safeStatus(perms.statusAlways),
      notification: await _safeStatus(perms.statusNotification),
      activityRecognition: await _safeStatus(perms.statusActivityRecognition),
      ignoreBatteryOptimizations:
          await _safeStatus(perms.statusIgnoreBatteryOptimizations),
    );

    DiagnosticsMetrics? metrics;
    try {
      metrics = await readDiagnosticsMetrics(ref);
    } on Object {
      // Swallow — DB may be unavailable during early startup; HUD shows `—`.
      metrics = null;
    }

    if (!mounted) return;
    setState(() {
      _facadeState = facadeState;
      _permissions = snapshot;
      _metrics = metrics;
    });
  }

  Future<PermissionStatus?> _safeStatus(
    Future<PermissionStatus> Function() reader,
  ) async {
    try {
      return await reader();
    } on Object {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final diag = ref.read(trackingDiagnosticsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Tracking diagnostics')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          const _SectionHeader('FGB'),
          _FacadeReadyTile(outcome: diag.facadeReadyOutcome),
          ListTile(
            dense: true,
            title: const Text('state.enabled'),
            trailing: Text(_facadeState?.enabled.toString() ?? '—'),
          ),
          ListTile(
            dense: true,
            title: const Text('state.isMoving'),
            trailing: Text(_facadeState?.isMoving.toString() ?? '—'),
          ),
          const Divider(height: 1),
          const _SectionHeader('Permissions'),
          _PermissionTile('whenInUse', _permissions?.whenInUse),
          _PermissionTile('always', _permissions?.always),
          _PermissionTile('notification', _permissions?.notification),
          _PermissionTile(
            'activityRecognition',
            _permissions?.activityRecognition,
          ),
          _PermissionTile(
            'ignoreBatteryOptimizations',
            _permissions?.ignoreBatteryOptimizations,
          ),
          const Divider(height: 1),
          const _SectionHeader('Last accepted fix'),
          _LastFixTile(sample: diag.lastAcceptedFix),
          const Divider(height: 1),
          const _SectionHeader('Last rejected fix'),
          ListTile(
            dense: true,
            title: const Text('reason'),
            trailing: Text(diag.lastRejectedReason ?? '—'),
          ),
          ListTile(
            dense: true,
            title: const Text('when'),
            trailing: Text(_formatRelative(diag.lastRejectedAt)),
          ),
          const Divider(height: 1),
          const _SectionHeader('Last activity'),
          ListTile(
            dense: true,
            title: const Text('type'),
            trailing: Text(diag.lastActivityType),
          ),
          ListTile(
            dense: true,
            title: const Text('when'),
            trailing: Text(_formatRelative(diag.lastActivityAt)),
          ),
          const Divider(height: 1),
          const _SectionHeader('Counters'),
          ListTile(
            dense: true,
            title: const Text('accept'),
            trailing: Text('${diag.acceptCount}'),
          ),
          ListTile(
            dense: true,
            title: const Text('reject'),
            trailing: Text('${diag.rejectCount}'),
          ),
          ListTile(
            dense: true,
            title: const Text('gap'),
            trailing: Text('${diag.gapCount}'),
          ),
          ListTile(
            dense: true,
            title: const Text('split'),
            trailing: Text('${diag.splitCount}'),
          ),
          const Divider(height: 1),
          const _SectionHeader('Current trip'),
          ListTile(
            dense: true,
            title: const Text('tripId'),
            trailing:
                Text(diag.currentTripId?.toString() ?? 'idle'),
          ),
          const Divider(height: 1),
          const _SectionHeader('Matcher / cache'),
          ListTile(
            dense: true,
            title: const Text('queue depth'),
            trailing: Text(_metrics?.matcherQueueDepth.toString() ?? '—'),
          ),
          ListTile(
            dense: true,
            title: const Text('cacheHits'),
            trailing: Text(_metrics?.cacheHits.toString() ?? '—'),
          ),
          ListTile(
            dense: true,
            title: const Text('cacheMisses'),
            trailing: Text(_metrics?.cacheMisses.toString() ?? '—'),
          ),
          ListTile(
            dense: true,
            title: const Text('hitRate'),
            trailing: Text(
              _metrics?.cacheHitRate != null
                  ? '${(_metrics!.cacheHitRate! * 100).toStringAsFixed(0)}%'
                  : '—',
            ),
          ),
        ],
      ),
    );
  }
}

class _PermissionSnapshot {
  const _PermissionSnapshot({
    required this.whenInUse,
    required this.always,
    required this.notification,
    required this.activityRecognition,
    required this.ignoreBatteryOptimizations,
  });

  final PermissionStatus? whenInUse;
  final PermissionStatus? always;
  final PermissionStatus? notification;
  final PermissionStatus? activityRecognition;
  final PermissionStatus? ignoreBatteryOptimizations;
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 6),
      child: Text(
        title.toUpperCase(),
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              letterSpacing: 1.2,
              fontWeight: FontWeight.w600,
            ),
      ),
    );
  }
}

class _FacadeReadyTile extends StatelessWidget {
  const _FacadeReadyTile({required this.outcome});

  final FacadeReadyOutcome outcome;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (label, color) = switch (outcome) {
      FacadeReadyPending() => ('pending', scheme.outline),
      FacadeReadySuccess() => ('success', Colors.green),
      FacadeReadyFailed() => ('failed', scheme.error),
    };
    final subtitle = outcome is FacadeReadyFailed
        ? (outcome as FacadeReadyFailed).message
        : null;
    return ListTile(
      dense: true,
      title: const Text('ready() outcome'),
      subtitle: subtitle == null
          ? null
          : Text(
              subtitle,
              style: TextStyle(color: color.withValues(alpha: 0.85)),
            ),
      trailing: Text(
        label,
        style: TextStyle(color: color, fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _PermissionTile extends StatelessWidget {
  const _PermissionTile(this.label, this.status);

  final String label;
  final PermissionStatus? status;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      title: Text(label),
      trailing: Text(status?.name ?? '—'),
    );
  }
}

class _LastFixTile extends StatelessWidget {
  const _LastFixTile({required this.sample});

  final LastFixSample? sample;

  @override
  Widget build(BuildContext context) {
    if (sample == null) {
      return const ListTile(
        dense: true,
        title: Text('—'),
        subtitle: Text('no fix accepted yet'),
      );
    }
    final s = sample!;
    return ListTile(
      dense: true,
      title: Text('${s.lat.toStringAsFixed(5)}, ${s.lon.toStringAsFixed(5)}'),
      subtitle: Text(
        '${_formatRelative(s.ts)} · ±${s.accuracyMeters.toStringAsFixed(0)} m '
        '· ${s.speedKmh.toStringAsFixed(1)} km/h',
      ),
    );
  }
}

/// Format a [DateTime] as a short relative delta (`—`, `just now`,
/// `12 s ago`, `4 m ago`, `1 h ago`).
String _formatRelative(DateTime? ts) {
  if (ts == null) return '—';
  final delta = DateTime.now().difference(ts);
  if (delta.inSeconds < 2) return 'just now';
  if (delta.inSeconds < 60) return '${delta.inSeconds} s ago';
  if (delta.inMinutes < 60) return '${delta.inMinutes} m ago';
  if (delta.inHours < 24) return '${delta.inHours} h ago';
  return '${delta.inDays} d ago';
}
