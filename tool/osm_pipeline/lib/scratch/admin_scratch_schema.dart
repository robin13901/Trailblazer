/// SQL CREATE statements for the admin-region scratch tables.
///
/// Applied at scratch-DB open time alongside `scratch_schema.dart` (owned by
/// 04-03). Kept in a separate file so 04-03 and 04-04 can execute in the
/// same wave without touching the same file — the pipeline orchestrator
/// (04-06) is the wiring seam that applies both.
///
/// Schema shape follows 04-RESEARCH.md §6. This is the RAW scratch table —
/// 04-06 promotes it to the final `admin_regions` in `osm.sqlite`.
library;

/// Ordered list of CREATE statements. Idempotent when applied to a fresh
/// scratch DB; not idempotent against an existing one (deliberate — scratch
/// is single-use).
const List<String> kAdminScratchSchema = [
  '''
  CREATE TABLE admin_regions_raw (
    region_id       INTEGER PRIMARY KEY,
    osm_relation_id INTEGER NOT NULL,
    admin_level     INTEGER NOT NULL,
    name            TEXT NOT NULL,
    geometry_wkb    BLOB NOT NULL,
    bbox_minlat     REAL NOT NULL,
    bbox_maxlat     REAL NOT NULL,
    bbox_minlng     REAL NOT NULL,
    bbox_maxlng     REAL NOT NULL
  );
  ''',
  'CREATE INDEX idx_admin_regions_raw_level ON admin_regions_raw(admin_level);',
];
