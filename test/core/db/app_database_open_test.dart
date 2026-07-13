import 'package:flutter_test/flutter_test.dart';

import '../../helpers/test_database.dart';

void main() {
  test('AppDatabase opens in memory with all 9 tables', () async {
    final db = createInMemoryDatabase();
    addTearDown(db.close);

    // Reading Drift's internal table list via sqlite_master.
    final rows = await db
        .customSelect(
          'SELECT name FROM sqlite_master '
          "WHERE type='table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'android_%'",
        )
        .get();
    final tableNames = rows.map((r) => r.read<String>('name')).toSet();

    expect(
      tableNames,
      containsAll(<String>{
        'trips',
        'trip_points',
        'driven_way_intervals',
        'coverage_cache',
        'app_prefs',
        'overpass_way_cache',
        'pending_road_fetches',
      }),
    );
  });

  test('foreign_keys pragma is ON after beforeOpen', () async {
    final db = createInMemoryDatabase();
    addTearDown(db.close);

    // Force beforeOpen by issuing any query first.
    await db.customSelect('SELECT 1').get();

    final row = await db.customSelect('PRAGMA foreign_keys').getSingle();
    expect(row.read<int>('foreign_keys'), 1);
  });
}
