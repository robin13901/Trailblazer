/// Ephemeral SQLite scratch DB — the write-heavy sink for pipeline Stages A-C.
///
/// Tuned for maximum write throughput (04-RESEARCH §10):
///   * `journal_mode=OFF`  — no rollback journal (scratch dies on success).
///   * `synchronous=OFF`   — no fsync between writes.
///   * `cache_size=-524288`  — 512 MB page cache.
///   * `temp_store=MEMORY`.
///   * `page_size=65536` — set BEFORE the first CREATE TABLE.
///
/// Writes use prepared statements + batched transactions (10 000 rows per
/// flush) to balance throughput against peak memory.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:osm_pipeline/scratch/scratch_schema.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

/// Thin wrapper around the pipeline's ephemeral scratch SQLite DB.
class ScratchDb {
  ScratchDb._(this._db, this.file, this.directory);

  /// Opens a fresh scratch DB in `Directory.systemTemp` under a unique
  /// `trailblazer_osm_*/` directory. Applies write-optimised pragmas and
  /// creates the tables declared in [kScratchDdl].
  ///
  /// A static method (not a constructor) because construction is non-trivial
  /// — it creates a temp directory and applies pragmas/DDL that may throw.
  // ignore: prefer_constructors_over_static_methods
  static ScratchDb openTempFile() {
    final dir = Directory.systemTemp.createTempSync('trailblazer_osm_');
    final path = p.join(dir.path, 'scratch.sqlite');
    final db = sqlite3.open(path);
    // page_size must be set before any table exists, hence before DDL.
    // ignore: cascade_invocations
    db
      ..execute('PRAGMA page_size = 65536;')
      ..execute('PRAGMA journal_mode = OFF;')
      ..execute('PRAGMA synchronous = OFF;')
      ..execute('PRAGMA cache_size = -524288;')
      ..execute('PRAGMA temp_store = MEMORY;');
    for (final ddl in kScratchDdl) {
      db.execute(ddl);
    }
    return ScratchDb._(db, File(path), dir);
  }

  final Database _db;

  /// Absolute path to the scratch DB file.
  final File file;

  /// Owning temp directory — `skipped.log` lives alongside.
  final Directory directory;

  static const int _batchSize = 10000;

  PreparedStatement? _wayKfzStmt;
  PreparedStatement? _wayFeldwegStmt;
  PreparedStatement? _nodeStmt;
  PreparedStatement? _relationStmt;
  PreparedStatement? _bumpStatStmt;

  int _inFlight = 0;
  bool _txOpen = false;

  void _ensureTx() {
    if (!_txOpen) {
      _db.execute('BEGIN;');
      _txOpen = true;
    }
  }

  void _maybeFlush() {
    _inFlight++;
    if (_inFlight >= _batchSize) {
      flush();
    }
  }

  /// Commits any pending batched writes.
  void flush() {
    if (_txOpen) {
      _db.execute('COMMIT;');
      _txOpen = false;
    }
    _inFlight = 0;
  }

  PreparedStatement _prepWayKfz() => _wayKfzStmt ??= _db.prepare(
        '''
INSERT INTO ways_raw
  (id, source, is_counting, is_directional, oneway_tag, highway,
   name, ref, maxspeed, node_ids)
VALUES (?, 'kfz', 1, ?, ?, ?, ?, ?, ?, ?);
''',
      );

  PreparedStatement _prepWayFeldweg() => _wayFeldwegStmt ??= _db.prepare(
        '''
INSERT INTO ways_raw
  (id, source, is_counting, is_directional, highway,
   name, surface, motor_vehicle, service, node_ids)
VALUES (?, 'feldweg', 0, 0, ?, ?, ?, ?, ?, ?);
''',
      );

  PreparedStatement _prepNode() => _nodeStmt ??= _db.prepare(
        'INSERT OR IGNORE INTO nodes_raw (id, lat, lng) VALUES (?, ?, ?);',
      );

  PreparedStatement _prepRelation() => _relationStmt ??= _db.prepare(
        '''
INSERT INTO relations_raw (id, type, admin_level, name, members)
VALUES (?, ?, ?, ?, ?);
''',
      );

