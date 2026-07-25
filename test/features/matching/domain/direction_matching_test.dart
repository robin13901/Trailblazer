// #11 direction term (dual-carriageway fix) — decoder-level scenario tests.
//
// The direction term penalizes a `oneway` candidate whose LEGAL travel bearing
// disagrees with the vehicle's travel direction. It is inert on `oneway=no`
// ways and when no trustworthy direction exists (low speed / no heading / tiny
// move). These tests exercise all four branches:
//   1. dual carriageway — heading keeps an overtaking fix on the correct
//      (east-bound) carriageway even when it is perpendicularly closer to the
//      west-bound one.
//   2. oneway=no identical geometry → term inert (emission identical with and
//      without heading).
//   3. low-speed / no-heading → identical to pre-change (heading ignored).
//   4. headingDegrees=null but moving → derived bearing still steers correctly.

import 'package:auto_explore/features/matching/domain/gps_fix.dart';
import 'package:auto_explore/features/matching/domain/viterbi_decoder.dart';
import 'package:auto_explore/features/matching/domain/way_candidate.dart';
import 'package:auto_explore/features/matching/domain/way_segment_index.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart' show LatLng;

// ---------------------------------------------------------------------------
// Geometry helpers
// ---------------------------------------------------------------------------

const double _lat0 = 49.700;

/// ~15 m north of [_lat0] (15 / 111320).
const double _lat15mNorth = _lat0 + 15 / 111320;

/// A straight W→E way from lon 9.000 to 9.002 at latitude [lat].
WayCandidate _ewWay({
  required int wayId,
  required double lat,
  required OnewayDirection oneway,
}) =>
    WayCandidate(
      wayId: wayId,
      highwayClass: 'primary',
      oneway: oneway,
      geometry: [
        for (var i = 0; i <= 4; i++) LatLng(lat, 9.000 + i * 0.0005),
      ],
    );

