import 'dart:ui';

import 'package:auto_explore/features/map/data/tile_provider_config.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

// ---------------------------------------------------------------------------
// MapTiler-URL wiring (Plan 04-11; legacy asset-based provider deleted in 04-12)
// ---------------------------------------------------------------------------

/// The active [TileProviderConfig] for the app.
///
/// This provider is **overridden at bootstrap** in `main.dart` with the real
/// `TileProviderConfig` constructed from `--dart-define=MAPTILER_KEY`. The
/// default value here (empty key) exists purely so widget tests that don't
/// override it still have a resolvable read — the URL it produces is unusable
/// but that's the correct fail-loud behaviour when no key is injected.
final tileProviderConfigProvider = Provider<TileProviderConfig>(
  (ref) => const TileProviderConfig(
    lightStyle: MapTilerStyle.dataviz,
    darkStyle: MapTilerStyle.datavizDark,
    apiKey: '',
  ),
);

/// Notifier that resolves the current MapTiler style URL for the active
/// system brightness.
///
/// The map widget calls [updateFromBrightness] on
/// `didChangePlatformBrightness` so the URL flips between the light + dark
/// styles configured in the injected [TileProviderConfig].
///
/// Plain [Notifier] — no @Riverpod codegen (STATE.md Plan 01-01 decision).
class MapStyleUrlNotifier extends Notifier<String> {
  @override
  String build() {
    final config = ref.watch(tileProviderConfigProvider);
    return _urlForBrightness(
      config,
      PlatformDispatcher.instance.platformBrightness,
    );
  }

  /// Called from `MapWidget`'s platform-brightness observer when the system
  /// brightness changes. Reads the current [TileProviderConfig] and updates
  /// the URL accordingly.
  void updateFromBrightness(Brightness b) {
    final config = ref.read(tileProviderConfigProvider);
    state = _urlForBrightness(config, b);
  }

  String _urlForBrightness(TileProviderConfig config, Brightness b) {
    final style = b == Brightness.dark ? config.darkStyle : config.lightStyle;
    // When no key is injected (tests, CI without secret) the URL is still
    // constructed — MapLibre's tile request will 401 and the diagnostics
    // logger will pick it up. The alternative (returning an empty string)
    // breaks MapLibre's style loader in an obscure way.
    if (!config.hasKey) {
      return 'https://api.maptiler.com/maps/${style.id}/style.json?key=';
    }
    return config.styleUrl(style).toString();
  }
}

/// Provider for the active MapTiler style URL.
///
/// Watches [tileProviderConfigProvider] and system brightness. The map
/// widget consumes this as `MapLibreMap.styleString`; no local asset loading.
final mapStyleUrlProvider = NotifierProvider<MapStyleUrlNotifier, String>(
  MapStyleUrlNotifier.new,
);
