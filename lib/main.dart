import 'dart:io' show Platform;

import 'package:auto_explore/app.dart';
import 'package:auto_explore/core/errors/domain_error.dart';
import 'package:auto_explore/core/logging/app_logger.dart';
import 'package:auto_explore/core/theme/liquid_glass_settings.dart';
import 'package:auto_explore/features/map/data/tile_provider_config.dart';
import 'package:auto_explore/features/map/presentation/providers/map_style_provider.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';

final _log = Logger('main');

/// MapTiler API key, injected at build time via one of:
///   flutter run --dart-define=MAPTILER_KEY=`your-key`
///   flutter run --dart-define-from-file=env/dev.json
///
/// Empty string when the flag is missing (CI without secret, fork PRs). The
/// map renders blank tiles in that case; a warning is logged in `main()` and
/// the diagnostics HUD surfaces the resulting HTTP 401 chain.
///
/// The key never appears in source, git history, or logs — this constant
/// is the only path from the toolchain to `TileProviderConfig`.
const kMaptilerKey = String.fromEnvironment('MAPTILER_KEY');

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

  // MapTiler tile-provider configuration.
  // Defaults chosen from 04-11-STYLE-SPIKE.md (dataviz / dataviz-dark).
  // The key is empty when --dart-define=MAPTILER_KEY is not set — we log a
  // warning but keep booting so the diagnostics HUD stays reachable.
  //
  // Plan 04-16-1 (2026-07-08 UX polish): map labels localized to the
  // system locale (falls back to 'de' when the locale is not a MapTiler-
  // supported code). See tile_provider_config.dart / resolveMapLanguage.
  if (kMaptilerKey.isEmpty) {
    _log.warning(
      'MAPTILER_KEY not set — map will render blank tiles. '
      'Pass --dart-define=MAPTILER_KEY=<key> or '
      '--dart-define-from-file=env/dev.json at run/build time.',
    );
  }
  final mapLanguage = resolveMapLanguage(Platform.localeName);
  _log.info('Map labels language: $mapLanguage '
      '(from platform locale ${Platform.localeName})');
  final tileProviderConfig = TileProviderConfig(
    lightStyle: MapTilerStyle.dataviz,
    darkStyle: MapTilerStyle.datavizDark,
    apiKey: kMaptilerKey,
    language: mapLanguage,
  );

  final container = ProviderContainer(
    overrides: [
      tileProviderConfigProvider.overrideWithValue(tileProviderConfig),
    ],
  );

  runApp(UncontrolledProviderScope(container: container, child: const App()));
}
