---
plan: "03"
name: "go-router-shell"
wave: 2
depends_on: ["01"]
files_modified:
  - "lib/core/routing/app_router.dart"    # replaces stub from Plan 01
  - "lib/core/routing/app_router.g.dart"  # generated
  - "lib/features/onboarding/presentation/splash_screen.dart"
  - "lib/features/onboarding/presentation/onboarding_screen.dart"
  - "lib/features/onboarding/data/onboarding_flag_repository.dart"
  - "lib/features/map/presentation/placeholder_home_screen.dart"
  - "test/core/routing/app_router_test.dart"
  - "test/features/onboarding/onboarding_flag_repository_test.dart"
autonomous: true
requirements: ["FND-09"]
must_haves:
  truths:
    - "On first launch (no `onboarding_done` pref), the router lands on `/splash` then redirects the user through `/onboarding` before showing the placeholder home."
    - "On subsequent launches (`onboarding_done=true`), the router bypasses `/onboarding` and shows `/` (placeholder home)."
    - "Marking onboarding done persists across app restarts via `SharedPreferencesAsync`."
    - "`flutter run` on iOS + Android displays a non-crashing screen — satisfies phase SC5."
  artifacts:
    - path: "lib/core/routing/app_router.dart"
      provides: "@riverpod GoRouter with splash / onboarding / placeholder-home + first-launch redirect"
      contains: "@riverpod"
    - path: "lib/features/onboarding/data/onboarding_flag_repository.dart"
      provides: "Async repository around SharedPreferencesAsync for the onboarding_done flag"
    - path: "lib/features/onboarding/presentation/splash_screen.dart"
      provides: "Splash widget rendered on `/splash`"
    - path: "lib/features/onboarding/presentation/onboarding_screen.dart"
      provides: "Onboarding widget with 'Continue' action that flips the flag and navigates to `/`"
    - path: "lib/features/map/presentation/placeholder_home_screen.dart"
      provides: "Empty Scaffold at `/` — Phase 2 replaces with real map"
  key_links:
    - from: "lib/core/routing/app_router.dart"
      to: "lib/features/onboarding/data/onboarding_flag_repository.dart"
      via: "GoRouter redirect reads onboarding_done"
      pattern: "onboarding_done|onboardingFlagProvider"
    - from: "lib/features/onboarding/presentation/onboarding_screen.dart"
      to: "lib/features/onboarding/data/onboarding_flag_repository.dart"
      via: "sets onboarding_done=true, then context.go('/')"
      pattern: "context\\.go\\('/'\\)"
---

<objective>
Wire `go_router` for navigation and implement the first-launch splash → onboarding → home flow. After this plan, the app launches, shows onboarding once, persists the flag, and lands on the placeholder home screen on subsequent runs.
</objective>

<context>
- **Package:** `go_router: ^17.3.0` (pinned in Plan 01).
- **Router in Riverpod scope pattern:** RESEARCH.md lines 578-618 (with placeholder redirect).
- **Full redirect logic:** RESEARCH.md lines 643-659.
- **SharedPreferencesAsync preferred over legacy API:** RESEARCH.md lines 676-681, 1081.
- **Pitfall 6 (do not build GoRouter as a global):** RESEARCH.md lines 946-952.
- **CONTEXT.md decisions:** first-launch flow is splash → onboarding → main; onboarding shown once only; onboarding structure = Claude's discretion — RESEARCH.md picks a separate `/onboarding` GoRoute + redirect guard (lines 208-209).
- **Phase 2 will replace `/` with a `StatefulShellRoute`** (RESEARCH.md lines 663-674). Plan 03 must NOT add the shell — that's out of scope. Leave `/` as a placeholder.
</context>

<tasks>

