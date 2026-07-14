// Trailblazer 2026-07-14 (road-snapped coverage rework):
// Unit tests for coveragePathFromMatch — proves on-road fixes render at their
// SNAPPED road position, off-road (null-step) fixes bridge with RAW GPS, the
// whole trip is one polyline unless a large gap splits it, and zero-length /
// malformed points are dropped.

import 'package:auto_explore/features/matching/domain/coverage_path_builder.dart';
import 'package:auto_explore/features/matching/domain/matched_step.dart';
import 'package:auto_explore/features/matching/domain/way_candidate.dart';
import 'package:flutter_test/flutter_test.dart';

/// An on-road step whose snapped point is deliberately DIFFERENT from the raw
/// fix, so a test can prove the builder used the snapped coord (not the raw).
MatchedStep _onRoad({
  required double snappedLat,
  required double snappedLon,
  int wayId = 1,
}) =>
    MatchedStep(
      wayId: wayId,
      segIdx: 0,
      projectionFraction: 0.5,
      perpDistMeters: 1,
      emissionLogP: -1,
      direction: 'forward',
      highwayClass: 'residential',
      oneway: OnewayDirection.no,
      snappedLat: snappedLat,
      snappedLon: snappedLon,
    );

void main() {
  group('coveragePathFromMatch', () {
    test('all on-road → one segment of SNAPPED points (not raw)', () {
      final fixes = [
        [50.0000, 8.0000],
        [50.0010, 8.0010],
        [50.0020, 8.0020],
      ];
      // Snapped coords offset from raw so we can tell them apart.
      final steps = [
        _onRoad(snappedLat: 50.1000, snappedLon: 8.1000),
        _onRoad(snappedLat: 50.1010, snappedLon: 8.1010),
        _onRoad(snappedLat: 50.1020, snappedLon: 8.1020),
      ];

      final out = coveragePathFromMatch(fixes, steps);

      expect(out, hasLength(1));
      expect(out.first, [
        [50.1000, 8.1000],
        [50.1010, 8.1010],
        [50.1020, 8.1020],
      ]);
    });

    test('all off-road (null steps) → one segment of RAW GPS points', () {
      final fixes = [
        [50.0000, 8.0000],
        [50.0005, 8.0005],
        [50.0010, 8.0010],
      ];
      final steps = <MatchedStep?>[null, null, null];

      final out = coveragePathFromMatch(fixes, steps);

      expect(out, hasLength(1));
      expect(out.first, fixes);
    });

    test('mixed on→off→on → one continuous segment mixing both sources', () {
      final fixes = [
        [50.0000, 8.0000], // on-road
        [50.0005, 8.0005], // off-road (raw bridge)
        [50.0010, 8.0010], // on-road
      ];
      // Snapped coords a realistic ~1 m off the raw fix, but distinct values so
      // the test proves the snapped source was used for on-road fixes.
      final steps = <MatchedStep?>[
        _onRoad(snappedLat: 50.00001, snappedLon: 8.00001),
        null,
        _onRoad(snappedLat: 50.00101, snappedLon: 8.00101),
      ];

      final out = coveragePathFromMatch(fixes, steps);

      expect(out, hasLength(1));
      expect(out.first, [
        [50.00001, 8.00001], // snapped
        [50.0005, 8.0005], // raw GPS bridge
        [50.00101, 8.00101], // snapped
      ]);
    });

    test('cross-way transition with nearby snapped points stays one run', () {
      // Two different ways meeting at a junction: snapped points are close, so
      // no spurious split — the junction chord is tiny.
      final fixes = [
        [50.0000, 8.0000],
        [50.0001, 8.0001],
      ];
      final steps = [
        _onRoad(wayId: 3, snappedLat: 50.00001, snappedLon: 8.00001),
        _onRoad(wayId: 2, snappedLat: 50.00005, snappedLon: 8.00005),
      ];

      final out = coveragePathFromMatch(fixes, steps);

      expect(out, hasLength(1));
      expect(out.first, hasLength(2));
    });

    test('gap > splitGapMeters splits into two segments', () {
      // ~1.5 km jump between fix 2 and 3 (0.01° lat ≈ 1.1 km).
      final fixes = [
        [50.0000, 8.0000],
        [50.0005, 8.0000],
        [50.0200, 8.0000], // big jump
        [50.0205, 8.0000],
      ];
      final steps = <MatchedStep?>[null, null, null, null];

      final out = coveragePathFromMatch(fixes, steps);

      expect(out, hasLength(2));
      expect(out[0], [
        [50.0000, 8.0000],
        [50.0005, 8.0000],
      ]);
      expect(out[1], [
        [50.0200, 8.0000],
        [50.0205, 8.0000],
      ]);
    });

    test('same small gap stays one segment; splitGapMeters override splits it',
        () {
      // ~55 m spacing (0.0005° lat ≈ 55 m).
      final fixes = [
        [50.0000, 8.0000],
        [50.0005, 8.0000],
        [50.0010, 8.0000],
      ];
      final steps = <MatchedStep?>[null, null, null];

      // Default 200 m threshold → one run.
      expect(coveragePathFromMatch(fixes, steps), hasLength(1));

      // Tight 10 m override → every hop splits → no run reaches 2 points.
      expect(
        coveragePathFromMatch(fixes, steps, splitGapMeters: 10),
        isEmpty,
      );
    });

    test('single-point run is dropped (needs 2+ points)', () {
      final fixes = [
        [50.0000, 8.0000],
      ];
      final steps = <MatchedStep?>[null];

      expect(coveragePathFromMatch(fixes, steps), isEmpty);
    });

    test('malformed length-<2 fix is skipped; identical points deduped', () {
      final fixes = [
        [50.0000, 8.0000],
        [50.0000, 8.0000], // duplicate → deduped
        <double>[8.5], // malformed (length 1) → skipped
        [50.0010, 8.0010],
      ];
      final steps = <MatchedStep?>[null, null, null, null];

      final out = coveragePathFromMatch(fixes, steps);

      expect(out, hasLength(1));
      // Duplicate collapsed, malformed skipped → two distinct points.
      expect(out.first, [
        [50.0000, 8.0000],
        [50.0010, 8.0010],
      ]);
    });

    test('steps shorter than fixes → trailing fixes treated as off-road', () {
      final fixes = [
        [50.0000, 8.0000],
        [50.0010, 8.0010], // no step for this index → raw
      ];
      final steps = <MatchedStep?>[
        _onRoad(snappedLat: 50.00001, snappedLon: 8.00001),
      ];

      final out = coveragePathFromMatch(fixes, steps);

      expect(out, hasLength(1));
      expect(out.first, [
        [50.00001, 8.00001], // snapped
        [50.0010, 8.0010], // raw (no step)
      ]);
    });

    test('empty fixes → empty output', () {
      expect(coveragePathFromMatch(const [], const []), isEmpty);
    });
  });
}
