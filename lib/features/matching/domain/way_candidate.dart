// Phase 4 rescope Wave 2: WayCandidate domain model.
//
// Shape mirrors the ways-row schema written by
// `tool/osm_pipeline/lib/output/osm_sqlite_writer.dart:488-505` (Phase 4
// bundled-osm.sqlite architecture, now retained as Phase-5 fixture generator).
// The Overpass client (04-13) and the future WayCandidateSource (04-15) both
// return `List<WayCandidate>`; the matcher (Phase 5) consumes it. Keeping the
// same field shape across both data-sources lets Phase-5 golden corpora feed
// either a pre-built osm.sqlite or a live Overpass response with zero adapter
// code in the matcher.

import 'package:maplibre_gl/maplibre_gl.dart' show LatLng;
import 'package:meta/meta.dart';

/// OSM `oneway` tag, normalized to a three-way enum.
///
/// - [OnewayDirection.no] — either the tag is absent, `no`, or the highway
///   class is not implicit-oneway. Traffic flows in both node-order and
///   reverse-node-order.
/// - [OnewayDirection.forward] — traffic flows along stored node order
///   (`oneway=yes` OR implicit-oneway highway class per OSM wiki: `motorway`,
///   `motorway_link`, `trunk_link` — NOT `trunk` itself — as locked in
///   STATE Plan 04-03).
/// - [OnewayDirection.backward] — `oneway=-1`. Per Plan 04-03 the pipeline
///   physically reverses node order at parse time so this variant should be
///   rare in practice; Overpass responses may still carry it verbatim.
enum OnewayDirection { no, forward, backward }

/// The 14-tag Kfz highway allowlist (Motor-vehicle-passable roads only).
///
/// Source: REQUIREMENTS.md OSM-02 + `.planning/phases/04-osm-pipeline/`
/// 04-CONTEXT.md ("Highway filter") + STATE Plan 04-01 (2026-07-05) —
/// `highway=service` is intentionally excluded (parking lot / driveway sprawl
/// blows the byte budget for negligible driven-experience value).
///
/// Overpass responses are filtered to this set inside
/// `OverpassResponseParser`. Any way whose `highway` tag falls outside the
/// allowlist (`path`, `cycleway`, `footway`, `track`, `service`, etc.) is
/// dropped at the parser boundary.
const kfzHighwayClasses = <String>{
  'motorway',
  'motorway_link',
  'trunk',
  'trunk_link',
  'primary',
  'primary_link',
  'secondary',
  'secondary_link',
  'tertiary',
  'tertiary_link',
  'unclassified',
  'residential',
  'living_street',
  'road',
};

/// Immutable candidate way returned by the Overpass client (or, later, any
/// implementation of `WayCandidateSource` from Plan 04-15).
///
/// Equality is based purely on [wayId] — OSM way IDs are stable across
/// data-sources, so two candidates fetched from different tiles (or from the
/// same tile at different times) with the same ID compare equal even when
/// their geometry has been re-densified upstream.
@immutable
class WayCandidate {
  const WayCandidate({
    required this.wayId,
    required this.geometry,
    required this.highwayClass,
    this.name,
    this.ref,
    this.oneway = OnewayDirection.no,
    this.maxspeedKmh,
  });

  /// OSM way id (`elements[].id` in the Overpass JSON response).
  final int wayId;

  /// Ordered polyline of geographic points; two entries minimum.
  final List<LatLng> geometry;

  /// Value of the `highway=` tag. Guaranteed to be a member of
  /// [kfzHighwayClasses] when produced by `OverpassResponseParser`.
  final String highwayClass;

  /// Value of the `name=` tag, if present.
  final String? name;

  /// Value of the `ref=` tag (e.g. `A9`, `B27`), if present.
  final String? ref;

  /// Normalized `oneway=` tag; defaults to [OnewayDirection.no].
  final OnewayDirection oneway;

  /// Speed limit in km/h; null when the `maxspeed=` tag is absent, non-numeric
  /// (`signals`, `walk`, `variable`), or a variant we cannot safely coerce
  /// (units other than `kmh`/`mph`).
  final int? maxspeedKmh;

  @override
  bool operator ==(Object other) =>
      other is WayCandidate && other.wayId == wayId;

  @override
  int get hashCode => wayId.hashCode;

  @override
  String toString() =>
      'WayCandidate(wayId: $wayId, highwayClass: $highwayClass, '
      'points: ${geometry.length}, name: $name, ref: $ref, '
      'oneway: $oneway, maxspeedKmh: $maxspeedKmh)';
}
