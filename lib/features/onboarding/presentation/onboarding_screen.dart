import 'package:auto_explore/features/onboarding/presentation/pages/permission_always_page.dart';
import 'package:auto_explore/features/onboarding/presentation/pages/permission_motion_notification_page.dart';
import 'package:auto_explore/features/onboarding/presentation/pages/permission_when_in_use_page.dart';
import 'package:flutter/material.dart';

/// Three-page permission onboarding flow.
///
/// Pages advance programmatically only ([NeverScrollableScrollPhysics]).
/// The [PageController] is created here and passed into each page so they
/// can call `nextPage` without knowing about the parent.
///
/// Page order:
///   0 — whenInUse location permission
///   1 — Always (background) location permission
///   2 — Motion+Fitness (iOS) / Notification+BatteryOpt (Android)
///
/// After page 2 completes: TrackingCapability is persisted,
/// onboarding_done flag is set, and the router navigates to `/`.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final PageController _pageController = PageController();

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: PageView(
          controller: _pageController,
          physics: const NeverScrollableScrollPhysics(),
          children: [
            PermissionWhenInUsePage(pageController: _pageController),
            PermissionAlwaysPage(pageController: _pageController),
            const PermissionMotionNotificationPage(),
          ],
        ),
      ),
    );
  }
}
