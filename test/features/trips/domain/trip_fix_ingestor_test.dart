import 'package:auto_explore/features/trips/domain/trip_fix_ingestor.dart';
import 'package:auto_explore/features/trips/domain/trip_fix_input.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/trip_fixtures.dart';

void main() {
  group('TripFixIngestor', () {
    // -----------------------------------------------------------------------
    // Rejection rules
    // -----------------------------------------------------------------------

    test('rejects fix with accuracy > 25 m', () {
      final ingestor = TripFixIngestor();
      final result = ingestor.ingest(
        FixInput(
          ts: DateTime.utc(2026, 7, 5, 8),
          lat: 50.1,
          lon: 9,
          accuracyMeters: 30,
        ),
      );
      expect(result, isA<FixRejected>());
      expect((result as FixRejected).reason, equals('accuracy'));
    });

    test('rejects second fix arriving < 900 ms after the first', () {
      final ingestor = TripFixIngestor();
      final base = DateTime.utc(2026, 7, 5, 8);

      // First fix — accepted
      final first = ingestor.ingest(
        FixInput(ts: base, lat: 50.1, lon: 9, accuracyMeters: 5),
      );
      expect(first, isA<FixAccepted>());

      // Second fix 500 ms later — rate-limited
      final second = ingestor.ingest(
        FixInput(
          ts: base.add(const Duration(milliseconds: 500)),
          lat: 50.1001,
          lon: 9.0001,
          accuracyMeters: 5,
        ),
      );
      expect(second, isA<FixRejected>());
      expect((second as FixRejected).reason, equals('rate_limit'));
    });

    test('rejects duplicate UUID', () {
      final ingestor = TripFixIngestor();
      final base = DateTime.utc(2026, 7, 5, 8);

      ingestor.ingest(
        FixInput(ts: base, lat: 50.1, lon: 9, accuracyMeters: 5, uuid: 'dup'),
      );

      final dup = ingestor.ingest(
        FixInput(
          ts: base.add(const Duration(seconds: 2)),
          lat: 50.1002,
          lon: 9.0002,
          accuracyMeters: 5,
          uuid: 'dup',
        ),
      );
      expect(dup, isA<FixRejected>());
      expect((dup as FixRejected).reason, equals('duplicate'));
    });

    // -----------------------------------------------------------------------
    // Gap / split
    // -----------------------------------------------------------------------

    test('goldenWithGap (2-min gap): no SplitRequired emitted', () {
      final ingestor = TripFixIngestor();
      var splitCount = 0;

      for (final fix in goldenWithGap) {
        final outcome = ingestor.ingest(fix);
        if (outcome is SplitRequired) splitCount++;
      }

      expect(
        splitCount,
        equals(0),
        reason: 'A 2-min gap (< 5 min threshold) must NOT trigger a split',
      );
    });

    test(
      'goldenSplitCandidate emits SplitRequired (6-min gap + 800 m)',
      () {
        final ingestor = TripFixIngestor();
        IngestorOutcome? splitOutcome;

        for (final fix in goldenSplitCandidate) {
          final outcome = ingestor.ingest(fix);
          if (outcome is SplitRequired) {
            expect(splitOutcome, isNull, reason: 'Only one split expected');
            splitOutcome = outcome;
          }
        }

        expect(
          splitOutcome,
          isA<SplitRequired>(),
          reason: 'SplitRequired must be emitted at the 6-min / 800 m boundary',
        );
      },
    );

    // -----------------------------------------------------------------------
    // Keeper threshold (finalize)
    // -----------------------------------------------------------------------

    test('goldenParkingLotShuffle: passesKeeperThreshold == false (bbox)', () {
      final ingestor = TripFixIngestor();
      goldenParkingLotShuffle.forEach(ingestor.ingest);
      final summary = ingestor.finalize(startedAt: goldenParkingLotShuffle.first.ts);
      expect(summary, isNotNull);
      expect(
        summary!.passesKeeperThreshold,
        isFalse,
        reason: 'Parking-lot bbox diagonal < 50 m should fail keeper check',
      );
    });

    test('goldenShortDrive45s: passesKeeperThreshold == false (duration<60s)', () {
      final ingestor = TripFixIngestor();
      goldenShortDrive45s.forEach(ingestor.ingest);
      final summary = ingestor.finalize(startedAt: goldenShortDrive45s.first.ts);
      expect(summary, isNotNull);
      expect(
        summary!.passesKeeperThreshold,
        isFalse,
        reason: '45 s trip should fail duration < 60 s keeper check',
      );
    });

    test(
      'goldenTinyDistanceCrawl: passesKeeperThreshold == false (distance<100m)',
      () {
        final ingestor = TripFixIngestor();
        goldenTinyDistanceCrawl.forEach(ingestor.ingest);
        final summary =
            ingestor.finalize(startedAt: goldenTinyDistanceCrawl.first.ts);
        expect(summary, isNotNull);
        expect(
          summary!.passesKeeperThreshold,
          isFalse,
          reason: '~90 m trip should fail distance < 100 m keeper check',
        );
      },
    );

    // -----------------------------------------------------------------------
    // Golden suburban drive
    // -----------------------------------------------------------------------

    test('goldenSuburbanDrive10Fixes: 10 FixAccepted, passes keeper', () {
      // The fixture has 10 fixes 1 s apart = 9 s duration.
      // Use keeperMinSeconds: 5 so duration and distance checks are both met,
      // letting the test focus on speed/pointCount correctness.
      final ingestor = TripFixIngestor(keeperMinSeconds: 5);
      final outcomes = <IngestorOutcome>[];
      for (final fix in goldenSuburbanDrive10Fixes) {
        outcomes.add(ingestor.ingest(fix));
      }

      expect(outcomes.whereType<FixAccepted>().length, equals(10));
      expect(outcomes.whereType<FixRejected>().length, equals(0));

      final summary =
          ingestor.finalize(startedAt: goldenSuburbanDrive10Fixes.first.ts);
      expect(summary, isNotNull);
      expect(summary!.pointCount, equals(10));
      expect(summary.passesKeeperThreshold, isTrue);

      // avgSpeedKmh should be within ±5% of 40 km/h (speedMps was 11.1 m/s = 39.96 km/h)
      expect(
        summary.avgSpeedKmh,
        closeTo(40, 40 * 0.05),
        reason: 'avgSpeedKmh should be ≈ 40 km/h ± 5%',
      );

      // maxSpeedKmh close to 40 (speedMps 11.1 → 39.96 km/h)
      expect(
        summary.maxSpeedKmh,
        closeTo(40, 40 * 0.05),
        reason: 'maxSpeedKmh should be ≈ 40 km/h ± 5%',
      );
    });

    // -----------------------------------------------------------------------
    // finalize with no fixes
    // -----------------------------------------------------------------------

    test('finalize returns null when no fixes were accepted', () {
      final ingestor = TripFixIngestor();
      final summary = ingestor.finalize(startedAt: DateTime.utc(2026, 7, 5));
      expect(summary, isNull);
    });

    // -----------------------------------------------------------------------
    // SplitRequired does NOT update ingestor state
    // -----------------------------------------------------------------------

    test('SplitRequired: ingestor state not updated from recovered fix', () {
      final ingestor = TripFixIngestor();
      // Accept 2 fixes
      final base = DateTime.utc(2026, 7, 5, 8);
      ingestor
        ..ingest(FixInput(ts: base, lat: 50.3, lon: 8.8, accuracyMeters: 5))
        ..ingest(
          FixInput(
            ts: base.add(const Duration(seconds: 1)),
            lat: 50.3001,
            lon: 8.8001,
            accuracyMeters: 5,
          ),
        );

      // Trigger split (6 min + 800 m)
      final result = ingestor.ingest(
        FixInput(
          ts: base.add(const Duration(minutes: 6)),
          lat: 50.3076,
          lon: 8.801,
          accuracyMeters: 5,
        ),
      );
      expect(result, isA<SplitRequired>());

      // pointCount should still be 2 (recovered fix was NOT accepted)
      final summary = ingestor.finalize(startedAt: base);
      expect(summary!.pointCount, equals(2));
    });
  });
}
