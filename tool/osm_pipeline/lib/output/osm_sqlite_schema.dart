/// SQL DDL + PRAGMA statements for the final `osm.sqlite` output artifact.
///
/// Emitted at write time by `OsmSqliteWriter`. Per the 04-05 Berlin
/// measurement recommendation the pipeline uses the
/// **denormalized L2..L8 + way_admin for splits** variant (see
/// `.planning/phases/04-osm-pipeline/04-05-BERLIN-MEASUREMENT.md`).
/// Admin regions L9/L10 are excluded from the denormalized columns to keep
/// the projected osm.sqlite under the relaxed 800 MB SC4 budget; L2..L8
/// wholly-contained ways roll up into columns, cross-border ways stay in
/// `way_admin`.
library;

/// Admin levels that get denormalized on the `ways` table.
///
/// See 04-05-BERLIN-MEASUREMENT.md → Recommendation. L9/L10 are intentionally
/// excluded per the slim projection.
const List<int> kDenormAdminLevels = [2, 4, 6, 8];

/// Runtime PRAGMAs applied to `osm.sqlite` before DDL. Matches 04-RESEARCH
/// §10 output-DB pragmas (WAL journal, synchronous NORMAL, 4 KiB pages).
///
/// `page_size` must be set BEFORE any table exists — `OsmSqliteWriter`
/// applies these pragmas immediately after opening the file.
const List<String> kOsmSqlitePragmas = [
  'PRAGMA page_size = 4096;',
  'PRAGMA journal_mode = WAL;',
  'PRAGMA synchronous = NORMAL;',
];

/// Ordered CREATE statements for the final osm.sqlite schema.
///
/// `PRAGMA user_version` is stamped separately by `VersionStamp.writeTo`
/// so the schema version constant lives in one place.
const List<String> kOsmSqliteDdl = [
  '''
CREATE TABLE metadata (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
''',
  '''
CREATE TABLE ways (
  way_id             INTEGER PRIMARY KEY,
  source             TEXT NOT NULL,
  is_counting        INTEGER NOT NULL,
  is_directional    INTEGER NOT NULL,
  oneway_tag         TEXT,
  highway            TEXT NOT NULL,
  name               TEXT,
  ref                TEXT,
  maxspeed           TEXT,
  surface            TEXT,
  length_m           REAL NOT NULL,
  geometry_wkb       BLOB NOT NULL,
  admin_region_id_l2 INTEGER,
  admin_region_id_l4 INTEGER,
  admin_region_id_l6 INTEGER,
  admin_region_id_l8 INTEGER
);
''',
  'CREATE INDEX idx_ways_source_counting ON ways(source, is_counting);',
  'CREATE INDEX idx_ways_highway ON ways(highway);',
  '''
CREATE TABLE admin_regions (
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
  'CREATE INDEX idx_admin_regions_level ON admin_regions(admin_level);',
  '''
CREATE VIRTUAL TABLE admin_regions_rtree USING rtree(
  id, min_lat, max_lat, min_lng, max_lng
);
''',
  '''
CREATE TABLE way_admin (
  way_id         INTEGER NOT NULL,
  region_id      INTEGER NOT NULL,
  admin_level    INTEGER NOT NULL,
  fraction_start REAL NOT NULL,
  fraction_end   REAL NOT NULL,
  PRIMARY KEY (way_id, region_id, admin_level, fraction_start)
) WITHOUT ROWID;
''',
  'CREATE INDEX idx_way_admin_region ON way_admin(region_id, admin_level);',
  '''
CREATE VIRTUAL TABLE ways_rtree USING rtree(
  id, min_lat, max_lat, min_lng, max_lng
);
''',
  '''
CREATE TABLE ways_rtree_lookup (
  rtree_id    INTEGER PRIMARY KEY,
  way_id      INTEGER NOT NULL,
  segment_idx INTEGER NOT NULL
);
''',
  'CREATE INDEX idx_ways_rtree_lookup_way ON ways_rtree_lookup(way_id);',
];
