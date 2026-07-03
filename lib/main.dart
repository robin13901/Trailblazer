import 'package:auto_explore/app.dart';
import 'package:auto_explore/core/logging/app_logger.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  setupLogging();
  runApp(const ProviderScope(child: App()));
}
