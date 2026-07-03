import 'package:auto_explore/app.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  testWidgets('App boots and reaches a stable screen', (tester) async {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();

    await tester.pumpWidget(const ProviderScope(child: App()));
    // Allow splash microtask + async prefs read + navigation to settle.
    await tester.pumpAndSettle(const Duration(seconds: 1));

    // First launch (empty prefs) -> onboarding screen visible.
    expect(find.text('Welcome to Trailblazer'), findsOneWidget);
  });
}
