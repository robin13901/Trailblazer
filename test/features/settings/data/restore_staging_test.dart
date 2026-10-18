// Trailblazer: unit tests for restore_staging.dart — the backup-restore
// staging + launch-time swap that replaces the old in-place live swap (which
// deadlocked on db.close() while watch-streams were alive).
//
// Pure temp-directory + sqlite3 tests — no platform channels, no Drift.

import 'dart:io';
import 'dart:typed_data';

import 'package:auto_explore/features/settings/data/restore_staging.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

/// Writes a minimal but valid Trailblazer-shaped SQLite DB at [path] with the
/// given [userVersion] and the required tables (unless [withTables] is false).
void _writeDb(
  String path, {
  int userVersion = 10,
  bool withTables = true,
  int marker = 1,
}) {
  final db = sqlite3.open(path);
  try {
    db.execute('PRAGMA user_version = $userVersion');
    if (withTables) {
      db
        ..execute('CREATE TABLE trips (id INTEGER PRIMARY KEY, marker INTEGER)')
        ..execute('CREATE TABLE trip_points (id INTEGER PRIMARY KEY)')
        ..execute('CREATE TABLE driven_way_intervals (id INTEGER PRIMARY KEY)')
        ..execute('INSERT INTO trips (id, marker) VALUES (1, $marker)');
    }
  } finally {
    db.close();
  }
}

int _readMarker(String path) {
  final db = sqlite3.open(path, mode: OpenMode.readOnly);
  try {
    return db.select('SELECT marker FROM trips WHERE id = 1').first['marker']
        as int;
  } finally {
    db.close();
  }
}

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('tb_restore_staging_');
  });

  tearDown(() async {
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  String mainDbPath() => p.join(dir.path, kAppDbFileName);
  String pendingPath() => p.join(dir.path, kPendingRestoreFileName);
  String tmpPath() => p.join(dir.path, kPendingRestoreTmpFileName);

  group('stagePendingRestore', () {
    test('copies the backup to the pending file and leaves the live DB alone',
        () async {
      _writeDb(mainDbPath(), marker: 111); // live DB
      final backupPath = p.join(dir.path, 'backup.trailblazer');
      _writeDb(backupPath, marker: 222);

      await stagePendingRestore(
        backupPath: backupPath,
        documentsDir: dir.path,
      );

      // Pending file now exists; no leftover tmp; live DB untouched.
      expect(hasPendingRestore(dir.path), isTrue);
      expect(File(tmpPath()).existsSync(), isFalse);
      expect(_readMarker(mainDbPath()), 111, reason: 'live DB not modified');
      expect(_readMarker(pendingPath()), 222);
    });

    test('overwrites a previously staged pending file', () async {
      final backupA = p.join(dir.path, 'a.trailblazer');
      final backupB = p.join(dir.path, 'b.trailblazer');
      _writeDb(backupA, marker: 7);
      _writeDb(backupB, marker: 2);

      await stagePendingRestore(backupPath: backupA, documentsDir: dir.path);
      await stagePendingRestore(backupPath: backupB, documentsDir: dir.path);

      expect(_readMarker(pendingPath()), 2);
    });
  });

  group('applyPendingRestoreIfAny', () {
    test('returns false and keeps the live DB when nothing is staged',
        () async {
      _writeDb(mainDbPath(), marker: 111);

      final applied = await applyPendingRestoreIfAny(dir.path);

      expect(applied, isFalse);
      expect(_readMarker(mainDbPath()), 111);
    });

    test('swaps a staged pending file into the live DB location', () async {
      _writeDb(mainDbPath(), marker: 111);
      // Also drop stale WAL/SHM sidecars to prove they get cleared.
      File('${mainDbPath()}-wal').writeAsBytesSync(Uint8List(4));
      File('${mainDbPath()}-shm').writeAsBytesSync(Uint8List(4));

      final backupPath = p.join(dir.path, 'backup.trailblazer');
      _writeDb(backupPath, marker: 222);
      await stagePendingRestore(backupPath: backupPath, documentsDir: dir.path);

      final applied = await applyPendingRestoreIfAny(dir.path);

      expect(applied, isTrue);
      expect(_readMarker(mainDbPath()), 222, reason: 'backup swapped in');
      expect(hasPendingRestore(dir.path), isFalse, reason: 'pending consumed');
      expect(File('${mainDbPath()}-wal').existsSync(), isFalse);
      expect(File('${mainDbPath()}-shm').existsSync(), isFalse);
    });

    test('is idempotent — a second call finds nothing to do', () async {
      _writeDb(mainDbPath(), marker: 111);
      final backupPath = p.join(dir.path, 'backup.trailblazer');
      _writeDb(backupPath, marker: 222);
      await stagePendingRestore(backupPath: backupPath, documentsDir: dir.path);

      expect(await applyPendingRestoreIfAny(dir.path), isTrue);
      expect(await applyPendingRestoreIfAny(dir.path), isFalse);
      expect(_readMarker(mainDbPath()), 222);
    });

    test('discards a stray tmp file (crash mid-staging) without swapping',
        () async {
      _writeDb(mainDbPath(), marker: 111);
      File(tmpPath()).writeAsBytesSync(Uint8List.fromList([1, 2, 3]));

      final applied = await applyPendingRestoreIfAny(dir.path);

      expect(applied, isFalse);
      expect(File(tmpPath()).existsSync(), isFalse, reason: 'tmp discarded');
      expect(_readMarker(mainDbPath()), 111, reason: 'live DB untouched');
    });

    test('discards an INVALID staged file and keeps the live DB', () async {
      _writeDb(mainDbPath(), marker: 111);
      // Pending file that is not valid SQLite (random bytes).
      File(pendingPath())
          .writeAsBytesSync(Uint8List.fromList(List.generate(64, (i) => i)));

      final applied = await applyPendingRestoreIfAny(dir.path);

      expect(applied, isFalse);
      expect(hasPendingRestore(dir.path), isFalse, reason: 'bad pending purged');
      expect(_readMarker(mainDbPath()), 111, reason: 'good data preserved');
    });

    test('discards a staged DB missing required tables', () async {
      _writeDb(mainDbPath(), marker: 111);
      // Valid SQLite + user_version but without the required tables.
      _writeDb(pendingPath(), withTables: false);

      final applied = await applyPendingRestoreIfAny(dir.path);

      expect(applied, isFalse);
      expect(_readMarker(mainDbPath()), 111);
    });
  });

  group('isPlausibleTrailblazerDb', () {
    test('true for a valid Trailblazer-shaped DB', () {
      final path = p.join(dir.path, 'ok.trailblazer');
      _writeDb(path);
      expect(isPlausibleTrailblazerDb(path), isTrue);
    });

    test('false for user_version 0', () {
      final path = p.join(dir.path, 'uv0.trailblazer');
      _writeDb(path, userVersion: 0);
      expect(isPlausibleTrailblazerDb(path), isFalse);
    });

    test('false for a non-SQLite file', () {
      final path = p.join(dir.path, 'junk.trailblazer');
      File(path).writeAsBytesSync(Uint8List.fromList([9, 9, 9, 9]));
      expect(isPlausibleTrailblazerDb(path), isFalse);
    });
  });
}
