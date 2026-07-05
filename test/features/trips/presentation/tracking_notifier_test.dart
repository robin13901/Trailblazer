import 'package:auto_explore/core/db/app_database.dart' hide TripPoint;
import 'package:auto_explore/core/db/app_database_providers.dart';
import 'package:auto_explore/features/trips/data/background_geolocation_facade_provider.dart';
import 'package:auto_explore/features/trips/domain/tracking_state.dart';
import 'package:auto_explore/features/trips/domain/trip_fix_input.dart';
import 'package:auto_explore/features/trips/presentation/providers/tracking_state_provider.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../helpers/fake_background_geolocation_facade.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Build [count] in-vehicle fixes at 1 Hz, each advancing lat by 0.00025°
/// (≈ 27.8 m at 49°N). Anchored to [from] so the trip's startedAt aligns.
List<FixInput> buildFixes(DateTime from, int count) {
  return List.generate(count, (i) {
    return FixInput(
      ts: from.add(Duration(seconds: i)),
      lat: 49.0 + i * 0.00025,
      lon: 8,
      accuracyMeters: 8,
      speedMps: 27.8,
      activityType: 'in_vehicle',
      uuid: 'uuid-notifier-$i',
    );
  });
}

void main() {
  late ProviderContainer container;
  late FakeBackgroundGeolocationFacade fakeFacade;
  late AppDatabase db;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    fakeFacade = FakeBackgroundGeolocationFacade();
    container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        backgroundGeolocationFacadeProvider.overrideWithValue(fakeFacade),
      ],
    );
  });

  tearDown(() async {
    container.dispose();
    fakeFacade.dispose();
    await db.close();
  });

  group('TrackingNotifier', () {
    test('initial state is TrackingIdle', () {
      final state = container.read(trackingStateProvider);
      expect(state, isA<TrackingIdle>());
    });

    test('startManual() → state TrackingRecording, facade.moving == true',
        () async {
      final state = container.read(trackingStateProvider);
      expect(state, isA<TrackingIdle>());

      await container.read(trackingStateProvider.notifier).startManual();
      // Allow stream to propagate.
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(container.read(trackingStateProvider), isA<TrackingRecording>());
      expect(fakeFacade.moving, isTrue);
    });

    test(
        'stopActive() on empty trip (no fixes) → '
        'state Idle, trips table empty (deleted)', () async {
      await container.read(trackingStateProvider.notifier).startManual();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(container.read(trackingStateProvider), isA<TrackingRecording>());

      await container.read(trackingStateProvider.notifier).stopActive();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(container.read(trackingStateProvider), isA<TrackingIdle>());

      // Trip below keeper threshold → deleted.
      final tripRows = await db.customSelect('SELECT * FROM trips').get();
      expect(tripRows, isEmpty);
    });

    test(
        'stopActive() after 65 fixes → '
        'state Idle, trips table has 1 row with status=pending', () async {
      await container.read(trackingStateProvider.notifier).startManual();
      await Future<void>.delayed(const Duration(milliseconds: 10));

      final now = DateTime.now();
      for (final fix in buildFixes(now, 65)) {
        fakeFacade.emitFix(fix);
        await Future<void>.delayed(Duration.zero);
      }
      // Allow batcher to flush.
      await Future<void>.delayed(const Duration(milliseconds: 100));

      await container.read(trackingStateProvider.notifier).stopActive();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(container.read(trackingStateProvider), isA<TrackingIdle>());

      final tripRows = await db.customSelect('SELECT * FROM trips').get();
      expect(tripRows, hasLength(1));
      expect(tripRows.first.read<String>('status'), 'pending');
    });
  });
}
