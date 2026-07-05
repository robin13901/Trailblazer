/// Admin-side scratch DB contract + writer implementations.
///
/// 04-04 owns the admin extraction stage. Its scratch-write path is defined
/// here as an abstract contract so:
///
///   * The stage does not depend on 04-03's `ScratchDb` type at compile time
///     for tests (the [InMemoryAdminScratchWriter] path stays hermetic).
///   * The CLI + pipeline orchestrator (04-06) wire [ScratchDbAdminWriter]
///     on top of 04-03's `ScratchDb.raw` sqlite handle without 04-04
///     modifying any file 04-03 owns.
///
/// See 04-04-PLAN.md "File-ownership note" for the coordination rationale.
library;

import 'dart:typed_data';

import 'package:osm_pipeline/scratch/admin_scratch_schema.dart';
import 'package:osm_pipeline/scratch/scratch_db.dart';
import 'package:sqlite3/sqlite3.dart';

/// Sink for admin-region rows produced by the extraction stage.
abstract interface class AdminScratchWriter {
  /// Applies the CREATE statements from `admin_scratch_schema.dart`.
  ///
  /// Must be called exactly once, before any [insertAdminRegion] call.
  /// Idempotent-per-run: the underlying scratch DB is single-use.
  void applyAdminSchema();

  /// Inserts a single admin-region row.
  Future<void> insertAdminRegion({
    required int regionId,
    required int osmRelationId,
    required int adminLevel,
    required String name,
    required Uint8List geometryWkb,
    required double bboxMinLat,
    required double bboxMaxLat,
    required double bboxMinLng,
    required double bboxMaxLng,
  });
}

/// One admin-region row captured by [InMemoryAdminScratchWriter].
class AdminRegionRow {
  /// Create a row.
  const AdminRegionRow({
    required this.regionId,
    required this.osmRelationId,
    required this.adminLevel,
    required this.name,
    required this.geometryWkb,
    required this.bboxMinLat,
    required this.bboxMaxLat,
    required this.bboxMinLng,
    required this.bboxMaxLng,
  });

  /// Pipeline-assigned sequential region id.
  final int regionId;

  /// Source OSM relation id (traceability).
  final int osmRelationId;

  /// OSM `admin_level` value.
  final int adminLevel;

  /// Human-readable region name (`name` OSM tag).
  final String name;

  /// Serialized `MultiPolygon` as Well-Known Binary.
  final Uint8List geometryWkb;

  /// Minimum latitude bound of [geometryWkb].
  final double bboxMinLat;

  /// Maximum latitude bound of [geometryWkb].
  final double bboxMaxLat;

  /// Minimum longitude bound of [geometryWkb].
  final double bboxMinLng;

  /// Maximum longitude bound of [geometryWkb].
  final double bboxMaxLng;
}

/// Test/CLI-smoke sink — collects rows in a list without hitting sqlite3.
class InMemoryAdminScratchWriter implements AdminScratchWriter {
  /// True after [applyAdminSchema] has been called at least once.
  bool schemaApplied = false;

  /// Every row captured via [insertAdminRegion], in insertion order.
  final List<AdminRegionRow> rows = [];

  @override
  void applyAdminSchema() {
    schemaApplied = true;
  }

  @override
  Future<void> insertAdminRegion({
    required int regionId,
    required int osmRelationId,
    required int adminLevel,
    required String name,
    required Uint8List geometryWkb,
    required double bboxMinLat,
    required double bboxMaxLat,
    required double bboxMinLng,
    required double bboxMaxLng,
  }) async {
    rows.add(
      AdminRegionRow(
        regionId: regionId,
        osmRelationId: osmRelationId,
        adminLevel: adminLevel,
        name: name,
        geometryWkb: geometryWkb,
        bboxMinLat: bboxMinLat,
        bboxMaxLat: bboxMaxLat,
        bboxMinLng: bboxMinLng,
        bboxMaxLng: bboxMaxLng,
      ),
    );
  }
}

/// [AdminScratchWriter] backed by 04-03's [ScratchDb].
///
/// Uses only the public `ScratchDb.raw` accessor — does not modify any
/// scratch_db.dart / scratch_schema.dart internals (both owned by 04-03).
class ScratchDbAdminWriter implements AdminScratchWriter {
  /// Create a writer that pushes rows through [scratch].
  ScratchDbAdminWriter(this.scratch);

  /// The 04-03 scratch DB whose `raw` handle we execute against.
  final ScratchDb scratch;

  PreparedStatement? _insertStmt;

  @override
  void applyAdminSchema() {
    final db = scratch.raw;
    for (final stmt in kAdminScratchSchema) {
      db.execute(stmt);
    }
  }

  @override
  Future<void> insertAdminRegion({
    required int regionId,
    required int osmRelationId,
    required int adminLevel,
    required String name,
    required Uint8List geometryWkb,
    required double bboxMinLat,
    required double bboxMaxLat,
    required double bboxMinLng,
    required double bboxMaxLng,
  }) async {
    (_insertStmt ??= scratch.raw.prepare('''
INSERT INTO admin_regions_raw
  (region_id, osm_relation_id, admin_level, name, geometry_wkb,
   bbox_minlat, bbox_maxlat, bbox_minlng, bbox_maxlng)
VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
'''))
        .execute([
      regionId,
      osmRelationId,
      adminLevel,
      name,
      geometryWkb,
      bboxMinLat,
      bboxMaxLat,
      bboxMinLng,
      bboxMaxLng,
    ]);
  }

  /// Disposes the prepared insert statement, if any.
  void dispose() {
    final stmt = _insertStmt;
    if (stmt != null) {
      stmt.dispose();
      _insertStmt = null;
    }
  }
}
