// Trailblazer Phase 9, Plan 09-04: Widget tests for PermissionsSection.

import 'package:auto_explore/features/onboarding/data/permission_service_provider.dart';
import 'package:auto_explore/features/settings/presentation/widgets/permissions_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../onboarding/fakes/fake_permission_service.dart';

void main() {
  group('PermissionsSection', () {
    testWidgets('renders all five permission rungs', (tester) async {
      final fake = FakePermissionService();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            permissionServiceProvider.overrideWithValue(fake),
          ],
          child: const MaterialApp(
            home: Scaffold(body: PermissionsSection()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Standort immer'), findsOneWidget);
      expect(find.text('Standort bei Nutzung'), findsOneWidget);
      expect(find.text('Bewegung / Aktivität'), findsOneWidget);
      expect(find.text('Benachrichtigungen'), findsOneWidget);
      expect(find.text('Batterieoptimierung'), findsOneWidget);
    });

    testWidgets('shows correct statuses for mixed configuration', (tester) async {
      // Always=granted, whenInUse=granted, notification=granted (defaults),
      // activityRecognition=denied, ignoreBatteryOptimizations=permanentlyDenied.
      final fake = FakePermissionService()
        ..activityRecognitionStatus = PermissionStatus.denied
        ..ignoreBatteryOptimizationsStatus = PermissionStatus.permanentlyDenied;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            permissionServiceProvider.overrideWithValue(fake),
          ],
          child: const MaterialApp(
            home: Scaffold(body: PermissionsSection()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Granted rungs show 'granted' label.
      expect(find.text('granted'), findsNWidgets(3));

      // Denied rung shows 'denied' label.
      expect(find.text('denied'), findsOneWidget);

      // PermanentlyDenied rung shows 'permanentlyDenied' label.
      expect(find.text('permanentlyDenied'), findsOneWidget);
    });

    testWidgets('shows "granted" when all permissions are granted',
        (tester) async {
      // All defaults are granted; force-set the status-override fields too.
      final fake = FakePermissionService()
        ..activityRecognitionStatus = PermissionStatus.granted
        ..ignoreBatteryOptimizationsStatus = PermissionStatus.granted;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            permissionServiceProvider.overrideWithValue(fake),
          ],
          child: const MaterialApp(
            home: Scaffold(body: PermissionsSection()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // All five rungs should show 'granted'.
      expect(find.text('granted'), findsNWidgets(5));
    });

    testWidgets('no request methods are called on render', (tester) async {
      final fake = FakePermissionService();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            permissionServiceProvider.overrideWithValue(fake),
          ],
          child: const MaterialApp(
            home: Scaffold(body: PermissionsSection()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // requestLog should be empty — PermissionsSection must not call
      // any request() methods (read-only v1).
      expect(fake.requestLog, isEmpty);
      expect(fake.openAppSettingsCalls, isZero);
    });
  });
}