void main() {
  // -------------------------------------------------------------------------
  // 1. Dual carriageway: heading pins overtaking fixes to the east-bound side.
  // -------------------------------------------------------------------------
  test('1. dual carriageway — heading keeps overtaking fixes on east-bound', () {
    // East-bound carriageway (legal travel East, bearing 90) at lat0, stored
    // W→E with oneway=forward. West-bound carriageway ~15 m north, stored W→E
    // with oneway=backward so its LEGAL travel is West (270).
    final eastBound = _ewWay(
      wayId: 1,
      lat: _lat0,
      oneway: OnewayDirection.forward,
    );
    final westBound = _ewWay(
      wayId: 2,
      lat: _lat15mNorth,
      oneway: OnewayDirection.backward,
    );
    final index = WaySegmentIndex.buildFromWays([eastBound, westBound]);
    const decoder = ViterbiDecoder();

    // Eastbound trace, heading due East (90). Fixes 1 and 2 are noised ~10 m
    // north (toward the west-bound carriageway) — an overtaking wobble that a
    // perp-only decoder would snap to way 2. Heading must keep them on way 1.
    const noiseNorthDeg = 10 / 111320;
    final base = DateTime.utc(2026, 7, 25, 12);
    final fixes = <GpsFix>[
      for (var i = 0; i < 5; i++)
        GpsFix(
          lat: _lat0 + ((i == 1 || i == 2) ? noiseNorthDeg : 0.0),
          lon: 9.000 + i * 0.0005,
          accuracyMeters: 5,
          speedKmh: 50,
          headingDegrees: 90,
          ts: base.add(Duration(seconds: i)),
        ),
    ];

    final result = decoder.decode(fixes, index);
    expect(result, hasLength(5));
    for (var i = 0; i < 5; i++) {
      expect(result[i], isNotNull, reason: 'fix $i should match');
      expect(
        result[i]!.wayId,
        equals(1),
        reason: 'fix $i must stay on the east-bound carriageway (heading 90); '
            'got way ${result[i]!.wayId}',
      );
    }
  });

  // -------------------------------------------------------------------------
  // 2. oneway=no identical geometry → direction term is inert.
  // -------------------------------------------------------------------------
  test('2. oneway=no way — direction term contributes nothing to emission', () {
    final twoWay = _ewWay(wayId: 3, lat: _lat0, oneway: OnewayDirection.no);
    final index = WaySegmentIndex.buildFromWays([twoWay]);
    const decoder = ViterbiDecoder();

    final base = DateTime.utc(2026, 7, 25, 12);
    // Same trace twice: once WITH a heading, once WITHOUT. On a oneway=no way
    // the emission (which absorbs the direction term) must be byte-identical.
    List<GpsFix> trace({required bool withHeading}) => [
          for (var i = 0; i < 5; i++)
            GpsFix(
              lat: _lat0,
              lon: 9.000 + i * 0.0005,
              accuracyMeters: 5,
              speedKmh: 50,
              headingDegrees: withHeading ? 90 : null,
              ts: base.add(Duration(seconds: i)),
            ),
        ];

    final withHdg = decoder.decode(trace(withHeading: true), index);
    final noHdg = decoder.decode(trace(withHeading: false), index);
    expect(withHdg, hasLength(5));
    for (var i = 0; i < 5; i++) {
      expect(withHdg[i]!.wayId, equals(noHdg[i]!.wayId));
      expect(
        withHdg[i]!.emissionLogP,
        equals(noHdg[i]!.emissionLogP),
        reason: 'oneway=no: heading must not perturb emission at fix $i',
      );
    }
  });

  // -------------------------------------------------------------------------
  // 3. Low speed / no movement → heading ignored (identical to pre-change).
  // -------------------------------------------------------------------------
  test('3. low speed → direction term skipped (identical with/without heading)',
      () {
    // A oneway=forward way. At speed < kDirMinSpeedKmh the OS heading is not
    // trusted, and near-stationary fixes move < kDirMinMoveMeters so no derived
    // bearing either → the term is skipped, so a WRONG heading changes nothing.
    final oneway = _ewWay(wayId: 4, lat: _lat0, oneway: OnewayDirection.forward);
    final index = WaySegmentIndex.buildFromWays([oneway]);
    const decoder = ViterbiDecoder();

    final base = DateTime.utc(2026, 7, 25, 12);
    // All fixes at essentially the same spot (< 5 m apart), speed 3 km/h.
    List<GpsFix> trace({double? heading}) => [
          for (var i = 0; i < 4; i++)
            GpsFix(
              lat: _lat0,
              lon: 9.0010 + i * 0.00002, // ~1.4 m steps → below move floor
              accuracyMeters: 5,
              speedKmh: 3, // < kDirMinSpeedKmh
              headingDegrees: heading,
              ts: base.add(Duration(seconds: i)),
            ),
        ];

    // A deliberately WRONG heading (270 = West, opposing the way's legal East).
    final wrongHdg = decoder.decode(trace(heading: 270), index);
    final noHdg = decoder.decode(trace(), index);
    for (var i = 0; i < 4; i++) {
      expect(wrongHdg[i]!.wayId, equals(noHdg[i]!.wayId));
      expect(
        wrongHdg[i]!.emissionLogP,
        equals(noHdg[i]!.emissionLogP),
        reason: 'low-speed fix $i: wrong heading must be ignored',
      );
    }
  });

  // -------------------------------------------------------------------------
  // 4. headingDegrees=null but moving → derived bearing steers correctly.
  // -------------------------------------------------------------------------
  test('4. null heading but moving — derived bearing picks correct carriageway',
      () {
    final eastBound = _ewWay(
      wayId: 1,
      lat: _lat0,
      oneway: OnewayDirection.forward,
    );
    final westBound = _ewWay(
      wayId: 2,
      lat: _lat15mNorth,
      oneway: OnewayDirection.backward,
    );
    final index = WaySegmentIndex.buildFromWays([eastBound, westBound]);
    const decoder = ViterbiDecoder();

    // No OS heading at all, but the fixes clearly progress east → the decoder
    // derives a ~90° bearing from consecutive fixes. Fixes 2 and 3 are noised
    // north toward the west-bound carriageway (fix 0/1 clean to anchor).
    const noiseNorthDeg = 10 / 111320;
    final base = DateTime.utc(2026, 7, 25, 12);
    final fixes = <GpsFix>[
      for (var i = 0; i < 5; i++)
        GpsFix(
          lat: _lat0 + ((i == 2 || i == 3) ? noiseNorthDeg : 0.0),
          lon: 9.000 + i * 0.0005,
          accuracyMeters: 5,
          speedKmh: 50,
          ts: base.add(Duration(seconds: i)),
        ),
    ];

    final result = decoder.decode(fixes, index);
    expect(result, hasLength(5));
    // The noised fixes (2, 3) — where the derived bearing does the work — must
    // stay on the east-bound carriageway.
    for (final i in [2, 3]) {
      expect(result[i], isNotNull, reason: 'fix $i should match');
      expect(
        result[i]!.wayId,
        equals(1),
        reason: 'fix $i (derived east bearing) must stay east-bound; '
            'got way ${result[i]!.wayId}',
      );
    }
  });
}
