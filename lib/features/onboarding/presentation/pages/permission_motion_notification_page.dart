import 'dart:io';

import 'package:auto_explore/features/onboarding/data/onboarding_flag_repository.dart';
import 'package:auto_explore/features/onboarding/data/permission_service_provider.dart';
import 'package:auto_explore/features/onboarding/data/tracking_capability_providers.dart';
import 'package:auto_explore/features/onboarding/data/tracking_capability_repository.dart';
import 'package:auto_explore/features/onboarding/presentation/widgets/permission_rationale_page.dart';
import 'package:auto_explore/features/trips/data/background_geolocation_facade_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:logging/logging.dart';
import 'package:permission_handler/permission_handler.dart';

/// Onboarding page 3 (last): Motion+Fitness (iOS) or Notification+battery
/// optimisation (Android). After completing this page, final capability is
/// resolved, persisted, and the user is navigated to `/`.
class PermissionMotionNotificationPage extends ConsumerStatefulWidget {
  const PermissionMotionNotificationPage({super.key});

  @override
  ConsumerState<PermissionMotionNotificationPage> createState() =>
      _PermissionMotionNotificationPageState();
}

class _PermissionMotionNotificationPageState
    extends ConsumerState<PermissionMotionNotificationPage> {
  static final _log = Logger('permission_motion_notification_page');

  bool _busy = false;

  Future<void> _onPrimary() async {
    if (_busy) return;
    setState(() => _busy = true);

    try {
      final svc = ref.read(permissionServiceProvider);

      if (Platform.isIOS) {
        await svc.requestSensors();
      } else {
        await svc.requestNotification();
        await ref
            .read(backgroundGeolocationFacadeProvider)
            .showIgnoreBatteryOptimizations();
      }

      await _resolveAndFinish();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _resolveAndFinish() async {
    final svc = ref.read(permissionServiceProvider);
    final always = await svc.statusAlways();
    // On iOS, `statusNotification` is skipped in the ladder — pass
    // `granted` to keep the pure resolver Android-agnostic.
    final notif = Platform.isAndroid
        ? await svc.statusNotification()
        : PermissionStatus.granted;
    // Plan 03-1-02 H5 fix: consider the Samsung / OEM battery-opt grant on
    // Android. iOS callers get `granted` from the PermissionService stub.
    final battOpt = await svc.statusIgnoreBatteryOptimizations();

    final capability = TrackingCapabilityRepository.resolveCapability(
      always: always,
      notification: notif,
      ignoreBatteryOptimizations: battOpt,
    );

    if (Platform.isAndroid && !battOpt.isGranted) {
      _log.info(
        'Ignore-battery-optimizations not granted — capability degrades '
        'to manualOnly. The permission-denial banner (Plan 03-05) is the '
        'recovery UI.',
      );
    }

    await ref.read(trackingCapabilityRepositoryProvider).save(capability);
    await ref.read(onboardingFlagRepositoryProvider).markDone();

    if (!mounted) return;
    context.go('/');
  }

  @override
  Widget build(BuildContext context) {
    final isIOS = Platform.isIOS;

    return PermissionRationalePage(
      icon: Icons.notifications_active,
      title: isIOS ? 'Bewegung & Fitness' : 'Benachrichtigungen und Batterie',
      body: isIOS
          ? 'Der Bewegungs- & Fitness-Sensor von iOS hilft, Fahren von Gehen zu '
              'unterscheiden — das macht die automatische Erkennung intelligenter.'
          : 'Trailblazer zeigt während der Aufnahme eine dauerhafte '
              'Benachrichtigung an (Android braucht dies, um das Tracking am '
              'Leben zu halten). Es bittet Android außerdem, die '
              'Batterieoptimierung zu ignorieren, damit das Betriebssystem das '
              'Tracking nicht mitten in der Fahrt beendet.',
      primaryLabel: isIOS ? 'Weiter' : 'Aktivieren',
      onPrimary: _busy ? () {} : _onPrimary,
    );
  }
}
