import 'package:auto_explore/core/db/app_database.dart';
import 'package:drift/native.dart';

AppDatabase createInMemoryDatabase() {
  return AppDatabase(NativeDatabase.memory());
}
