import 'package:auto_explore/features/onboarding/data/permission_service_provider.dart';
import 'package:auto_explore/features/onboarding/presentation/widgets/permission_rationale_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Onboarding page 1: requests `locationWhenInUse` permission.
///
/// Always advances the [PageController] regardless of grant/deny — the flow
/// never gates on the result.
class PermissionWhenInUsePage extends ConsumerWidget {
  const PermissionWhenInUsePage({required this.pageController, super.key});

  final PageController pageController;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return PermissionRationalePage(
      icon: Icons.location_on,
      title: 'Standort während der Nutzung von Trailblazer',
      body:
          'Trailblazer zeichnet die von dir gefahrenen Straßen auf der Karte '
          'nach. Zuerst braucht die App die Berechtigung, deinen Standort zu '
          'sehen, während du die App verwendest.',
      primaryLabel: 'Weiter',
      onPrimary: () async {
        await ref.read(permissionServiceProvider).requestWhenInUse();
        await pageController.nextPage(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
        );
      },
    );
  }
}
