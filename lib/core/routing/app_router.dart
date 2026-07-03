import 'package:auto_explore/features/map/presentation/placeholder_home_screen.dart';
import 'package:auto_explore/features/onboarding/presentation/onboarding_screen.dart';
import 'package:auto_explore/features/onboarding/presentation/splash_screen.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// Top-level GoRouter. Kept inside a Riverpod `Provider` so the router
/// can be replaced in tests via `ProviderScope.overrides`.
///
/// NOTE: plain `Provider` (no `@Riverpod` code-gen) — matches the
/// project-wide decision to avoid `riverpod_generator` code-gen while
/// `custom_lint`/`riverpod_lint` are out of the toolchain
/// (see STATE.md Plan 01-01 decision).
///
/// Onboarding gating is handled in [SplashScreen] (reads the flag once,
/// then `context.go(...)`), not a top-level `redirect:`. This keeps the
/// router synchronous and avoids re-reading prefs on every navigation.
/// Phase 2 will replace `/` with a `StatefulShellRoute` — do NOT add
/// that here.
final appRouterProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: '/splash',
    routes: [
      GoRoute(
        path: '/splash',
        builder: (context, state) => const SplashScreen(),
      ),
      GoRoute(
        path: '/onboarding',
        builder: (context, state) => const OnboardingScreen(),
      ),
      GoRoute(
        path: '/',
        builder: (context, state) => const PlaceholderHomeScreen(),
      ),
    ],
  );
});
