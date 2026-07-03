import 'dart:async';

import 'package:auto_explore/features/onboarding/data/onboarding_flag_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// Splash screen: reads the `onboarding_done` flag once and redirects.
///
/// Gating happens here (rather than a `GoRouter.redirect`) so the router
/// stays synchronous — see Plan 03 design note. Deep links land on splash
/// first, which is acceptable for a personal app.
class SplashScreen extends ConsumerStatefulWidget {
  const SplashScreen({super.key});

  @override
  ConsumerState<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends ConsumerState<SplashScreen> {
  @override
  void initState() {
    super.initState();
    // Defer to a microtask so the first frame renders before we navigate.
    unawaited(Future<void>.microtask(_resolve));
  }

  Future<void> _resolve() async {
    final repo = ref.read(onboardingFlagRepositoryProvider);
    final done = await repo.isDone();
    if (!mounted) return;
    context.go(done ? '/' : '/onboarding');
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: CircularProgressIndicator()),
    );
  }
}
