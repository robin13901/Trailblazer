/// End-to-end admin-region extraction stage.
///
/// Consumes a `.osm.pbf` via [PbfReader], assembles multipolygon geometries,
/// and pushes rows into an [AdminScratchWriter]. Runs as three sequential
/// streaming passes over the PBF (relations → member ways → member nodes) —
/// clarity over throughput per 04-04-PLAN.md; 04-06 may collapse passes.
///
/// The Berlin/Hamburg/Bremen dual-write (04-RESEARCH.md §12 pitfall #10)
/// lives inside [extractAdminRegions] — city-state level-4 relations are
/// written a SECOND time as level-6 rows, so downstream focus-area lookups
/// find them under both Bundesland and Gemeinde queries.
library;

import 'dart:io';

import 'package:osm_pipeline/admin/admin_relation_filter.dart';
import 'package:osm_pipeline/admin/multipolygon_assembler.dart';
import 'package:osm_pipeline/admin/wkb_writer.dart';
import 'package:osm_pipeline/pbf/entities.dart';
import 'package:osm_pipeline/pbf/pbf_reader.dart';
import 'package:osm_pipeline/scratch/scratch_db_admin_ext.dart';

/// Result summary from [extractAdminRegions].
class AdminExtractionSummary {
  /// Create a summary.
  const AdminExtractionSummary({
    required this.relationsSeen,
    required this.relationsAccepted,
    required this.regionsWritten,
    required this.dualWrites,
    required this.rejected,
  });

  /// Total OSM relations observed in the PBF (any type).
  final int relationsSeen;

  /// Relations that passed [isAdminRelation].
  final int relationsAccepted;

  /// Rows written to `admin_regions_raw` (includes dual-writes).
  final int regionsWritten;

  /// Number of city-state dual-writes (level-4 → level-6 duplicates).
  final int dualWrites;

  /// Accepted relations that produced no usable geometry (all rings
  /// skipped, no name, etc.) — logged and not written.
  final int rejected;
}

/// Runs the admin extraction stage against [pbf], writing rows via [writer].
///
/// All skipped rings, missing refs, self-intersections, and rejected
/// relations are appended to [skippedLog] (may be `null` in tests).
Future<AdminExtractionSummary> extractAdminRegions({
  required File pbf,
  required AdminScratchWriter writer,
  IOSink? skippedLog,
}) async {
  // --- Pass A: collect admin relations + their member way ids. ---
  final admins = <OsmRelation>[];
  final relevantWayIds = <int>{};
  var relationsSeen = 0;
  await for (final e in PbfReader().stream(pbf)) {
    if (e is OsmRelation) {
      relationsSeen++;
      if (isAdminRelation(e)) {
        admins.add(e);
        for (final m in e.members) {
          if (m.type == OsmMemberType.way) relevantWayIds.add(m.refId);
        }
      }
    }
  }

  if (admins.isEmpty) {
    return AdminExtractionSummary(
      relationsSeen: relationsSeen,
      relationsAccepted: 0,
      regionsWritten: 0,
      dualWrites: 0,
      rejected: 0,
    );
  }

  // --- Pass B: collect member ways referenced by admin relations. ---
  final waysById = <int, OsmWay>{};
  final relevantNodeIds = <int>{};
  await for (final e in PbfReader().stream(pbf)) {
    if (e is OsmWay && relevantWayIds.contains(e.id)) {
      waysById[e.id] = e;
      relevantNodeIds.addAll(e.nodeRefs);
    }
  }

  // --- Pass C: collect nodes referenced by admin ways. ---
  final nodesById = <int, ({double lat, double lng})>{};
  await for (final e in PbfReader().stream(pbf)) {
    if (e is OsmNode && relevantNodeIds.contains(e.id)) {
      nodesById[e.id] = (lat: e.lat, lng: e.lng);
    }
  }

  // --- Pass D: assemble + write. ---
  writer.applyAdminSchema();
  var regionId = 0;
  var dualWrites = 0;
  var rejected = 0;
  for (final rel in admins) {
    try {
      final mp = MultipolygonAssembler.assemble(
        rel,
        waysById,
        (int nid) => nodesById[nid],
        skippedLog,
      );
      if (mp == null || mp.isEmpty) {
        rejected++;
        _log(skippedLog, 'SKIP relation ${rel.id}: no usable geometry');
        continue;
      }
      final lvl = int.parse(rel.tags['admin_level']!);
      final name = rel.tags['name'] ?? '';
      if (name.isEmpty) {
        rejected++;
        _log(skippedLog, 'SKIP relation ${rel.id}: no name tag');
        continue;
      }

      final wkb = encodeMultiPolygon(mp);
      final b = mp.bbox();

      regionId++;
      await writer.insertAdminRegion(
        regionId: regionId,
        osmRelationId: rel.id,
        adminLevel: lvl,
        name: name,
        geometryWkb: wkb,
        bboxMinLat: b.minLat,
        bboxMaxLat: b.maxLat,
        bboxMinLng: b.minLng,
        bboxMaxLng: b.maxLng,
      );

      // Pitfall #10: Berlin/Hamburg/Bremen dual-write at level 6.
      if (lvl == 4 && kCityStateNames.contains(name)) {
        regionId++;
        dualWrites++;
        await writer.insertAdminRegion(
          regionId: regionId,
          osmRelationId: rel.id,
          adminLevel: 6,
          name: name,
          geometryWkb: wkb,
          bboxMinLat: b.minLat,
          bboxMaxLat: b.maxLat,
          bboxMinLng: b.minLng,
          bboxMaxLng: b.maxLng,
        );
        _log(
          skippedLog,
          'INFO dual-write city-state relation ${rel.id} $name at level 6',
        );
      }
    } on Object catch (err, st) {
      rejected++;
      _log(
        skippedLog,
        'ERR relation ${rel.id} assembly failed: $err',
      );
      _log(skippedLog, st.toString());
    }
  }

  return AdminExtractionSummary(
    relationsSeen: relationsSeen,
    relationsAccepted: admins.length,
    regionsWritten: regionId,
    dualWrites: dualWrites,
    rejected: rejected,
  );
}

void _log(IOSink? sink, String line) {
  if (sink == null) return;
  sink.writeln(line);
}
