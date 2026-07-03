// Test helper: fake implementation of MapLibrePlatform.
// Adapted from maplibre_gl-0.26.2/test/helpers/fake_platform.dart
// (pub cache — not importable directly, so reproduced here).

import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:maplibre_gl_platform_interface/maplibre_gl_platform_interface.dart';

/// Minimal fake implementation of [MapLibrePlatform] for widget tests.
///
/// [buildView] returns a [SizedBox.shrink] instead of a real platform view,
/// which avoids the "MissingPluginException" that would otherwise be thrown
/// when the native MapLibre GL plugin is absent in a unit-test environment.
class FakeMapLibrePlatform extends MapLibrePlatform {
  Map<String, dynamic>? lastCreationParams;

  @override
  Future<void> initPlatform(int id) async {}

  @override
  Widget buildView(
    Map<String, dynamic> creationParams,
    OnPlatformViewCreatedCallback onPlatformViewCreated,
    Set<Factory<OneSequenceGestureRecognizer>>? gestureRecognizers,
  ) {
    lastCreationParams = creationParams;
    return const SizedBox.shrink();
  }

  @override
  Future<CameraPosition?> updateMapOptions(
    Map<String, dynamic> optionsUpdate,
  ) async => null;

  @override
  Future<bool?> animateCamera(
    CameraUpdate cameraUpdate, {
    Duration? duration,
  }) async => null;

  @override
  Future<bool?> moveCamera(CameraUpdate cameraUpdate) async => null;

  @override
  Future<void> updateMyLocationTrackingMode(
    MyLocationTrackingMode myLocationTrackingMode,
  ) async {}

  @override
  Future<void> matchMapLanguageWithDeviceDefault() async {}

  @override
  void resizeWebMap() {}

  @override
  void forceResizeWebMap() {}

  @override
  Future<void> updateContentInsets(EdgeInsets insets, bool animated) async {}

  @override
  Future<void> setMapLanguage(String language) async {}

  @override
  Future<void> setTelemetryEnabled(bool enabled) async {}

  @override
  Future<bool> getTelemetryEnabled() async => false;

  @override
  Future<void> setMaximumFps(int fps) async {}

  @override
  Future<void> forceOnlineMode() async {}

  @override
  Future<bool> easeCamera(
    CameraUpdate cameraUpdate, {
    Duration? duration,
    CameraAnimationInterpolation? interpolation,
  }) async => false;

  @override
  Future<CameraPosition?> queryCameraPosition() async => null;

  @override
  Future<bool> editGeoJsonSource(String id, String data) async => false;

  @override
  Future<bool> editGeoJsonUrl(String id, String url) async => false;

  @override
  Future<bool> setLayerFilter(String layerId, String filter) async => false;

  @override
  Future<String?> getStyle() async => null;

  @override
  Future<void> setCustomHeaders(
    Map<String, String> headers,
    List<String> filter,
  ) async {}

  @override
  Future<Map<String, String>> getCustomHeaders() async => {};

  @override
  Future<List<dynamic>> queryRenderedFeatures(
    Point<double> point,
    List<String> layerIds,
    List<Object>? filter,
  ) async => [];

  @override
  Future<List<dynamic>> queryRenderedFeaturesInRect(
    Rect rect,
    List<String> layerIds,
    String? filter,
  ) async => [];

  @override
  Future<List<dynamic>> querySourceFeatures(
    String sourceId,
    String? sourceLayerId,
    List<Object>? filter,
  ) async => [];

  @override
  Future<void> invalidateAmbientCache() async {}

  @override
  Future<void> clearAmbientCache() async {}

  @override
  Future<LatLng?> requestMyLocationLatLng() async => null;

  @override
  Future<LatLngBounds> getVisibleRegion() async => LatLngBounds(
    southwest: const LatLng(-1, -1),
    northeast: const LatLng(1, 1),
  );

  @override
  Future<void> addImage(String name, Uint8List bytes, [bool sdf = false]) async {
  }

  @override
  Future<void> addImageSource(
    String imageSourceId,
    Uint8List bytes,
    LatLngQuad coordinates,
  ) async {}

  @override
  Future<void> updateImageSource(
    String imageSourceId,
    Uint8List? bytes,
    LatLngQuad? coordinates,
  ) async {}

  @override
  Future<void> addLayer(
    String imageLayerId,
    String imageSourceId,
    double? minzoom,
    double? maxzoom,
  ) async {}

  @override
  Future<void> addLayerBelow(
    String imageLayerId,
    String imageSourceId,
    String belowLayerId,
    double? minzoom,
    double? maxzoom,
  ) async {}

  @override
  Future<void> removeLayer(String layerId) async {}

  @override
  Future<List<dynamic>> getLayerIds() async => [];

  @override
  Future<List<dynamic>> getSourceIds() async => [];

