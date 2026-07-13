import 'dart:async';

import 'package:auto_explore/features/onboarding/data/permission_service_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart' show PermissionStatus;

/// Read-only permissions inspector section (SET-03).
///
/// Displays five permission rungs — Location Always, Location whenInUse,
/// Motion/Activity, Notifications, Battery optimization — each with a colored
/// live-status indicator.
///
/// Statuses are fetched once on init and re-fetched automatically each time
/// the app returns to the foreground (AppLifecycleState.resumed).
///
/// No request prompts, no deep-links, no openAppSettings calls. v1 is
/// intentionally read-only; interactive rungs may be added in a future phase.
class PermissionsSection extends ConsumerStatefulWidget {
  const PermissionsSection({super.key});

  @override
  ConsumerState<PermissionsSection> createState() =>
      _PermissionsSectionState();
}

class _PermissionsSectionState extends ConsumerState<PermissionsSection>
    with WidgetsBindingObserver {
  // Loaded asynchronously; null while pending or on error.
  PermissionStatus? _always;
  PermissionStatus? _whenInUse;
  PermissionStatus? _activityRecognition;
  PermissionStatus? _notification;
  PermissionStatus? _ignoreBatteryOptimizations;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_refresh());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_refresh());
    }
  }

  Future<void> _refresh() async {
    final svc = ref.read(permissionServiceProvider);

    final always = await _safeStatus(svc.statusAlways);
    final whenInUse = await _safeStatus(svc.statusWhenInUse);
    final activityRecognition =
        await _safeStatus(svc.statusActivityRecognition);
    final notification = await _safeStatus(svc.statusNotification);
    final ignoreBatteryOptimizations =
        await _safeStatus(svc.statusIgnoreBatteryOptimizations);

    if (!mounted) return;
    setState(() {
      _always = always;
      _whenInUse = whenInUse;
      _activityRecognition = activityRecognition;
      _notification = notification;
      _ignoreBatteryOptimizations = ignoreBatteryOptimizations;
    });
  }

  /// Wraps a status read in a safe try/catch, returning null on any error
  /// (e.g. platform channel unavailable in tests or restricted environments).
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _PermissionRung(
          label: 'Standort immer',
          status: _always,
        ),
        _PermissionRung(
          label: 'Standort bei Nutzung',
          status: _whenInUse,
        ),
        _PermissionRung(
          label: 'Bewegung / Aktivität',
          status: _activityRecognition,
        ),
        _PermissionRung(
          label: 'Benachrichtigungen',
          status: _notification,
        ),
        _PermissionRung(
          label: 'Batterieoptimierung',
          status: _ignoreBatteryOptimizations,
        ),
      ],
    );
  }
}

/// A single read-only permission rung displaying a label and colored status dot.
class _PermissionRung extends StatelessWidget {
  const _PermissionRung({required this.label, required this.status});

  final String label;
  final PermissionStatus? status;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (dotColor, statusLabel) = _statusStyle(status, scheme);

    return ListTile(
      title: Text(label),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: dotColor,
              border: dotColor == Colors.transparent
                  ? Border.all(
                      color: scheme.outline.withValues(alpha: 0.6),
                    )
                  : null,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            statusLabel,
            style: TextStyle(
              color: dotColor == Colors.transparent ? scheme.onSurfaceVariant : dotColor,
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }

  /// Maps a [PermissionStatus?] to a (dotColor, label) pair.
  ///
  /// Color semantics:
  /// - granted / limited      → green (all good)
  /// - denied                 → colorScheme.error (user declined, re-askable)
  /// - permanentlyDenied /
  ///   restricted              → amber (needs Settings)
  /// - null (loading / error) → outline dot + "—"
  (Color, String) _statusStyle(PermissionStatus? status, ColorScheme scheme) {
    if (status == null) {
      return (Colors.transparent, '—');
    }
    return switch (status) {
      PermissionStatus.granted => (Colors.green, 'granted'),
      PermissionStatus.limited => (Colors.green, 'limited'),
      PermissionStatus.denied => (scheme.error, 'denied'),
      PermissionStatus.permanentlyDenied => (Colors.amber, 'permanentlyDenied'),
      PermissionStatus.restricted => (Colors.amber, 'restricted'),
      // provisional is iOS-specific (notification pre-grant).
      PermissionStatus.provisional => (Colors.green, 'provisional'),
    };
  }
}
