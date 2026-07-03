import 'package:auto_explore/features/map/presentation/providers/location_permission_provider.dart';
import 'package:auto_explore/features/onboarding/data/onboarding_flag_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:logging/logging.dart';
import 'package:permission_handler/permission_handler.dart';

final _log = Logger('onboarding');

/// One-shot onboarding screen.
///
/// The Continue button:
/// 1. Requests `locationWhenInUse` permission.
/// 2. Logs the outcome via the root [Logger].
/// 3. Shows a [SnackBar] hint if denied (does NOT gate navigation).
/// 4. Marks onboarding done and navigates to `/`.
class OnboardingScreen extends ConsumerWidget {
  const OnboardingScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Welcome to Trailblazer',
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.w600),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              const Text(
                'Every road you drive gets painted onto the map. '
                'That view is the whole point.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              const Text(
                'Trailblazer needs your location to paint the roads you '
                'drive onto the map. On the next tap, iOS/Android will '
                'ask for permission.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13),
              ),
              const Spacer(),
              FilledButton(
                onPressed: () async {
                  final scaffold = ScaffoldMessenger.of(context);
                  try {
                    final status = await ref
                        .read(locationPermissionProvider.notifier)
                        .requestOnce();
                    _log.info('status=$status');
                    if (!status.isGranted &&
                        !status.isLimited &&
                        context.mounted) {
                      scaffold.showSnackBar(
                        const SnackBar(
                          content: Text(
                            'Location denied — you can enable it later in Settings.',
                          ),
                        ),
                      );
                    }
                  } on Object catch (e, st) {
                    _log.warning('location permission request failed', e, st);
                  }
                  final repo = ref.read(onboardingFlagRepositoryProvider);
                  await repo.markDone();
                  if (!context.mounted) return;
                  context.go('/');
                },
                child: const Text('Continue'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
