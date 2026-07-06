/// Scratch DB DDL — the ephemeral write-heavy tables Stages A-C use as a
/// spillover for entities that don't fit in RAM.
///
/// The scratch DB is created inside `Directory.systemTemp` and deleted on
/// pipeline success. Pragmas are tuned for write-mostly, no-crash-safety use
/// (04-RESEARCH §10); pragmas live on the `ScratchDb` wrapper, not here.
library;

/// Ordered CREATE statements. Applied via `db.execute` at open time.
const List<String> kScratchDdl = <String>[
  '''
CREATE TABLE nodes_raw (
  id       INTEGER PRIMARY KEY,
  lat      REAL NOT NULL,
  lng      REAL NOT NULL
) WITHOUT ROWID;
''',
  '''
CREATE TABLE ways_raw (
  id             INTEGER PRIMARY KEY,
  source         TEXT NOT NULL,
  is_counting    INTEGER NOT NULL,
  is_directional INTEGER NOT NULL,
  oneway_tag     TEXT,
  highway        TEXT NOT NULL,
  name           TEXT,
  ref            TEXT,
  maxspeed       TEXT,
  surface        TEXT,
  motor_vehicle  TEXT,
  service        TEXT,
  node_ids       BLOB NOT NULL
);
''',
  '''
CREATE TABLE relations_raw (
  id          INTEGER PRIMARY KEY,
  type        TEXT NOT NULL,
  admin_level INTEGER,
  name        TEXT,
  members     BLOB NOT NULL
);
''',
  '''
CREATE TABLE filter_stats (
  key   TEXT PRIMARY KEY,
  count INTEGER NOT NULL DEFAULT 0
);
''',
  // 04-05: PROVISIONAL join scratch table. 04-06 promotes rows into the
  // final osm.sqlite schema (either as denormalized columns on `ways` or as
  // a permanent `way_admin` table — depends on 04-05-BERLIN-MEASUREMENT.md).
  '''
CREATE TABLE way_admin_raw (
  way_id         INTEGER NOT NULL,
  region_id      INTEGER NOT NULL,
  admin_level    INTEGER NOT NULL,
  fraction_start REAL NOT NULL,
  fraction_end   REAL NOT NULL,
  PRIMARY KEY (way_id, region_id, admin_level, fraction_start)
) WITHOUT ROWID;
''',
  'CREATE INDEX idx_way_admin_way ON way_admin_raw(way_id);',
  'CREATE INDEX idx_way_admin_region ON way_admin_raw(region_id);',
];
