// Trailblazer Phase 9, Plan 09-01:
// Unit tests for DriftBackupService — round-trip, validation, rejection.
//
// Test strategy:
// - validateBackup cases: pure sqlite3, no platform channels needed.
//   Files created in Directory.systemTemp directly.
// - VACUUM INTO round-trip: open real temp-file Drift DBs (NativeDatabase(File)),
//   seed data, call customStatement('VACUUM INTO ?') directly, validate output,
//   then open the backup as a second Drift DB and assert row counts match.
//   This covers the core SC1 guarantee without platform-channel dependency.
// - restore() rejection: call validateBackup() directly on bad files and assert
//   the source DB row count is unchanged (live DB never touched before validate).
// - Platform-channel-dependent paths (createBackup/restore with
//   getTemporaryDirectory / getApplicationDocumentsDirectory) are tested
//   via the VACUUM INTO direct pattern; full end-to-end restore is narrowed to
//   platform-channel-free seams per plan note.
import 'dart:io';

import 'package:auto_explore/core/db/app_database.dart';
import 'package:auto_explore/core/db/app_database_providers.dart';
import 'package:auto_explore/core/db/daos/driven_way_intervals_dao.dart';
import 'package:auto_explore/core/errors/domain_error.dart';
import 'package:auto_explore/core/errors/result.dart';
import 'package:auto_explore/features/settings/data/backup_service_provider.dart';
import 'package:auto_explore/features/settings/data/drift_backup_service.dart';
import 'package:auto_explore/features/settings/domain/backup_validation_result.dart';
import 'package:auto_explore/features/trips/data/trips_dao.dart';
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as s3;

// ─── Helpers ────────────────────────────────────────────────────────────────

/// Open a fresh temp-file AppDatabase (WAL mode via beforeOpen).
/// The caller is responsible for closing it and deleting the temp directory.
Future<(AppDatabase, Directory)> _openTempFileDb() async {
  final dir = await Directory.systemTemp.createTemp('tb_backup_test_');
  final file = File('${dir.path}/app_db.sqlite');
  final db = AppDatabase(NativeDatabase(file));
  // Trigger beforeOpen PRAGMAs (foreign_keys=ON, WAL mode).
  await db.customSelect('SELECT 1').getSingle();
  return (db, dir);
}

/// Seed [trips] trip rows with [pointsPerTrip] GPS points and one interval each.
Future<void> _seedData(
  AppDatabase db, {
  int trips = 2,
  int pointsPerTrip = 3,
}) async {
  final tripsDao = TripsDao(db);
  final intervalsDao = DrivenWayIntervalsDao(db);

  for (var i = 0; i < trips; i++) {
    final tripId = await tripsDao.openTrip(
      startedAt: DateTime(2026, 1, i + 1),
      manuallyStarted: true,
    );
    await tripsDao.appendPointsBatch(
      tripId,
      List.generate(
        pointsPerTrip,
        (j) => TripPointsCompanion.insert(
          tripId: tripId,
          seq: j + 1,
          ts: DateTime(2026, 1, i + 1, 0, j),
          lat: 49.0 + j * 0.001,
          lon: 9.0 + j * 0.001,
        ),
      ),
    );
    await intervalsDao.insertBatch([
      DrivenWayIntervalsCompanion.insert(
        wayId: 1000 + i,
        tripId: Value(tripId),
        startMeters: 0,
        endMeters: 100,
      ),
    ]);
  }
}

/// Build a [DriftBackupService] backed by a [ProviderContainer] that overrides
/// [appDatabaseProvider] with [db].
///
/// We read backupServiceProvider so we get a real DriftBackupService with a
/// valid Ref. validateBackup doesn't use Ref at all; the container is just
/// needed to satisfy the constructor signature.
DriftBackupService _buildService(AppDatabase db) {
  final container = ProviderContainer(
    overrides: [appDatabaseProvider.overrideWithValue(db)],
  );
  return container.read(backupServiceProvider) as DriftBackupService;
}

// ─── Tests ──────────────────────────────────────────────────────────────────

