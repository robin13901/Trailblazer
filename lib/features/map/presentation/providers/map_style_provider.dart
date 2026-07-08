import 'dart:ui';

import 'package:auto_explore/features/map/data/tile_provider_config.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

const _lightAsset = 'assets/map_style_light.json';
const _darkAsset = 'assets/map_style_dark.json';

/// Returns the map style asset path for the given [Brightness].
///
/// Public helper so tests and external code can use it without instantiating
/// the full Riverpod container.
///
/// **Deprecation notice:** this asset-based helper is being retired in
/// favour of MapTiler-hosted style URLs (see [mapStyleUrlProvider] below).
/// Plan 04-12 deletes the bundled `assets/map_style_*.json` files and this
/// helper along with them. Kept alive for one commit so map bootstrap can
/// remain green while 04-12 swaps the map widget over.
String assetForBrightness(Brightness b) =>
    b == Brightness.dark ? _darkAsset : _lightAsset;

/// Notifier that holds the current map-style asset path as a [String].
///
/// Initialized from `PlatformDispatcher.instance.platformBrightness` at
/// construction time. The map widget's brightness observer calls
/// `updateFromBrightness` when `didChangePlatformBrightness` fires — this
/// keeps the provider state in sync with the running style swap so other
/// widgets (e.g., glass shell, tests) can observe the current style.
///
/// Plain [Notifier] — no @Riverpod codegen (see STATE.md Plan 01-01 decision).
///
/// **Deprecation notice:** superseded by [mapStyleUrlProvider]. Kept for
/// one commit while 04-12 rewires the map widget to consume the new URL
/// provider; then this class + [mapStyleAssetProvider] are deleted.
class MapStyleAssetNotifier extends Notifier<String> {
  @override
  String build() => assetForBrightness(
    PlatformDispatcher.instance.platformBrightness,
  );

  /// Called from MapWidget's [WidgetsBindingObserver] when system brightness
  /// changes. Updates the stored asset path so watchers reflect the new style.
  void updateFromBrightness(Brightness b) {
    state = assetForBrightness(b);
  }
}

/// Provider for the active map-style asset path.
///
/// Derived from system brightness; updated by the map widget via
/// [MapStyleAssetNotifier.updateFromBrightness].
///
/// **Deprecation notice:** superseded by [mapStyleUrlProvider]. 04-12 will
/// delete this provider once the map widget consumes the MapTiler URL
/// directly.
final mapStyleAssetProvider = NotifierProvider<MapStyleAssetNotifier, String>(
  MapStyleAssetNotifier.new,
);

// ---------------------------------------------------------------------------
// New MapTiler-URL wiring (Plan 04-11)
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
/// Uses the same brightness-observer contract as [MapStyleAssetNotifier]:
/// the map widget calls [updateFromBrightness] on `didChangePlatformBrightness`
/// so the URL flips between the light + dark styles configured in the
/// injected [TileProviderConfig].
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

  /// Called from MapWidget's [WidgetsBindingObserver] when system brightness
  /// changes. Reads the current [TileProviderConfig] and updates the URL
  /// accordingly.
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
/// Watches [tileProviderConfigProvider] and system brightness. 04-12 rewires
/// the map widget to consume this in place of [mapStyleAssetProvider].
final mapStyleUrlProvider = NotifierProvider<MapStyleUrlNotifier, String>(
  MapStyleUrlNotifier.new,
);
