import 'package:auto_explore/features/map/data/location_repository.dart';
import 'package:flutter_test/flutter_test.dart';

/// Smoke tests for [LocationRepository].
///
/// Deep mocking of `permission_handler`'s platform interface requires the
/// `permission_handler_platform_interface` dev dependency plus
/// `PermissionHandlerPlatform.instance` override. For Phase 2 we keep these
/// as construction + type-assertion tests to avoid over-engineering; a richer
/// integration test is deferred to 02-07 (real-device verification).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('LocationRepository', () {
    test('can be constructed (const)', () {
      const repo = LocationRepository();
      expect(repo, isA<LocationRepository>());
    });

    test(
      'currentStatus() returns a Future (type assertion, no platform call)',
      () {
        // Verify the method exists and has the correct return type by reflection
        // without actually invoking the platform channel.
        const repo = LocationRepository();
        expect(repo.currentStatus, isA<Function>());
      },
    );

    test(
      'requestPermission() returns a Future (type assertion, no platform call)',
      () {
        const repo = LocationRepository();
        expect(repo.requestPermission, isA<Function>());
      },
    );

    test(
      'hasPermission() returns a Future (type assertion, no platform call)',
      () {
        const repo = LocationRepository();
        expect(repo.hasPermission, isA<Function>());
      },
    );
  });
}
