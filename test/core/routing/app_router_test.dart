import 'package:auto_explore/app.dart';
import 'package:auto_explore/features/onboarding/data/onboarding_flag_repository.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  testWidgets('first launch: splash -> onboarding -> home flow', (
    tester,
  ) async {
    await tester.pumpWidget(const ProviderScope(child: App()));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    // Splash resolved into onboarding because prefs are empty.
    expect(find.text('Welcome to Auto-Explore'), findsOneWidget);

    // Tap Continue -> flag set -> navigate to placeholder home.
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(find.text('Auto-Explore'), findsOneWidget);
  });

  testWidgets('second launch: skips onboarding, lands on home', (tester) async {
    // Pre-set the onboarding_done flag to simulate a repeat launch.
    final repo = OnboardingFlagRepository(SharedPreferencesAsync());
    await repo.markDone();

    await tester.pumpWidget(const ProviderScope(child: App()));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.text('Auto-Explore'), findsOneWidget);
    expect(find.text('Welcome to Auto-Explore'), findsNothing);
  });
}
