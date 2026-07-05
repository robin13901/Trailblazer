import 'package:auto_explore/core/db/app_database.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Singleton [AppDatabase] provider.
///
/// Plain `Provider` — no `@Riverpod` codegen (STATE.md 01-01 decision).
/// Tests override this with `AppDatabase(NativeDatabase.memory())`.
final appDatabaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase();
  ref.onDispose(db.close);
  return db;
});
