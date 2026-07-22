// Trailblazer trips: unit tests for the shared trip-formatting helpers that
// gained formatSpeed (2026-07-22, trip detail sheet).

import 'package:auto_explore/features/trips/presentation/widgets/trip_card.dart'
    show formatSpeed;
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('formatSpeed', () {
    test('derives km/h from distance / duration', () {
      // 28400 m over 42 min (2520 s) → 28400/2520*3.6 ≈ 40.57 → 41 km/h.
      expect(formatSpeed(28400, 42 * 60), '41 km/h');
    });

    test('rounds to the nearest km/h', () {
      // 1000 m over 100 s → 36.0 km/h exactly.
      expect(formatSpeed(1000, 100), '36 km/h');
    });

    test('null distance → dash', () {
      expect(formatSpeed(null, 600), '—');
    });

    test('null duration → dash', () {
      expect(formatSpeed(5000, null), '—');
    });

    test('zero duration → dash (no divide-by-zero)', () {
      expect(formatSpeed(5000, 0), '—');
    });
  });
}
