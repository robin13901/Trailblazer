import 'dart:io';

import 'package:auto_explore/features/onboarding/data/onboarding_flag_repository.dart';
import 'package:auto_explore/features/onboarding/data/permission_service_provider.dart';
import 'package:auto_explore/features/onboarding/data/tracking_capability.dart';
import 'package:auto_explore/features/onboarding/data/tracking_capability_providers.dart';
import 'package:auto_explore/features/onboarding/presentation/widgets/permission_rationale_page.dart';
import 'package:auto_explore/features/trips/data/background_geolocation_facade_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
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
    final notif = Platform.isAndroid
        ? await svc.statusNotification()
        : PermissionStatus.granted;

    final capability =
        (always.isGranted && notif.isGranted)
            ? TrackingCapability.fullAuto
            : TrackingCapability.manualOnly;

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
      title: isIOS ? 'Motion & Fitness' : 'Notifications and battery',
      body: isIOS
          ? "iOS's Motion & Fitness sensor helps distinguish driving from "
              'walking — this makes the auto-detect smarter.'
          : 'Trailblazer shows a persistent notification while recording '
              '(Android needs this to keep tracking alive). It also asks '
              "Android to ignore battery optimizations, so the OS doesn't "
              'kill tracking mid-trip.',
      primaryLabel: isIOS ? 'Continue' : 'Enable',
      onPrimary: _busy ? () {} : _onPrimary,
    );
  }
}
