import 'package:auto_explore/features/map/domain/road_snap_heading.dart';
import 'package:auto_explore/features/matching/domain/way_candidate.dart';
import 'package:auto_explore/features/matching/domain/way_segment.dart';
import 'package:flutter_test/flutter_test.dart';

/// Builds a [WaySegment] from a→b with a given oneway direction. Coordinates
/// are near 50°N (Kleinheubach latitude) so bearings are realistic for the
/// project's test corridor.
WaySegment _seg({
  required double aLat,
  required double aLon,
  required double bLat,
  required double bLon,
  OnewayDirection oneway = OnewayDirection.no,
}) =>
    WaySegment(
      wayId: 1,
      segIdx: 0,
      aLat: aLat,
      aLon: aLon,
      bLat: bLat,
      bLon: bLon,
      highwayClass: 'residential',
      oneway: oneway,
    );

void main() {
  group('headingDelta', () {
    test('returns 0 for identical bearings', () {
      expect(headingDelta(90, 90), 0);
    });

    test('takes the shortest arc across the 0/360 wrap', () {
      expect(headingDelta(350, 10), closeTo(20, 1e-9));
      expect(headingDelta(10, 350), closeTo(20, 1e-9));
    });

    test('never exceeds 180', () {
      expect(headingDelta(0, 270), closeTo(90, 1e-9));
      expect(headingDelta(0, 179), closeTo(179, 1e-9));
      expect(headingDelta(0, 181), closeTo(179, 1e-9));
    });
  });

  group('segmentTravelBearing', () {
    // A due-east segment: a → b tangent ≈ 90°, reverse ≈ 270°.
    final eastSeg = _seg(aLat: 50, aLon: 9, bLat: 50, bLon: 9.001);

    test('tangent is ~east for a west→east segment', () {
      // Raw heading east: should pick the a→b tangent (~90°).
      expect(segmentTravelBearing(eastSeg, 90), closeTo(90, 1.0));
    });

    test('flips to reverse tangent when raw heading is opposite', () {
      // Driving west along the same physical road: pick reverse (~270°).
      expect(segmentTravelBearing(eastSeg, 270), closeTo(270, 1.0));
    });

    test('snaps to road axis even when raw heading is noisy', () {
      // Raw heading is off by 25° but clearly eastbound → still snaps to ~90°.
      final snapped = segmentTravelBearing(eastSeg, 65);
      expect(snapped, closeTo(90, 1.0));
    });

    test('picks the nearer of the two tangent directions at the boundary', () {
      // 179° raw → closer to the 90° tangent than to 270°.
      expect(segmentTravelBearing(eastSeg, 179), closeTo(90, 1.0));
      // 181° raw → closer to the 270° reverse.
      expect(segmentTravelBearing(eastSeg, 181), closeTo(270, 1.0));
    });

    group('fallback when raw heading is null', () {
      test('oneway=no uses the stored a→b tangent', () {
        expect(
          segmentTravelBearing(
            _seg(aLat: 50, aLon: 9, bLat: 50, bLon: 9.001),
            null,
          ),
          closeTo(90, 1.0),
        );
      });

      test('oneway=forward uses the stored a→b tangent', () {
        expect(
          segmentTravelBearing(
            _seg(
              aLat: 50,
              aLon: 9,
              bLat: 50,
              bLon: 9.001,
              oneway: OnewayDirection.forward,
            ),
            null,
          ),
          closeTo(90, 1.0),
        );
      });

      test('oneway=backward uses the reverse tangent', () {
        expect(
          segmentTravelBearing(
            _seg(
              aLat: 50,
              aLon: 9,
              bLat: 50,
              bLon: 9.001,
              oneway: OnewayDirection.backward,
            ),
            null,
          ),
          closeTo(270, 1.0),
        );
      });
    });
  });

  group('blendHeading', () {
    test('returns the road bearing unchanged when raw heading is null', () {
      expect(blendHeading(120, null), 120);
    });

    test('road-dominant blend leans toward the road bearing', () {
      // road 90, raw 100, default roadWeight 0.8 → closer to 90 than midpoint.
      final blended = blendHeading(90, 100);
      expect(blended, greaterThan(90));
      expect(blended, lessThan(94));
    });

    test('roadWeight 1.0 ignores the raw heading', () {
      expect(blendHeading(90, 270, roadWeight: 1), closeTo(90, 1e-6));
    });

    test('roadWeight 0.0 follows the raw heading', () {
      expect(blendHeading(90, 200, roadWeight: 0), closeTo(200, 1e-6));
    });

    test('blends across the 0/360 wrap along the shortest arc', () {
      // road 350, raw 10, equal weight → ~0/360, NOT ~180.
      final blended = blendHeading(350, 10, roadWeight: 0.5);
      final delta = headingDelta(blended, 0);
      expect(delta, lessThan(1.0));
    });
  });
}
