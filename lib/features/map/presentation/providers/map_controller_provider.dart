import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

/// Notifier that holds the [MapLibreMapController] lifecycle.
///
/// Set `controller` to non-null on map creation; set to `null` on disposal.
///
/// Plain [Notifier] — no `@Riverpod` codegen (see STATE.md Plan 01-01 decision).
class MapControllerNotifier extends Notifier<MapLibreMapController?> {
  @override
  MapLibreMapController? build() => null;

  /// The current controller value.
  ///
  /// Mirrors [state] for callers that prefer property-style access.
  MapLibreMapController? get controller => state;

  /// Set to attach on map creation; set to `null` to detach on disposal.
  set controller(MapLibreMapController? value) => state = value;
}

/// Provider for the current [MapLibreMapController], or `null` before map
/// creation or after disposal.
final mapControllerProvider =
    NotifierProvider<MapControllerNotifier, MapLibreMapController?>(
      MapControllerNotifier.new,
    );
