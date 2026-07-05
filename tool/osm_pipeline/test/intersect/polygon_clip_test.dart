import 'package:osm_pipeline/intersect/polygon_clip.dart';
import 'package:osm_pipeline/intersect/vec2.dart';
import 'package:test/test.dart';

// A 100 m × 100 m-ish CCW square at ~52.5N. Coordinates chosen so that
// 0.001° in lat ≈ 111 m and 0.001° in lng at lat 52.5° ≈ 68 m. Precise
// distances are checked via haversine when needed.
ClipMultiPolygon _square() => const ClipMultiPolygon([
      ClipPolygon(
        outer: [
          Vec2(13.4000, 52.5000),
          Vec2(13.4020, 52.5000),
          Vec2(13.4020, 52.5015),
          Vec2(13.4000, 52.5015),
          Vec2(13.4000, 52.5000),
        ],
      ),
    ]);

// A donut: outer square with a smaller inner-hole square in the middle.
ClipMultiPolygon _donut() => const ClipMultiPolygon([
      ClipPolygon(
        outer: [
          Vec2(13.4000, 52.5000),
          Vec2(13.4020, 52.5000),
          Vec2(13.4020, 52.5015),
          Vec2(13.4000, 52.5015),
          Vec2(13.4000, 52.5000),
        ],
        holes: [
          // Inner ring: CW-oriented (hole).
          [
            Vec2(13.4007, 52.5005),
            Vec2(13.4007, 52.5010),
            Vec2(13.4013, 52.5010),
            Vec2(13.4013, 52.5005),
            Vec2(13.4007, 52.5005),
          ],
        ],
      ),
    ]);

