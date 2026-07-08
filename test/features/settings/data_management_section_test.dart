import 'dart:async';

import 'package:auto_explore/core/prefs/app_prefs.dart';
import 'package:auto_explore/features/admin/data/admin_bundle_refresher.dart';
import 'package:auto_explore/features/admin/data/admin_region_providers.dart';
import 'package:auto_explore/features/settings/presentation/widgets/data_management_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

class _FakeAdminBundleRefresher implements AdminBundleRefresher {
  _FakeAdminBundleRefresher({this.error});

  int callCount = 0;
  final Object? error;
  final Completer<void> completer = Completer<void>();

  @override
  Future<void> refreshFromOverpass() async {
    callCount++;
    if (error != null) {
      // Re-throw the caller-provided error verbatim so the widget's
      // catch-Object branch renders it in the failure SnackBar.
      // ignore: only_throw_errors
      throw error!;
    }
    if (!completer.isCompleted) completer.complete();
    return completer.future;
  }
}

Widget _wrap(Widget child, {required List<Object> overrides}) {
  return ProviderScope(
    overrides: overrides.cast(),
    child: MaterialApp(
      home: Scaffold(body: child),
    ),
  );
}

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  testWidgets('renders "Using bundled version" when prefs unset',
      (tester) async {
    await tester.pumpWidget(
      _wrap(
        const DataManagementSection(),
        overrides: [],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Refresh admin regions'), findsOneWidget);
    expect(find.text('Using bundled version'), findsOneWidget);
  });

  testWidgets('renders last-refreshed timestamp when prefs set',
      (tester) async {
    // Seed prefs before building.
    final prefs = SharedPreferencesAsync();
    await prefs.setString(AppPrefs.kAdminBundleVersion, '2026-07-08T12:00Z');

    await tester.pumpWidget(
      _wrap(
        const DataManagementSection(),
        overrides: [],
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Last refreshed: 2026-07-08T12:00Z'),
      findsOneWidget,
    );
  });

  testWidgets('tap → confirm dialog → refresher invoked → SnackBar shown',
      (tester) async {
    final fake = _FakeAdminBundleRefresher();
    await tester.pumpWidget(
      _wrap(
        const DataManagementSection(),
        overrides: [
          adminBundleRefresherProvider.overrideWithValue(fake),
        ],
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Refresh admin regions'));
    await tester.pumpAndSettle();

    expect(find.text('Refresh admin regions?'), findsOneWidget);
    await tester.tap(find.text('Refresh'));
    await tester.pumpAndSettle();

    expect(fake.callCount, 1);
    expect(find.text('Admin regions updated'), findsOneWidget);
  });

  testWidgets('tap → cancel → refresher NOT invoked',
      (tester) async {
    final fake = _FakeAdminBundleRefresher();
    await tester.pumpWidget(
      _wrap(
        const DataManagementSection(),
        overrides: [
          adminBundleRefresherProvider.overrideWithValue(fake),
        ],
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Refresh admin regions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(fake.callCount, 0);
  });

  testWidgets('error path → SnackBar reports failure', (tester) async {
    final fake = _FakeAdminBundleRefresher(error: StateError('boom'));
    await tester.pumpWidget(
      _wrap(
        const DataManagementSection(),
        overrides: [
          adminBundleRefresherProvider.overrideWithValue(fake),
        ],
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Refresh admin regions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Refresh'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Refresh failed'), findsOneWidget);
  });
}
