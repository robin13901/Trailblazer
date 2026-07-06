import 'package:osm_pipeline/output/osm_sqlite_schema.dart';
import 'package:osm_pipeline/output/version_stamp.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

Database _openWithMetadata() {
  final db = sqlite3.openInMemory();
  for (final ddl in kOsmSqliteDdl) {
    db.execute(ddl);
  }
  return db;
}

void main() {
  group('VersionStamp.writeTo', () {
    test('writes all 7 metadata rows and stamps user_version', () {
      final db = _openWithMetadata();
      try {
        VersionStamp(
          pbfDate: DateTime.utc(2026, 7, 5),
          pbfSource: 'berlin-260705.osm.pbf',
          pbfSha256: 'c96a067a',
          bbox: '13.0,52.0,14.0,53.0',
          schemaVersion: 1,
          gitSha: 'abc123',
          generatedAt: DateTime.utc(2026, 7, 6, 12, 30),
        ).writeTo(db);

        final rows = db.select(
          'SELECT key, value FROM metadata ORDER BY key;',
        );
        final map = {
          for (final r in rows) r['key'] as String: r['value'] as String,
        };
        expect(map, hasLength(7));
        expect(map['pbf_date'], '2026-07-05T00:00:00.000Z');
        expect(map['pbf_source'], 'berlin-260705.osm.pbf');
        expect(map['pbf_sha256'], 'c96a067a');
        expect(map['bbox'], '13.0,52.0,14.0,53.0');
        expect(map['pipeline_schema_version'], '1');
        expect(map['pipeline_git_sha'], 'abc123');
        expect(map['generated_at'], '2026-07-06T12:30:00.000Z');

        final uv = db.select('PRAGMA user_version;').first.values.first;
        expect(uv, 1);
      } finally {
        db.dispose();
      }
    });

    test("null bbox surfaces as '*'", () {
      final db = _openWithMetadata();
      try {
        VersionStamp(
          pbfDate: DateTime.utc(2026, 7, 5),
          pbfSource: 'x.pbf',
          pbfSha256: '',
          bbox: null,
          schemaVersion: 1,
          gitSha: 'unknown',
          generatedAt: DateTime.utc(2026),
        ).writeTo(db);

        final row = db.select(
          "SELECT value FROM metadata WHERE key = 'bbox';",
        ).first;
        expect(row['value'], '*');
      } finally {
        db.dispose();
      }
    });

    test('re-writing is idempotent (REPLACE)', () {
      final db = _openWithMetadata();
      try {
        VersionStamp(
          pbfDate: DateTime.utc(2026, 7, 5),
          pbfSource: 'x.pbf',
          pbfSha256: 'aa',
          bbox: null,
          schemaVersion: 1,
          gitSha: 'unknown',
          generatedAt: DateTime.utc(2026),
        ).writeTo(db);
        // Second write must not throw.
        VersionStamp(
          pbfDate: DateTime.utc(2026, 7, 6),
          pbfSource: 'x.pbf',
          pbfSha256: 'bb',
          bbox: null,
          schemaVersion: 1,
          gitSha: 'unknown',
          generatedAt: DateTime.utc(2026, 1, 2),
        ).writeTo(db);
        final row = db.select(
          "SELECT value FROM metadata WHERE key = 'pbf_sha256';",
        ).first;
        expect(row['value'], 'bb');
      } finally {
        db.dispose();
      }
    });
  });

  group('defaultGitShaResolver', () {
    test("returns 'unknown' or a real SHA (no throw)", () {
      final sha = defaultGitShaResolver();
      expect(sha, isNotNull);
      expect(sha, isNotEmpty);
      // Either 'unknown' or a hex-looking SHA (40 hex chars for a full SHA).
      expect(
        sha == 'unknown' || RegExp(r'^[a-f0-9]+$').hasMatch(sha),
        isTrue,
      );
    });
  });

  group('VersionStamp.basenameOf', () {
    test('strips directory prefix', () {
      expect(
        VersionStamp.basenameOf('/tmp/dir/berlin-260705.osm.pbf'),
        'berlin-260705.osm.pbf',
      );
    });
  });
}
