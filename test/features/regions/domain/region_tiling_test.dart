// Trailblazer 2026-07-14: unit tests for region_tiling — the shared cell-count
// + progress-parse helpers behind smallest-first ordering and the region-card
// progress label.

import 'dart:convert';

import 'package:auto_explore/features/regions/domain/region_tiling.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('plannedCellCount', () {
    test('2-cell bbox (0.19° lon × 0.09° lat at 0.1° tiling) → 2', () {
      // Matches the region_total_length_service test fixture: 49.7..49.79 lat
      // (one row) × 9.1..9.29 lon (two columns).
      expect(plannedCellCount(49.7, 9.1, 49.79, 9.29), 2);
    });

    test('single tiny cell → 1', () {
      expect(plannedCellCount(49.70, 9.10, 49.72, 9.12), 1);
    });

    test('degenerate (zero/negative area) bbox → 0', () {
      expect(plannedCellCount(50, 8, 50, 9), 0);
      expect(plannedCellCount(50, 8, 49, 9), 0);
    });

    test('large bbox tiles into many cells (~10×10 grid, float-inclusive)', () {
      // 1.0° × 1.0° at 0.1°. Float accumulation of `lat + 0.1` makes the grid
      // slightly inclusive at the far edge (~11 rows), so the count is ~110,
      // not a clean 100 — plannedCellCount faithfully mirrors the service's
      // _tileBbox, which is the point (the shown count == the work done).
      final n = plannedCellCount(50, 8, 51, 9);
      expect(n, greaterThanOrEqualTo(100));
      expect(n, lessThanOrEqualTo(121));
    });
  });

  group('completedCellCount', () {
    String blob(Map<String, double> cells, {int v = 1, double tiles = 0.1}) =>
        jsonEncode({'v': v, 'tiles': tiles, 'cells': cells});

    test('valid blob → number of recorded cells', () {
      expect(completedCellCount(blob({'a': 1, 'b': 2, 'c': 3})), 3);
      expect(completedCellCount(blob({})), 0);
    });

    test('null / empty input → null', () {
      expect(completedCellCount(null), isNull);
      expect(completedCellCount(''), isNull);
    });

    test('stale version → null', () {
      expect(completedCellCount(blob({'a': 1}, v: 2)), isNull);
    });

    test('mismatched tiling constant → null', () {
      expect(completedCellCount(blob({'a': 1}, tiles: 0.2)), isNull);
    });

    test('malformed JSON → null (never throws)', () {
      expect(completedCellCount('{not json'), isNull);
      expect(completedCellCount('[]'), isNull);
    });
  });
}
