// Trailblazer 2026-07-11 jump-to-map centering fix:
// AdminRegion.labelPoint returns the pole of inaccessibility (where the map
// draws the region name), NOT the bbox center. For irregular / concave
// regions the bbox center falls outside the polygon; labelPoint must always
// land inside so "Jump to on map" centers on the visible label.

import 'package:auto_explore/features/admin/data/admin_region.dart';
import 'package:flutter_test/flutter_test.dart';

/// Builds a single-polygon region from an outer ring of `[lat, lon]` points.
AdminRegion _region(List<List<double>> ring) {
  var minLat = double.infinity;
  var maxLat = -double.infinity;
  var minLon = double.infinity;
  var maxLon = -double.infinity;
  for (final p in ring) {
    if (p[0] < minLat) minLat = p[0];
    if (p[0] > maxLat) maxLat = p[0];
    if (p[1] < minLon) minLon = p[1];
    if (p[1] > maxLon) maxLon = p[1];
  }
  return AdminRegion(
    osmId: 1,
    adminLevel: 8,
    name: 'Test',
    bboxMinLat: minLat,
    bboxMinLon: minLon,
    bboxMaxLat: maxLat,
    bboxMaxLon: maxLon,
    polygons: [
      [ring],
    ],
  );
}

void main() {
  group('AdminRegion.labelPoint', () {
    test('square: label point is inside, near the center', () {
      final r = _region(const [
        [0, 0],
        [0, 10],
        [10, 10],
        [10, 0],
        [0, 0],
      ]);
      final p = r.labelPoint;
      expect(r.containsPoint(p[0], p[1]), isTrue);
      expect(p[0], closeTo(5, 1.0));
      expect(p[1], closeTo(5, 1.0));
    });

    test('C-shape: label point is inside the polygon (bbox center is not)', () {
      // A "C" opening to the right (+lon). Its bbox is the full 0..10 square,
      // whose center (5,5) sits in the mouth of the C — OUTSIDE the polygon.
      const ring = [
        [0.0, 0.0],
        [0.0, 10.0],
        [10.0, 10.0],
        [10.0, 7.0],
        [3.0, 7.0],
        [3.0, 3.0],
        [10.0, 3.0],
        [10.0, 0.0],
        [0.0, 0.0],
      ];
      final r = _region(ring);

      // Precondition: the bbox center really is outside (this is why the old
      // bbox-center centering missed the label).
      expect(
        r.containsPoint(5, 5),
        isFalse,
        reason: 'bbox center must be outside the C for this test to be valid',
      );

      // labelPoint must land INSIDE the polygon.
      final p = r.labelPoint;
      expect(
        r.containsPoint(p[0], p[1]),
        isTrue,
        reason: 'label point must be inside the region',
      );
      // For a C opening to +lon, the deepest interior is in the left bar
      // (small lon), not the mouth.
      expect(p[1], lessThan(5));
    });

    test('degenerate ring falls back to bbox center', () {
      const r = AdminRegion(
        osmId: 2,
        adminLevel: 8,
        name: 'Empty',
        bboxMinLat: 1,
        bboxMinLon: 2,
        bboxMaxLat: 3,
        bboxMaxLon: 4,
        polygons: [],
      );
      final p = r.labelPoint;
      expect(p[0], 2); // (1+3)/2
      expect(p[1], 3); // (2+4)/2
    });

    test('multipolygon: labels the LARGEST part', () {
      // Tiny square near (0,0) + big square near (100,100). Label the big one.
      const r = AdminRegion(
        osmId: 3,
        adminLevel: 8,
        name: 'Multi',
        bboxMinLat: 0,
        bboxMinLon: 0,
        bboxMaxLat: 110,
        bboxMaxLon: 110,
        polygons: [
          [
            [
              [0.0, 0.0],
              [0.0, 1.0],
              [1.0, 1.0],
              [1.0, 0.0],
              [0.0, 0.0],
            ],
          ],
          [
            [
              [100.0, 100.0],
              [100.0, 110.0],
              [110.0, 110.0],
              [110.0, 100.0],
              [100.0, 100.0],
            ],
          ],
        ],
      );
      final p = r.labelPoint;
      // Should be in the big square (100..110), not the tiny one (0..1).
      expect(p[0], greaterThan(100));
      expect(p[1], greaterThan(100));
    });
  });
}
