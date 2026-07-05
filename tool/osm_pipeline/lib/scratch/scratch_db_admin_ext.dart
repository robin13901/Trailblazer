/// Admin-side scratch DB contract + in-memory writer.
///
/// 04-04 owns the admin extraction stage. Its scratch-write path is defined
/// here as an abstract contract so:
///
///   * The stage does not depend on 04-03's `ScratchDb` type (04-03 runs in
///     the same wave — no cross-wave-3 imports).
///   * Tests and the CLI smoke path use [InMemoryAdminScratchWriter] without
///     needing a real sqlite3 handle.
///   * 04-06 (pipeline orchestrator) wires a concrete implementation on top
///     of the real `ScratchDb` — either as an extension on `ScratchDb`
///     implementing this interface, or as a thin wrapper class. Both shapes
///     honor the same contract.
///
/// See 04-04-PLAN.md "File-ownership note" for the coordination rationale.
library;

import 'dart:typed_data';

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
