// Trailblazer Phase 7, Plan 07-01:
// Unit tests for coverage threshold + fraction pure functions.

import 'package:auto_explore/features/coverage/domain/coverage_datum.dart';
import 'package:auto_explore/features/coverage/domain/coverage_threshold.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('isFullyCovered', () {
    test('long way (1000 m), union 970 m -> isFull true (>= 1000 - 30)', () {
      expect(isFullyCovered(970, 1000), isTrue);
    });

    test('long way (1000 m), union 969 m -> isFull false', () {
      expect(isFullyCovered(969, 1000), isFalse);
    });

    test('short way (25 m), union 20 m -> isFull true (>= 25 * 0.8 = 20)', () {
      expect(isFullyCovered(20, 25), isTrue);
    });

    test('short way (25 m), union 19 m -> isFull false', () {
      expect(isFullyCovered(19, 25), isFalse);
    });

    test('boundary: exactly 30 m way uses 80 % rule', () {
      // 30 m threshold = 30 * 0.8 = 24 m
      expect(isFullyCovered(24, 30), isTrue);
      expect(isFullyCovered(23.9, 30), isFalse);
    });

    test('boundary: 31 m way uses buffer rule (31 - 30 = 1 m threshold)', () {
      expect(isFullyCovered(1, 31), isTrue);
      expect(isFullyCovered(0.9, 31), isFalse);
    });
  });

  group('classifyCoverage', () {
    test(
        'floor: 1000 m autobahn, union 30 m (3 %) -> fraction 0 '
        '(below max(50, 50))', () {
      final datum = classifyCoverage(30, 1000);
      expect(datum.fraction, equals(0.0));
      expect(datum.isFull, isFalse);
    });

    test('just past floor: 1000 m way, union 60 m -> fraction ~0.06', () {
      final datum = classifyCoverage(60, 1000);
      expect(datum.fraction, closeTo(0.06, 1e-9));
      expect(datum.isFull, isFalse);
    });

    test('half driven: 1000 m way, union 500 m -> fraction 0.5', () {
      final datum = classifyCoverage(500, 1000);
      expect(datum.fraction, equals(0.5));
      expect(datum.isFull, isFalse);
    });

    test(
        'fully driven: 1000 m way, union 970 m -> isFull true, '
        'fraction 0.97', () {
      final datum = classifyCoverage(970, 1000);
      expect(datum.fraction, closeTo(0.97, 1e-9));
      expect(datum.isFull, isTrue);
    });

    test('wayLengthM <= 0 guard -> fraction 0, isFull false, no throw', () {
      expect(() => classifyCoverage(10, 0), returnsNormally);
      final datum = classifyCoverage(10, 0);
      expect(datum.fraction, equals(0.0));
      expect(datum.isFull, isFalse);
    });

    test('negative wayLengthM guard -> fraction 0, isFull false', () {
      final datum = classifyCoverage(10, -5);
      expect(datum.fraction, equals(0.0));
      expect(datum.isFull, isFalse);
    });

    test(
        'floor: small way (200 m), union 5 m (2.5 %) -> fraction 0 '
        '(below max(50, 10))', () {
      // floor = max(50, 200 * 0.05) = max(50, 10) = 50 m; union 5 < 50
      final datum = classifyCoverage(5, 200);
      expect(datum.fraction, equals(0.0));
    });

    test(
        'floor: small way (200 m), union 50 m -> just meets floor '
        '-> fraction 0.25', () {
      // floor = max(50, 200 * 0.05) = 50; union 50 >= 50 -> fraction = 50/200
      final datum = classifyCoverage(50, 200);
      expect(datum.fraction, equals(0.25));
    });

    test('fraction clamped at 1.0 even if union > way length', () {
      // Union can exceed way length due to GPS noise; must not produce > 1.0
      final datum = classifyCoverage(1100, 1000);
      expect(datum.fraction, equals(1.0));
      expect(datum.isFull, isTrue);
    });

    // -----------------------------------------------------------------------
    // Short-way regression (junction-gap fix):
    // A fully-driven SHORT way (< kPartialFloorMeters) MUST render, not be
    // dropped by the flat 50 m absolute floor. The floor exists to suppress
    // tiny PARTIAL clips on long ways — never to suppress a completed drive.
    // -----------------------------------------------------------------------

    test(
        'short way (25 m) driven end-to-end (25 m) -> isFull true, renders '
        '(NOT dropped by 50 m floor)', () {
      final datum = classifyCoverage(25, 25);
      expect(datum.isFull, isTrue);
      expect(datum.fraction, equals(1.0));
    });

    test(
        'short link (40 m) driven end-to-end (40 m) -> isFull true, renders '
        '(NOT dropped by 50 m floor)', () {
      final datum = classifyCoverage(40, 40);
      expect(datum.isFull, isTrue);
      expect(datum.fraction, equals(1.0));
    });

    test(
        'short link (45 m) driven 40 m (substantial partial) -> renders, '
        'fraction > 0 (floor capped at way length, not 50 m)', () {
      // isFullyCovered(40, 45): 40 >= 45 - 30 = 15 -> isFull true (buffer rule).
      final datum = classifyCoverage(40, 45);
      expect(datum.fraction, greaterThan(0.0));
    });

    test(
        'tiny clip (5 m) on short way (40 m) -> undriven '
        '(floor capped at 40 m, 5 < 40)', () {
      final datum = classifyCoverage(5, 40);
      expect(datum.fraction, equals(0.0));
      expect(datum.isFull, isFalse);
    });

    test(
        'GUARANTEE PRESERVED: 30 m clip on 1 km way -> undriven '
        '(flat 50 m floor still applies to long ways)', () {
      final datum = classifyCoverage(30, 1000);
      expect(datum.fraction, equals(0.0));
      expect(datum.isFull, isFalse);
    });
  });

  group('CoverageDatum', () {
    test('undriven() convenience constructor sets fraction 0 + isFull false',
        () {
      const datum = CoverageDatum.undriven();
      expect(datum.fraction, equals(0.0));
      expect(datum.isFull, isFalse);
    });

    test('equality by value', () {
      const a = CoverageDatum(fraction: 0.5, isFull: false);
      const b = CoverageDatum(fraction: 0.5, isFull: false);
      const c = CoverageDatum(fraction: 0.5, isFull: true);
      expect(a, equals(b));
      expect(a, isNot(equals(c)));
    });

    test('hashCode consistent with equality', () {
      const a = CoverageDatum(fraction: 0.5, isFull: false);
      const b = CoverageDatum(fraction: 0.5, isFull: false);
      expect(a.hashCode, equals(b.hashCode));
    });

    test('toString includes fraction and isFull', () {
      const datum = CoverageDatum(fraction: 0.75, isFull: true);
      expect(datum.toString(), contains('0.75'));
      expect(datum.toString(), contains('true'));
    });
  });
}
