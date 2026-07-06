import 'dart:io';

import 'package:osm_pipeline/intersect/vec2.dart';
import 'package:osm_pipeline/output/osm_sqlite_schema.dart';
import 'package:osm_pipeline/output/rtree_builder.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

/// Open an in-memory osm.sqlite-shaped DB with the two rtree-related tables
/// created (the schema.dart DDL is idempotent enough for this).
Database _openOsmSqliteInMemory() {
  final db = sqlite3.openInMemory();
  for (final pragma in kOsmSqlitePragmas) {
    // WAL/page_size are meaningless on :memory: but harmless.
    try {
      db.execute(pragma);
    } on SqliteException {
      // page_size is a no-op on :memory: — ignore.
    }
  }
  for (final ddl in kOsmSqliteDdl) {
    db.execute(ddl);
  }
  return db;
}

void main() {
  group('RtreeBuilder', () {
    test('per-segment: 3-point line → 2 rtree rows', () {
      final db = _openOsmSqliteInMemory();
      try {
        final b = RtreeBuilder(db, RtreeGranularity.perSegment);
        try {
          final line = <Vec2>[
            const Vec2(13.400, 52.500),
            const Vec2(13.401, 52.501),
            const Vec2(13.402, 52.502),
          ];
          final written = b.buildForWay(1, line);
          expect(written, 2);
          expect(b.rowsWritten, 2);
          final rows = db.select(
            'SELECT r.id, r.min_lat, r.max_lat, r.min_lng, r.max_lng, '
            'l.segment_idx FROM ways_rtree r '
            'JOIN ways_rtree_lookup l ON r.id = l.rtree_id '
            'ORDER BY l.segment_idx;',
          );
          expect(rows, hasLength(2));
          expect(rows[0]['segment_idx'], 0);
          expect(rows[1]['segment_idx'], 1);
        } finally {
          b.dispose();
        }
      } finally {
        db.dispose();
      }
    });

    test('per-way: 3-point line → 1 rtree row with segment_idx = -1', () {
      final db = _openOsmSqliteInMemory();
      try {
        final b = RtreeBuilder(db, RtreeGranularity.perWay);
        try {
          final line = <Vec2>[
            const Vec2(13.400, 52.500),
            const Vec2(13.401, 52.501),
            const Vec2(13.402, 52.502),
          ];
          final written = b.buildForWay(42, line);
          expect(written, 1);
          final row = db.select(
            'SELECT r.min_lat, r.max_lat, r.min_lng, r.max_lng, '
            'l.segment_idx FROM ways_rtree r '
            'JOIN ways_rtree_lookup l ON r.id = l.rtree_id;',
          ).first;
          expect(row['segment_idx'], -1);
          expect(row['min_lat'] as double, closeTo(52.500, 1e-4));
          expect(row['max_lat'] as double, closeTo(52.502, 1e-4));
        } finally {
          b.dispose();
        }
      } finally {
        db.dispose();
      }
    });

    test('bbox arithmetic: pair (52.5, 13.4)→(52.6, 13.5) has exact bbox', () {
      final db = _openOsmSqliteInMemory();
      try {
        final b = RtreeBuilder(db, RtreeGranularity.perSegment);
        try {
          final written = b.buildForWay(
            1,
            const [Vec2(13.4, 52.5), Vec2(13.5, 52.6)],
          );
          expect(written, 1);
          final row = db.select('SELECT * FROM ways_rtree;').first;
          // R*Tree stores single-precision floats; ~1e-4 tolerance covers it.
          expect(row['min_lat'] as double, closeTo(52.5, 1e-4));
          expect(row['max_lat'] as double, closeTo(52.6, 1e-4));
          expect(row['min_lng'] as double, closeTo(13.4, 1e-4));
          expect(row['max_lng'] as double, closeTo(13.5, 1e-4));
        } finally {
          b.dispose();
        }
      } finally {
        db.dispose();
      }
    });

    test('zero-length segments (duplicate points) are skipped', () {
      final db = _openOsmSqliteInMemory();
      try {
        final b = RtreeBuilder(db, RtreeGranularity.perSegment);
        try {
          final line = <Vec2>[
            const Vec2(13.400, 52.500),
            const Vec2(13.400, 52.500), // duplicate
            const Vec2(13.401, 52.501),
          ];
          final written = b.buildForWay(1, line);
          expect(written, 1); // only the non-degenerate segment.
        } finally {
          b.dispose();
        }
      } finally {
        db.dispose();
      }
    });

    test('degenerate lines (0 or 1 point) produce 0 rows', () {
      final db = _openOsmSqliteInMemory();
      try {
        final b = RtreeBuilder(db, RtreeGranularity.perSegment);
        try {
          expect(b.buildForWay(1, const []), 0);
          expect(b.buildForWay(2, const [Vec2(13.4, 52.5)]), 0);
          expect(b.rowsWritten, 0);
        } finally {
          b.dispose();
        }
      } finally {
        db.dispose();
      }
    });

    test('R-Tree query round-trip returns the built row', () {
      final db = _openOsmSqliteInMemory();
      try {
        final b = RtreeBuilder(db, RtreeGranularity.perSegment);
        try {
          b.buildForWay(
            777,
            const [Vec2(13.4, 52.5), Vec2(13.5, 52.6)],
          );
        } finally {
          b.dispose();
        }
        final rows = db.select(
          'SELECT l.way_id FROM ways_rtree r '
          'JOIN ways_rtree_lookup l ON r.id = l.rtree_id '
          'WHERE r.min_lat <= 52.55 AND r.max_lat >= 52.55 '
          'AND r.min_lng <= 13.45 AND r.max_lng >= 13.45;',
        );
        expect(rows, hasLength(1));
        expect(rows.first['way_id'], 777);
      } finally {
        db.dispose();
      }
    });

    group('loadFromMeasurement', () {
      late Directory tmp;

      setUp(() {
        tmp = Directory.systemTemp.createTempSync('rtree_measurement_');
      });
      tearDown(() {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      });

      test('missing file → perSegment default', () async {
        final missing = File('${tmp.path}/absent.md');
        final g = await RtreeBuilder.loadFromMeasurement(missing);
        expect(g, RtreeGranularity.perSegment);
      });

      test('file without per-way phrase → perSegment', () async {
        final f = File('${tmp.path}/nope.md')
          ..writeAsStringSync('regular measurement text');
        final g = await RtreeBuilder.loadFromMeasurement(f);
        expect(g, RtreeGranularity.perSegment);
      });

      test('file mentioning per-way → perWay', () async {
        final f = File('${tmp.path}/perway.md')
          ..writeAsStringSync('Recommend per-way granularity.');
        final g = await RtreeBuilder.loadFromMeasurement(f);
        expect(g, RtreeGranularity.perWay);
      });
    });
  });
}