  PreparedStatement _prepBumpStat() => _bumpStatStmt ??= _db.prepare(
        '''
INSERT INTO filter_stats (key, count) VALUES (?, 1)
ON CONFLICT(key) DO UPDATE SET count = count + 1;
''',
      );

  /// Inserts a Kfz way row.
  void insertWayKfz({
    required int id,
    required List<int> nodeIds,
    required bool isDirectional,
    required String? onewayTag,
    required String highway,
    required String? name,
    required String? ref,
    required String? maxspeed,
  }) {
    _ensureTx();
    _prepWayKfz().execute([
      id,
      if (isDirectional) 1 else 0,
      onewayTag,
      highway,
      name,
      ref,
      maxspeed,
      encodeNodeIds(nodeIds),
    ]);
    _maybeFlush();
  }

  /// Inserts a Feldweg way row.
  void insertWayFeldweg({
    required int id,
    required List<int> nodeIds,
    required String highway,
    required String? name,
    required String? surface,
    required String? motorVehicle,
    required String? service,
  }) {
    _ensureTx();
    _prepWayFeldweg().execute([
      id,
      highway,
      name,
      surface,
      motorVehicle,
      service,
      encodeNodeIds(nodeIds),
    ]);
    _maybeFlush();
  }

  /// Inserts a node row.
  void insertNode({required int id, required double lat, required double lng}) {
    _ensureTx();
    _prepNode().execute([id, lat, lng]);
    _maybeFlush();
  }

  /// Inserts a relation row (raw admin/multipolygon relation payload — Plan
  /// 04-04 owns the actual admin extraction; this is the shared table shape).
  void insertRelation({
    required int id,
    required String type,
    required int? adminLevel,
    required String? name,
    required Uint8List members,
  }) {
    _ensureTx();
    _prepRelation().execute([id, type, adminLevel, name, members]);
    _maybeFlush();
  }

  /// Increments the counter at [key] by 1, inserting the row on first bump.
  void bumpStat(String key) {
    _ensureTx();
    _prepBumpStat().execute([key]);
    _maybeFlush();
  }

  /// Reads the current value of [key] in `filter_stats`, or 0 if unset.
  int readStat(String key) {
    final result = _db.select(
      'SELECT count FROM filter_stats WHERE key = ?;',
      [key],
    );
    if (result.isEmpty) return 0;
    return result.first['count'] as int;
  }

  /// Convenience: counts rows in the given table (post-flush).
  int countRows(String table) {
    final result = _db.select('SELECT COUNT(*) AS n FROM $table;');
    return result.first['n'] as int;
  }

  /// Closes the DB; deletes the file (and its temp directory) when
  /// [deleteFile] is true.
  void close({required bool deleteFile}) {
    flush();
    _wayKfzStmt?.dispose();
    _wayFeldwegStmt?.dispose();
    _nodeStmt?.dispose();
    _relationStmt?.dispose();
    _bumpStatStmt?.dispose();
    _db.dispose();
    if (deleteFile && directory.existsSync()) {
      directory.deleteSync(recursive: true);
    }
  }

  /// Returns the underlying [Database] for read-only queries owned by
  /// pipeline stages (e.g. Pass B post-integrity check in 04-03 way_pipeline).
  Database get raw => _db;
}

/// Length-prefixed little-endian int64 encoding for a node-id sequence.
///
/// Layout: `uint32 count | int64 * count`, little-endian, ~8 B per id.
/// Chosen for constant-time decode and stable Windows/macOS/Linux behaviour
/// — SQLite BLOB storage is opaque.
Uint8List encodeNodeIds(List<int> ids) {
  final buffer = ByteData(4 + ids.length * 8)
    ..setUint32(0, ids.length, Endian.little);
  for (var i = 0; i < ids.length; i++) {
    buffer.setInt64(4 + i * 8, ids[i], Endian.little);
  }
  return buffer.buffer.asUint8List();
}

/// Inverse of [encodeNodeIds] — decodes a node-id BLOB back into a list.
List<int> decodeNodeIds(Uint8List bytes) {
  final view = ByteData.sublistView(bytes);
  final count = view.getUint32(0, Endian.little);
  final out = List<int>.filled(count, 0);
  for (var i = 0; i < count; i++) {
    out[i] = view.getInt64(4 + i * 8, Endian.little);
  }
  return out;
}