void main() {
  // ── Group 1: validateBackup ────────────────────────────────────────────────
  group('DriftBackupService.validateBackup', () {
    late Directory tempDir;
    late AppDatabase db;
    late DriftBackupService service;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('tb_validate_test_');
      db = AppDatabase(NativeDatabase.memory());
      service = _buildService(db);
    });

    tearDown(() async {
      await db.close();
      await tempDir.delete(recursive: true);
    });

    // Case 2: reject non-SQLite (random bytes).
    test('rejects a non-SQLite file', () async {
      final badFile = File('${tempDir.path}/bad.trailblazer')
        ..writeAsBytesSync(
          Uint8List.fromList(List.generate(256, (i) => i)),
        );

      final result = await service.validateBackup(badFile.path);

      expect(result, isA<BackupInvalid>());
      expect(
        (result as BackupInvalid).reason,
        contains('not a valid SQLite file'),
      );
    });

    // Case 3: reject newer schema (user_version = 99).
    test('rejects a backup from a newer app version', () async {
      final dbPath = '${tempDir.path}/future.trailblazer';
      final raw = s3.sqlite3.open(dbPath);
      try {
        raw
          ..execute('PRAGMA user_version = 99')
          ..execute('CREATE TABLE trips (id INTEGER PRIMARY KEY)')
          ..execute('CREATE TABLE trip_points (id INTEGER PRIMARY KEY)')
          ..execute(
            'CREATE TABLE driven_way_intervals (id INTEGER PRIMARY KEY)',
          );
      } finally {
        raw.close();
      }

      final result = await service.validateBackup(dbPath);

      expect(result, isA<BackupInvalid>());
      expect((result as BackupInvalid).reason, contains('newer app version'));
      expect(result.reason, contains('99'));
    });

    // Case 4: reject user_version = 0 (not a Trailblazer DB).
    test('rejects a file with user_version = 0', () async {
      final dbPath = '${tempDir.path}/zero_version.trailblazer';
      final raw = s3.sqlite3.open(dbPath);
      try {
        raw
          ..execute('PRAGMA user_version = 0')
          ..execute('CREATE TABLE trips (id INTEGER PRIMARY KEY)');
      } finally {
        raw.close();
      }

      final result = await service.validateBackup(dbPath);

      expect(result, isA<BackupInvalid>());
      expect((result as BackupInvalid).reason, contains('user_version=0'));
    });

    // Case 4b: reject missing tables.
    test('rejects a valid SQLite file missing required tables', () async {
      final dbPath = '${tempDir.path}/missing_tables.trailblazer';
      final raw = s3.sqlite3.open(dbPath);
      try {
        raw
          ..execute('PRAGMA user_version = 4')
          ..execute('CREATE TABLE trips (id INTEGER PRIMARY KEY)');
        // trip_points and driven_way_intervals intentionally omitted.
      } finally {
        raw.close();
      }

      final result = await service.validateBackup(dbPath);

      expect(result, isA<BackupInvalid>());
      expect((result as BackupInvalid).reason, contains('missing tables'));
    });

    // Case 5: accept a file with the current schema version (4).
    test('accepts a file with the current schema version (4)', () async {
      final dbPath = '${tempDir.path}/valid.trailblazer';
      final raw = s3.sqlite3.open(dbPath);
      try {
        raw
          ..execute('PRAGMA user_version = 4')
          ..execute('CREATE TABLE trips (id INTEGER PRIMARY KEY)')
          ..execute('CREATE TABLE trip_points (id INTEGER PRIMARY KEY)')
          ..execute(
            'CREATE TABLE driven_way_intervals (id INTEGER PRIMARY KEY)',
          );
      } finally {
        raw.close();
      }

      final result = await service.validateBackup(dbPath);

      expect(result, isA<BackupValid>());
      expect((result as BackupValid).schemaVersion, equals(4));
    });

    // Case 5b: accept a file with an older schema version (Drift will migrate).
    test('accepts a file with an older schema version (< 4)', () async {
      final dbPath = '${tempDir.path}/old_schema.trailblazer';
      final raw = s3.sqlite3.open(dbPath);
      try {
        raw
          ..execute('PRAGMA user_version = 2')
          ..execute('CREATE TABLE trips (id INTEGER PRIMARY KEY)')
          ..execute('CREATE TABLE trip_points (id INTEGER PRIMARY KEY)')
          ..execute(
            'CREATE TABLE driven_way_intervals (id INTEGER PRIMARY KEY)',
          );
      } finally {
        raw.close();
      }

      final result = await service.validateBackup(dbPath);

      expect(result, isA<BackupValid>());
      expect((result as BackupValid).schemaVersion, equals(2));
    });
  });

  // ── Group 2: VACUUM INTO round-trip ───────────────────────────────────────
  group('VACUUM INTO round-trip (core SC1 guarantee)', () {
    test('backup file has no -wal/-shm sidecar and preserves row counts',
        () async {
      final (sourceDb, sourceDir) = await _openTempFileDb();
      addTearDown(() async {
        await sourceDb.close();
        await sourceDir.delete(recursive: true);
      });

      await _seedData(sourceDb, trips: 3, pointsPerTrip: 4);

      // VACUUM INTO a separate temp output path.
      final backupDir =
          await Directory.systemTemp.createTemp('tb_backup_out_');
      addTearDown(() => backupDir.delete(recursive: true));
      final backupPath = '${backupDir.path}/backup.trailblazer';
      await sourceDb.customStatement('VACUUM INTO ?', [backupPath]);

      // Assert: no -wal/-shm sidecars on the backup output.
      expect(
        File('$backupPath-wal').existsSync(),
        isFalse,
        reason: 'VACUUM INTO must not produce a -wal sidecar',
      );
      expect(
        File('$backupPath-shm').existsSync(),
        isFalse,
        reason: 'VACUUM INTO must not produce a -shm sidecar',
      );

      // Open backup as a second Drift DB and verify row counts match.
      final backupDb = AppDatabase(NativeDatabase(File(backupPath)));
      addTearDown(backupDb.close);
      await backupDb.customSelect('SELECT 1').getSingle(); // trigger beforeOpen

      Future<int> count(AppDatabase d, String table) async {
        final row =
            await d.customSelect('SELECT COUNT(*) AS c FROM $table').getSingle();
        return row.read<int>('c');
      }

      expect(
        await count(backupDb, 'trips'),
        equals(await count(sourceDb, 'trips')),
      );
      expect(
        await count(backupDb, 'trip_points'),
        equals(await count(sourceDb, 'trip_points')),
      );
      expect(
        await count(backupDb, 'driven_way_intervals'),
        equals(await count(sourceDb, 'driven_way_intervals')),
      );
    });

    test('validateBackup on a real VACUUM INTO output returns BackupValid(4)',
        () async {
      final (db, dir) = await _openTempFileDb();
      addTearDown(() async {
        await db.close();
        await dir.delete(recursive: true);
      });
      await _seedData(db, pointsPerTrip: 2);

      final backupDir =
          await Directory.systemTemp.createTemp('tb_validate_out_');
      addTearDown(() => backupDir.delete(recursive: true));
      final backupPath = '${backupDir.path}/export.trailblazer';
      await db.customStatement('VACUUM INTO ?', [backupPath]);

      final service = _buildService(db);
      final result = await service.validateBackup(backupPath);
      expect(result, isA<BackupValid>());
      expect(
        (result as BackupValid).schemaVersion,
        equals(kCurrentSchemaVersion),
      );
    });
  });

  // ── Group 3: restore rejects invalid file (live DB untouched) ─────────────
  group('restore: invalid backup rejected before touching live DB', () {
    test('validateBackup on bad file returns BackupInvalid; source row count unchanged',
        () async {
      final (liveDb, liveDir) = await _openTempFileDb();
      addTearDown(() async {
        await liveDb.close();
        await liveDir.delete(recursive: true);
      });
      await _seedData(liveDb);

      // Confirm source has 2 trips.
      final before = await liveDb
          .customSelect('SELECT COUNT(*) AS c FROM trips')
          .getSingle();
      expect(before.read<int>('c'), equals(2));

      // Build an invalid backup file (random bytes).
      final badDir = await Directory.systemTemp.createTemp('tb_bad_backup_');
      addTearDown(() => badDir.delete(recursive: true));
      final badPath = '${badDir.path}/bad.trailblazer';
      File(badPath).writeAsBytesSync(
        Uint8List.fromList(List.generate(64, (i) => i)),
      );

      final service = _buildService(liveDb);
      final validation = await service.validateBackup(badPath);
      expect(
        validation,
        isA<BackupInvalid>(),
        reason: 'corrupt file must be rejected',
      );

      // Live DB must still have all rows (not touched by validate).
      final after = await liveDb
          .customSelect('SELECT COUNT(*) AS c FROM trips')
          .getSingle();
      expect(
        after.read<int>('c'),
        equals(2),
        reason: 'live DB must be untouched when validation fails',
      );
    });

    test('restore returns Err(StorageError) for a corrupt backup file', () async {
      final (liveDb, liveDir) = await _openTempFileDb();
      addTearDown(() async {
        await liveDb.close();
        await liveDir.delete(recursive: true);
      });
      await _seedData(liveDb, trips: 1);

      final badDir = await Directory.systemTemp.createTemp('tb_bad_backup2_');
      addTearDown(() => badDir.delete(recursive: true));
      final badPath = '${badDir.path}/bad.trailblazer';
      File(badPath).writeAsBytesSync(
        Uint8List.fromList(List.generate(64, (i) => i)),
      );

      final service = _buildService(liveDb);
      final result = await service.restore(badPath);
      expect(result.isErr, isTrue);
      expect(
        (result as Err<void>).error as StorageError,
        isA<StorageError>(),
      );
      expect(
        (result.error as StorageError).message,
        contains('Invalid backup'),
      );
    });
  });

  // ── Group 4: Result type contract ─────────────────────────────────────────
  group('Result type contract', () {
    test('Err wraps a DomainError subtype', () {
      const Result<String> result = Err(StorageError('test'));
      expect(result.isErr, isTrue);
      expect((result as Err<String>).error, isA<StorageError>());
    });

    test('Ok wraps the value', () {
      const Result<String> result = Ok('/fake/path.trailblazer');
      expect(result.isOk, isTrue);
      expect((result as Ok<String>).value, contains('.trailblazer'));
    });
  });
}
