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
      title: 'Location while using Trailblazer',
      body:
          'Trailblazer draws the roads you drive on the map. It first needs '
          "permission to see your location while you're using the app.",
      primaryLabel: 'Continue',
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