<task id="3.1" type="auto">
  <name>Create onboarding_flag_repository + tests</name>
  <files>
    - `lib/features/onboarding/data/onboarding_flag_repository.dart`
    - `test/features/onboarding/onboarding_flag_repository_test.dart`
  </files>
  <action>

    **`lib/features/onboarding/data/onboarding_flag_repository.dart`:**

    ```dart
    import 'package:flutter_riverpod/flutter_riverpod.dart';
    import 'package:riverpod_annotation/riverpod_annotation.dart';
    import 'package:shared_preferences/shared_preferences.dart';

    part 'onboarding_flag_repository.g.dart';

    /// Repository around SharedPreferencesAsync for the one-shot
    /// `onboarding_done` flag. Kept minimal — no in-memory cache; the router
    /// reads it once at redirect time.
    class OnboardingFlagRepository {
      OnboardingFlagRepository(this._prefs);

      static const String _key = 'onboarding_done';
      final SharedPreferencesAsync _prefs;

      Future<bool> isDone() async => (await _prefs.getBool(_key)) ?? false;

      Future<void> markDone() async => _prefs.setBool(_key, true);

      Future<void> reset() async => _prefs.remove(_key);
    }

    @Riverpod(keepAlive: true)
    OnboardingFlagRepository onboardingFlagRepository(Ref ref) {
      return OnboardingFlagRepository(SharedPreferencesAsync());
    }
    ```

    Regenerate riverpod parts:

    ```bash
    dart run build_runner build --delete-conflicting-outputs
    ```

    **`test/features/onboarding/onboarding_flag_repository_test.dart`:**

    ```dart
    import 'package:auto_explore/features/onboarding/data/onboarding_flag_repository.dart';
    import 'package:flutter_test/flutter_test.dart';
    import 'package:shared_preferences/shared_preferences.dart';

    void main() {
      setUp(() async {
        SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
      });

      test('isDone() returns false by default', () async {
        final repo = OnboardingFlagRepository(SharedPreferencesAsync());
        expect(await repo.isDone(), isFalse);
      });

      test('markDone() then isDone() returns true', () async {
        final repo = OnboardingFlagRepository(SharedPreferencesAsync());
        await repo.markDone();
        expect(await repo.isDone(), isTrue);
      });

      test('reset() clears the flag', () async {
        final repo = OnboardingFlagRepository(SharedPreferencesAsync());
        await repo.markDone();
        await repo.reset();
        expect(await repo.isDone(), isFalse);
      });
    }
    ```

    NOTE on test setup: `InMemorySharedPreferencesAsync.empty()` is provided by `shared_preferences_platform_interface` and is exposed by `shared_preferences ^2.5.5` for testing. If the import fails, fall back to `SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsyncPlatform();` — verify the exact class name at execution time by grepping the `.pub-cache/hosted/pub.dev/shared_preferences-*/lib/` sources.
  </action>
  <verify>
    ```bash
    dart run build_runner build --delete-conflicting-outputs
    flutter analyze --fatal-infos lib/features/onboarding/ test/features/onboarding/
    flutter test test/features/onboarding/
    ```
  </verify>
  <done>Repo compiles; three unit tests pass.</done>
</task>

<task id="3.2" type="auto">
  <name>Replace app_router stub with full GoRouter + splash/onboarding/home screens</name>
  <files>
    - `lib/core/routing/app_router.dart`  # replaces stub from Plan 01
    - `lib/features/onboarding/presentation/splash_screen.dart`
    - `lib/features/onboarding/presentation/onboarding_screen.dart`
    - `lib/features/map/presentation/placeholder_home_screen.dart`
  </files>
  <action>

    **`lib/features/onboarding/presentation/splash_screen.dart`:**

    ```dart
    import 'dart:async';

    import 'package:auto_explore/features/onboarding/data/onboarding_flag_repository.dart';
    import 'package:flutter/material.dart';
    import 'package:flutter_riverpod/flutter_riverpod.dart';
    import 'package:go_router/go_router.dart';

    class SplashScreen extends ConsumerStatefulWidget {
      const SplashScreen({super.key});

      @override
      ConsumerState<SplashScreen> createState() => _SplashScreenState();
    }

    class _SplashScreenState extends ConsumerState<SplashScreen> {
      @override
      void initState() {
        super.initState();
        // Give the frame a chance to render before deciding where to go.
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
    ```

    **`lib/features/onboarding/presentation/onboarding_screen.dart`:**

    ```dart
    import 'package:auto_explore/features/onboarding/data/onboarding_flag_repository.dart';
    import 'package:flutter/material.dart';
    import 'package:flutter_riverpod/flutter_riverpod.dart';
    import 'package:go_router/go_router.dart';

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
                    'Welcome to Auto-Explore',
                    style: TextStyle(fontSize: 28, fontWeight: FontWeight.w600),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Every road you drive gets painted onto the map. '
                    'That view is the whole point.',
                    textAlign: TextAlign.center,
                  ),
                  const Spacer(),
                  FilledButton(
                    onPressed: () async {
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
    ```

    **`lib/features/map/presentation/placeholder_home_screen.dart`:**

    ```dart
    import 'package:flutter/material.dart';

    /// Placeholder — replaced by the real Map screen in Phase 2.
    class PlaceholderHomeScreen extends StatelessWidget {
      const PlaceholderHomeScreen({super.key});

      @override
      Widget build(BuildContext context) {
        return const Scaffold(
          body: Center(child: Text('Auto-Explore')),
        );
      }
    }
    ```

    **Replace `lib/core/routing/app_router.dart`** (removes the Plan 01 stub):

    ```dart
    import 'package:auto_explore/features/map/presentation/placeholder_home_screen.dart';
    import 'package:auto_explore/features/onboarding/presentation/onboarding_screen.dart';
    import 'package:auto_explore/features/onboarding/presentation/splash_screen.dart';
    import 'package:flutter_riverpod/flutter_riverpod.dart';
    import 'package:go_router/go_router.dart';
    import 'package:riverpod_annotation/riverpod_annotation.dart';

    part 'app_router.g.dart';

    @Riverpod(keepAlive: true)
    GoRouter appRouter(Ref ref) {
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
    }
    ```

    Design note: onboarding gating is handled by the SplashScreen (reads flag, redirects) rather than a top-level `redirect:` — this avoids re-running the async prefs read on every navigation, and keeps the router synchronous. Deep links land on splash first, which is acceptable for a personal app.

    Regenerate parts:

    ```bash
    dart run build_runner build --delete-conflicting-outputs
    ```
  </action>
  <verify>
    ```bash
    flutter analyze --fatal-infos
    dart format --set-exit-if-changed .
    flutter test          # existing widget_test.dart smoke test must still pass
    flutter build apk --debug
    ```
  </verify>
  <done>Analyzer + format clean; smoke test passes; Android debug APK builds green locally.</done>
