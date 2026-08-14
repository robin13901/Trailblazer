// Trailblazer 2026-08-13 (durable coverage-line cache):
// CoverageLineCacheDao tests against an in-memory Drift database.

import 'package:auto_explore/core/db/app_database.dart';
import 'package:auto_explore/core/db/daos/coverage_line_cache_dao.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late CoverageLineCacheDao dao;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    dao = CoverageLineCacheDao(db);
    await db.customSelect('SELECT 1').getSingle(); // trigger beforeOpen PRAGMAs
  });

  tearDown(() async {
    await db.close();
  });

  test('getRow returns null on an empty cache', () async {
    expect(await dao.getRow(), isNull);
  });

  test('put then getRow returns the stored blob + revision', () async {
    await dao.put(linesJson: '{"v":1,"ways":[]}', intervalsRevision: 7);

    final row = await dao.getRow();
    expect(row, isNotNull);
    expect(row!.id, 1);
    expect(row.linesJson, '{"v":1,"ways":[]}');
    expect(row.intervalsRevision, 7);
  });

  test('put overwrites the single row (id = 1), never inserts a second', () async {
    await dao.put(linesJson: 'A', intervalsRevision: 1);
    await dao.put(linesJson: 'B', intervalsRevision: 2);

    final row = await dao.getRow();
    expect(row!.linesJson, 'B');
    expect(row.intervalsRevision, 2);

    final all = await db.select(db.coverageLineCache).get();
    expect(all, hasLength(1), reason: 'single-row table');
  });

  test('deleteAll clears the row', () async {
    await dao.put(linesJson: 'A', intervalsRevision: 1);
    expect(await dao.deleteAll(), 1);
    expect(await dao.getRow(), isNull);
  });

  test('watchRow emits on write', () async {
    final emissions = <int?>[];
    final sub = dao.watchRow().listen((r) => emissions.add(r?.intervalsRevision));
    addTearDown(sub.cancel);

    await Future<void>.delayed(Duration.zero);
    expect(emissions, [null]); // initial empty

    await dao.put(linesJson: 'A', intervalsRevision: 5);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(emissions.last, 5);
  });
}
