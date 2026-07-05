import 'package:auto_explore/features/trips/data/background_geolocation_facade.dart';
import 'package:auto_explore/features/trips/data/fgb_background_geolocation_facade.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Provider for the [BackgroundGeolocationFacade] singleton.
///
/// Override in tests with a fake implementation — no native FGB code runs.
///
/// Plain `Provider<T>` — no `@Riverpod` codegen (see STATE.md Plan 01-01).
final backgroundGeolocationFacadeProvider =
    Provider<BackgroundGeolocationFacade>(
  (ref) => FgbBackgroundGeolocationFacade(),
);
