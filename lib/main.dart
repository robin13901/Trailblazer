import 'package:auto_explore/app.dart';
import 'package:auto_explore/core/errors/domain_error.dart';
import 'package:auto_explore/core/logging/app_logger.dart';
import 'package:auto_explore/core/theme/liquid_glass_settings.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';

final _log = Logger('main');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  setupLogging();

  // G1 gate result — see docs/G1_SPIKE.md.
  // Enabled on both Android (SM S921B, Impeller — device-verified) and iOS
  // (not device-tested; liquid_glass_renderer is iOS-designed, low risk).
  // Full over-platform-view re-verification pending at end of Plan 02-02.
  LiquidGlassSettings.platformBlurEnabled = true;

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

  // Initialise the Riverpod container before the first frame.
  // The container is passed to UncontrolledProviderScope so the same instance
  // powers the entire widget tree.
  //
  // NOTE: facade.ready() is intentionally NOT called here. It is deferred to
  // TrackingService.startManual() / _openAutoTrip() / init()-when-resuming so
  // that the FGB "LICENSE VALIDATION FAILURE" nag toast only appears the first
  // time the user actually engages tracking, not on every cold start.
  final container = ProviderContainer();

  runApp(UncontrolledProviderScope(container: container, child: const App()));
}
