import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

const _lightAsset = 'assets/map_style_light.json';
const _darkAsset = 'assets/map_style_dark.json';

/// Returns the map style asset path for the given [Brightness].
///
/// Public helper so tests and external code can use it without instantiating
/// the full Riverpod container.
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
final mapStyleAssetProvider = NotifierProvider<MapStyleAssetNotifier, String>(
  MapStyleAssetNotifier.new,
);