</task>

<task id="3.3" type="auto">
  <name>Add widget test proving splash → onboarding → home flow</name>
  <files>
    - `test/core/routing/app_router_test.dart`
    - `test/widget_test.dart` (updated to reference the new screen text)
  </files>
  <action>

    **Update `test/widget_test.dart`** so the existing smoke test still passes with the new placeholder screen text (which was already `'Auto-Explore'`, so this is a no-op — but pump long enough to let the splash redirect resolve):

    ```dart
    import 'package:auto_explore/app.dart';
    import 'package:flutter/material.dart';
    import 'package:flutter_riverpod/flutter_riverpod.dart';
    import 'package:flutter_test/flutter_test.dart';
    import 'package:shared_preferences/shared_preferences.dart';

    void main() {
      testWidgets('App boots and reaches a stable screen', (tester) async {
        SharedPreferencesAsyncPlatform.instance =
            InMemorySharedPreferencesAsync.empty();

        await tester.pumpWidget(const ProviderScope(child: App()));
        // Allow splash redirect + async prefs read + first frame to settle.
        await tester.pumpAndSettle(const Duration(seconds: 1));

        // First launch → onboarding screen visible.
        expect(find.text('Welcome to Auto-Explore'), findsOneWidget);
      });
    }
    ```

    **`test/core/routing/app_router_test.dart`:**

    ```dart
    import 'package:auto_explore/app.dart';
    import 'package:auto_explore/features/onboarding/data/onboarding_flag_repository.dart';
    import 'package:flutter/material.dart';
    import 'package:flutter_riverpod/flutter_riverpod.dart';
    import 'package:flutter_test/flutter_test.dart';
    import 'package:shared_preferences/shared_preferences.dart';

    void main() {
      setUp(() {
        SharedPreferencesAsyncPlatform.instance =
            InMemorySharedPreferencesAsync.empty();
      });

      testWidgets('first launch: splash → onboarding → home flow', (tester) async {
        await tester.pumpWidget(const ProviderScope(child: App()));
        await tester.pumpAndSettle(const Duration(seconds: 1));
        expect(find.text('Welcome to Auto-Explore'), findsOneWidget);

        await tester.tap(find.text('Continue'));
        await tester.pumpAndSettle();
        expect(find.text('Auto-Explore'), findsOneWidget);
      });

      testWidgets('second launch: skips onboarding, lands on home', (tester) async {
        // Pre-set the flag.
        final repo = OnboardingFlagRepository(SharedPreferencesAsync());
        await repo.markDone();

        await tester.pumpWidget(const ProviderScope(child: App()));
        await tester.pumpAndSettle(const Duration(seconds: 1));

        expect(find.text('Auto-Explore'), findsOneWidget);
        expect(find.text('Welcome to Auto-Explore'), findsNothing);
      });
    }
    ```
  </action>
  <verify>
    ```bash
    flutter test test/core/routing/ test/widget_test.dart
    ```
  </verify>
  <done>All three widget tests pass, proving the flag-gated redirect works both ways.</done>
</task>

</tasks>

<verification>
```bash
dart run build_runner build --delete-conflicting-outputs
flutter analyze --fatal-infos
dart format --set-exit-if-changed .
flutter test
flutter build apk --debug
```
All exit 0.

Manual smoke (optional):
```bash
flutter run -d <device>   # first launch: onboarding shown; second launch: goes straight home
```
</verification>

<must_haves>
Contributes to phase Success Criterion 5 (empty app launches without crashing). Delivers FND-09 (typed navigation between top-level screens via go_router).
</must_haves>
