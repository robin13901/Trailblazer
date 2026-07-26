// Trailblazer Phase 6, Plan 06-01 Task 1 tests: sweep-line interval union.

import 'package:auto_explore/features/coverage/domain/interval_union.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('unionIntervals', () {
    test('empty input returns empty list; drivenLength == 0', () {
      expect(unionIntervals(const []), isEmpty);
      expect(drivenLengthMeters(const []), 0);
    });

    test('single interval preserved', () {
      const iv = Interval(3, 7);
      final result = unionIntervals(const [iv]);
      expect(result, equals(const [iv]));
      expect(drivenLengthMeters(const [iv]), 4);
    });

    test('two disjoint intervals stay disjoint, sum is correct', () {
      final result = unionIntervals(const [
        Interval(0, 5),
        Interval(10, 15),
      ]);
      expect(result, equals(const [Interval(0, 5), Interval(10, 15)]));
      expect(drivenLengthMeters(result), 10);
    });

    test('two overlapping intervals merge into one union', () {
      final result = unionIntervals(const [
        Interval(0, 10),
        Interval(5, 15),
      ]);
      expect(result, equals(const [Interval(0, 15)]));
      expect(drivenLengthMeters(result), 15);
    });

    test('fully contained interval is absorbed', () {
      final result = unionIntervals(const [
        Interval(0, 20),
        Interval(5, 10),
      ]);
      expect(result, equals(const [Interval(0, 20)]));
    });

    test('three chained overlaps + one disjoint tail', () {
      final result = unionIntervals(const [
        Interval(0, 5),
        Interval(3, 8),
        Interval(7, 12),
        Interval(20, 25),
      ]);
      expect(result, equals(const [Interval(0, 12), Interval(20, 25)]));
      expect(drivenLengthMeters(result), 17);
    });

    test('unsorted input still produces sorted, merged output', () {
      final result = unionIntervals(const [
        Interval(20, 25),
        Interval(0, 5),
        Interval(3, 8),
      ]);
      expect(result, equals(const [Interval(0, 8), Interval(20, 25)]));
    });

    test('adjacent intervals merge (a.end == b.start)', () {
      final result = unionIntervals(const [
        Interval(0, 10),
        Interval(10, 20),
      ]);
      expect(result, equals(const [Interval(0, 20)]));
      expect(drivenLengthMeters(result), 20);
    });

    test('floating-point precision: [0.0,0.1] + [0.1,0.2] merges', () {
      final result = unionIntervals(const [
        Interval(0, 0.1),
        Interval(0.1, 0.2),
      ]);
      expect(result.length, 1);
      expect(result.first.startMeters, 0);
      expect(result.first.endMeters, closeTo(0.2, 1e-9));
      expect(drivenLengthMeters(result), closeTo(0.2, 1e-9));
    });

    test('input iterable is not mutated', () {
      final input = <Interval>[
        const Interval(10, 20),
        const Interval(0, 5),
      ];
      final snapshot = List<Interval>.of(input);
      unionIntervals(input);
      expect(input, equals(snapshot));
    });
  });

  group('overlapLengthMeters', () {
    test('empty intervals → 0', () {
      expect(overlapLengthMeters(const [], 0, 100), 0);
    });

    test('degenerate range (end <= start) → 0', () {
      expect(overlapLengthMeters(const [Interval(0, 100)], 50, 50), 0);
      expect(overlapLengthMeters(const [Interval(0, 100)], 60, 50), 0);
    });

    test('interval fully inside range → full interval length', () {
      expect(overlapLengthMeters(const [Interval(10, 30)], 0, 100), 20);
    });

    test('interval fully outside range → 0', () {
      expect(overlapLengthMeters(const [Interval(200, 300)], 0, 100), 0);
    });

    test('partial overlap → clipped length', () {
      // Driven [0,120] clipped to region range [50,100] → 50.
      expect(overlapLengthMeters(const [Interval(0, 120)], 50, 100), 50);
    });

    test('range spans a boundary — only the in-range half counts', () {
      // Driven the first 200 m of a way; region A occupies [0,195].
      expect(overlapLengthMeters(const [Interval(0, 200)], 0, 195), 195);
      // Region B occupies [195,410]; only 5 m of the drive spills in.
      expect(overlapLengthMeters(const [Interval(0, 200)], 195, 410), 5);
    });

    test('multiple disjoint intervals summed within range', () {
      expect(
        overlapLengthMeters(
          const [Interval(0, 20), Interval(40, 60)],
          10,
          50,
        ),
        // [10,20] = 10  +  [40,50] = 10  → 20
        20,
      );
    });
  });
}