  @override
  Future<void> setFilter(String layerId, dynamic filter) async {}

  @override
  Future<dynamic> getFilter(String layerId) async => null;

  @override
  Future<Point<num>> toScreenLocation(LatLng latLng) async =>
      const Point(0, 0);

  @override
  Future<List<Point<num>>> toScreenLocationBatch(
    Iterable<LatLng> latLngs,
  ) async => [];

  @override
  Future<LatLng> toLatLng(Point<num> screenLocation) async =>
      const LatLng(0, 0);

  @override
  Future<double> getMetersPerPixelAtLatitude(double latitude) async => 1;

  @override
  Future<void> addGeoJsonSource(
    String sourceId,
    Map<String, dynamic> geojson, {
    String? promoteId,
  }) async {}

  @override
  Future<void> setGeoJsonSource(
    String sourceId,
    Map<String, dynamic> geojson,
  ) async {}

  @override
  Future<void> setCameraBounds({
    required double west,
    required double north,
    required double south,
    required double east,
    required int padding,
  }) async {}

  @override
  Future<void> setFeatureForGeoJsonSource(
    String sourceId,
    Map<String, dynamic> geojsonFeature,
  ) async {}

  @override
  Future<void> setFeatureState(
    String sourceId,
    String featureId,
    Map<String, dynamic> state, {
    String? sourceLayer,
  }) async {}

  @override
  Future<void> removeFeatureState(
    String sourceId, {
    String? featureId,
    String? stateKey,
    String? sourceLayer,
  }) async {}

  @override
  Future<Map<String, dynamic>?> getFeatureState(
    String sourceId,
    String featureId, {
    String? sourceLayer,
  }) async => null;

  @override
  Future<void> removeSource(String sourceId) async {}

  @override
  Future<void> addSymbolLayer(
    String sourceId,
    String layerId,
    Map<String, dynamic> properties, {
    required bool enableInteraction,
    String? belowLayerId,
    String? sourceLayer,
    double? minzoom,
    double? maxzoom,
    dynamic filter,
  }) async {}

  @override
  Future<void> addLineLayer(
    String sourceId,
    String layerId,
    Map<String, dynamic> properties, {
    required bool enableInteraction,
    String? belowLayerId,
    String? sourceLayer,
    double? minzoom,
    double? maxzoom,
    dynamic filter,
  }) async {}

  @override
  Future<void> setLayerProperties(
    String layerId,
    Map<String, dynamic> properties,
  ) async {}

  @override
  Future<void> addCircleLayer(
    String sourceId,
    String layerId,
    Map<String, dynamic> properties, {
    required bool enableInteraction,
    String? belowLayerId,
    String? sourceLayer,
    double? minzoom,
    double? maxzoom,
    dynamic filter,
  }) async {}

  @override
  Future<void> addFillLayer(
    String sourceId,
    String layerId,
    Map<String, dynamic> properties, {
    required bool enableInteraction,
    String? belowLayerId,
    String? sourceLayer,
    double? minzoom,
    double? maxzoom,
    dynamic filter,
  }) async {}

  @override
  Future<void> addFillExtrusionLayer(
    String sourceId,
    String layerId,
    Map<String, dynamic> properties, {
    required bool enableInteraction,
    String? belowLayerId,
    String? sourceLayer,
    double? minzoom,
    double? maxzoom,
    dynamic filter,
  }) async {}

  @override
  Future<void> addRasterLayer(
    String sourceId,
    String layerId,
    Map<String, dynamic> properties, {
    String? belowLayerId,
    String? sourceLayer,
    double? minzoom,
    double? maxzoom,
  }) async {}

  @override
  Future<void> addHillshadeLayer(
    String sourceId,
    String layerId,
    Map<String, dynamic> properties, {
    String? belowLayerId,
    String? sourceLayer,
    double? minzoom,
    double? maxzoom,
  }) async {}

  @override
  Future<void> addHeatmapLayer(
    String sourceId,
    String layerId,
    Map<String, dynamic> properties, {
    String? belowLayerId,
    String? sourceLayer,
    double? minzoom,
    double? maxzoom,
  }) async {}

  @override
  Future<void> addSource(String sourceId, SourceProperties properties) async {}

  @override
  Future<void> setLayerVisibility(String layerId, bool visible) async {}

  @override
  Future<bool?> getLayerVisibility(String layerId) async => null;

  @override
  Future<Size> setWebMapToCustomSize(Size size) async => size;

  @override
  Future<void> waitUntilMapIsIdleAfterMovement() async {}

  @override
  Future<void> waitUntilMapTilesAreLoaded() async {}

  @override
  Future<Uint8List> takeSnapshot({int? width, int? height}) async =>
      Uint8List.fromList([0x89, 0x50, 0x4E, 0x47]);

  @override
  Future<void> setStyle(String styleString) async {}
}
