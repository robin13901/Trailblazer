import 'package:flutter/material.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

/// Phase-2 map widget. Wraps [MapLibreMap] with the gesture set
/// mandated by 02-CONTEXT.md:
///   - pan / zoom / rotate: enabled
///   - tilt: DISABLED (flat 2D only)
///
/// Location, follow-mode, and dark-mode switching are added in later
/// Phase 2 plans (02-03, 02-04). This widget deliberately renders
/// only the base map + built-in compass button.
class MapWidget extends StatefulWidget {
  const MapWidget({
    super.key,
    this.initialTarget = const LatLng(52.52, 13.40), // Berlin default
    this.initialZoom = 15,
    this.styleAsset = 'assets/map_style_light.json',
    this.onMapCreated,
    this.onStyleLoaded,
  });

  final LatLng initialTarget;
  final double initialZoom;
  final String styleAsset;
  final void Function(MapLibreMapController)? onMapCreated;
  final VoidCallback? onStyleLoaded;

  @override
  State<MapWidget> createState() => _MapWidgetState();
}

class _MapWidgetState extends State<MapWidget> {
  @override
  Widget build(BuildContext context) {
    return MapLibreMap(
      styleString: widget.styleAsset,
      initialCameraPosition: CameraPosition(
        target: widget.initialTarget,
        zoom: widget.initialZoom,
      ),
      // 02-CONTEXT.md: flat 2D only — tilt is the only non-default gesture flag.
      tiltGesturesEnabled: false,
      compassViewPosition: CompassViewPosition.topRight,
      trackCameraPosition: true,
      // NOTE: myLocationEnabled is intentionally false here.
      // Plan 02-03 wires it up behind a permission check.
      // NOTE: useHybridComposition NOT set — we do NOT override the static
      // field. Pitfall 2: do not set it to true on Android Impeller.
      onMapCreated: (c) {
        widget.onMapCreated?.call(c);
      },
      onStyleLoadedCallback: () {
        widget.onStyleLoaded?.call();
      },
    );
  }
}
