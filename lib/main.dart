import 'package:auto_explore/app.dart';
import 'package:auto_explore/core/errors/domain_error.dart';
import 'package:auto_explore/core/logging/app_logger.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';

final _log = Logger('main');

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  setupLogging();

  // Framework errors — build/layout/paint.
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    final wrapped = DomainError.wrap(details.exception, details.stack);
    _log.severe('FlutterError', wrapped, details.stack);
  };

  // Async errors outside Flutter's callback zone.
  PlatformDispatcher.instance.onError = (error, stack) {
    final wrapped = DomainError.wrap(error, stack);
    _log.severe('PlatformDispatcher.onError', wrapped, stack);
    return true; // Prevent OS-level crash.
  };

  runApp(const ProviderScope(child: App()));
}