void main() {
  group('clipLinestringToPolygon', () {
    test('line entirely inside square → one subsegment covering the whole', () {
      final line = [
        const Vec2(13.4005, 52.5005),
        const Vec2(13.4015, 52.5010),
      ];
      final r = clipLinestringToPolygon(line, _square());
      expect(r, hasLength(1));
      expect(r.first.fractionStart, closeTo(0.0, 1e-9));
      expect(r.first.fractionEnd, closeTo(1.0, 1e-9));
      expect(r.first.points, hasLength(2));
    });

    test('line entirely outside square → empty list', () {
      final line = [
        const Vec2(13.5000, 52.6000),
        const Vec2(13.6000, 52.7000),
      ];
      final r = clipLinestringToPolygon(line, _square());
      expect(r, isEmpty);
    });

    test('line enters and exits once → one subsegment with 0<start && end<1',
        () {
      final line = [
        const Vec2(13.3990, 52.5008), // outside (west of square)
        const Vec2(13.4030, 52.5008), // outside (east of square)
      ];
      final r = clipLinestringToPolygon(line, _square());
      expect(r, hasLength(1));
      expect(r.first.fractionStart, greaterThan(0.0));
      expect(r.first.fractionEnd, lessThan(1.0));
      // Sanity: the fraction span roughly matches the ratio of square-width
      // (0.002° in lng) to line-width (0.004°) → 0.5.
      final span = r.first.fractionEnd - r.first.fractionStart;
      expect(span, closeTo(0.5, 0.05));
    });

    test('line enters, exits, re-enters → two subsegments', () {
      // A horizontal line that runs west→east across two disjoint squares.
      // We fake this by placing a MultiPolygon with two side-by-side squares.
      const twoSquares = ClipMultiPolygon([
        ClipPolygon(
          outer: [
            Vec2(13.4000, 52.5005),
            Vec2(13.4010, 52.5005),
            Vec2(13.4010, 52.5015),
            Vec2(13.4000, 52.5015),
            Vec2(13.4000, 52.5005),
          ],
        ),
        ClipPolygon(
          outer: [
            Vec2(13.4020, 52.5005),
            Vec2(13.4030, 52.5005),
            Vec2(13.4030, 52.5015),
            Vec2(13.4020, 52.5015),
            Vec2(13.4020, 52.5005),
          ],
        ),
      ]);
      final line = [
        const Vec2(13.3995, 52.5010), // west of first square
        const Vec2(13.4035, 52.5010), // east of second square
      ];
      final r = clipLinestringToPolygon(line, twoSquares);
      expect(r, hasLength(2));
      expect(r[0].fractionStart, lessThan(r[1].fractionStart));
      expect(r[0].fractionEnd, lessThan(r[1].fractionStart));
    });

    test('line touches vertex only → dropped by epsilon', () {
      final line = [
        const Vec2(13.3990, 52.4995),
        const Vec2(13.4000, 52.5000), // exactly at a corner
        const Vec2(13.3985, 52.4990),
      ];
      final r = clipLinestringToPolygon(line, _square());
      // Either 0 subsegments (tie-break rejects) or a sub-metre run that
      // epsilon-drops. Both are acceptable per the plan.
      expect(r, isEmpty);
    });

    test('line runs 100 m along an edge → assigned to polygon (left-of-line)',
        () {
      // The square's south edge is lat=52.5000, running lng=13.4000 →
      // 13.4020. Line runs west→east ALONG that edge. Direction of travel is
      // +lng; "left" of that in the (x=lng,y=lat) frame is +lat, which is
      // INTO the polygon. Expect the line to be assigned to the polygon.
      final line = [
        const Vec2(13.4003, 52.5000),
        const Vec2(13.4017, 52.5000),
      ];
      final r = clipLinestringToPolygon(line, _square());
      expect(r, hasLength(1));
      expect(r.first.fractionStart, closeTo(0.0, 1e-9));
      expect(r.first.fractionEnd, closeTo(1.0, 1e-9));
    });

    test('donut: line crossing the hole → two subsegments', () {
      // Horizontal line spanning outer square, crossing the hole.
      final line = [
        const Vec2(13.4001, 52.5008), // inside outer, left of hole
        const Vec2(13.4019, 52.5008), // inside outer, right of hole
      ];
      final r = clipLinestringToPolygon(line, _donut());
      expect(r, hasLength(2));
      // First subseg starts near line-start (~0), ends before hole.
      expect(r[0].fractionStart, closeTo(0.0, 0.05));
      expect(r[0].fractionEnd, lessThan(r[1].fractionStart));
      // Second subseg ends near line-end.
      expect(r[1].fractionEnd, closeTo(1.0, 0.05));
    });

    test('sub-metre clip artefact is dropped by 1 m epsilon', () {
      // Line that clips the corner by ~0.5 m. We use a very small triangle
      // clip.
      final line = [
        const Vec2(13.399998, 52.500000),
        const Vec2(13.400002, 52.499996),
      ];
      final r = clipLinestringToPolygon(line, _square());
      expect(r, isEmpty);
    });
  });

  group('haversineMeters', () {
    test('reasonable magnitude at 52.5°N', () {
      // 0.001° in lat ≈ 111 m.
      final d = haversineMeters(
        const Vec2(13.4, 52.5),
        const Vec2(13.4, 52.501),
      );
      expect(d, closeTo(111.2, 1.0));
    });
  });

  group('pointInRing', () {
    test('interior point returns true', () {
      final ring = [
        const Vec2(0, 0),
        const Vec2(1, 0),
        const Vec2(1, 1),
        const Vec2(0, 1),
        const Vec2(0, 0),
      ];
      expect(pointInRing(const Vec2(0.5, 0.5), ring), isTrue);
    });

    test('exterior point returns false', () {
      final ring = [
        const Vec2(0, 0),
        const Vec2(1, 0),
        const Vec2(1, 1),
        const Vec2(0, 1),
        const Vec2(0, 0),
      ];
      expect(pointInRing(const Vec2(2, 2), ring), isFalse);
    });
  });

  group('segmentIntersection', () {
    test('cross returns interior point', () {
      final hit = segmentIntersection(
        const Vec2(0, 0),
        const Vec2(2, 2),
        const Vec2(0, 2),
        const Vec2(2, 0),
      );
      expect(hit, isNotNull);
      expect(hit!.point.lng, closeTo(1, 1e-9));
      expect(hit.point.lat, closeTo(1, 1e-9));
      expect(hit.collinear, isFalse);
    });

    test('parallel non-collinear returns null', () {
      final hit = segmentIntersection(
        const Vec2(0, 0),
        const Vec2(1, 0),
        const Vec2(0, 1),
        const Vec2(1, 1),
      );
      expect(hit, isNull);
    });

    test('collinear overlap returns collinear=true', () {
      final hit = segmentIntersection(
        const Vec2(0, 0),
        const Vec2(2, 0),
        const Vec2(1, 0),
        const Vec2(3, 0),
      );
      expect(hit, isNotNull);
      expect(hit!.collinear, isTrue);
    });
  });
}
