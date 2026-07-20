import 'package:auto_explore/features/onboarding/data/permission_service_provider.dart';
import 'package:auto_explore/features/onboarding/presentation/widgets/permission_rationale_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Onboarding page 2: requests `locationAlways` (background) permission.
///
/// Offers a "Manual only" secondary button that skips without requesting.
/// The final capability is computed on the LAST page — this page does not
/// persist anything on its own.
class PermissionAlwaysPage extends ConsumerWidget {
  const PermissionAlwaysPage({required this.pageController, super.key});

  final PageController pageController;

  Future<void> _advance(WidgetRef ref) async {
    await pageController.nextPage(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return PermissionRationalePage(
      icon: Icons.explore,
      title: 'Fahrten im Hintergrund aufzeichnen',
      body:
          'OKF Buddy zeichnet Fahrten auch dann auf, wenn die App geschlossen '
          'ist — so erfassen wir die ganze Fahrt, nicht nur den Moment, in dem '
          'du die App geöffnet hast.',
      primaryLabel: 'Standort im Hintergrund aktivieren',
      onPrimary: () async {
        await ref.read(permissionServiceProvider).requestAlways();
        await _advance(ref);
      },
      secondaryLabel: 'Nur manuell',
      onSecondary: () => _advance(ref),
    );
  }
}
