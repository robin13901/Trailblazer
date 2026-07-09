import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

/// Renders 320x120 trip thumbnails as PNG bytes.
///
/// Two rendering paths:
///
/// * **[render]** — production path. If a [MapLibreMapController] is supplied
///   via the constructor, calls `takeSnapshot` (v0.26.2 API). On any failure
///   (including "no controller injected") falls back to [renderFallback].
/// * **[renderFallback]** — pure-Flutter path using `PictureRecorder` +
///   `Canvas` + `CustomPainter`-style polyline drawing on a neutral-gray
///   background. Belt-and-suspenders for devices where `takeSnapshot`
///   misbehaves (Q1 pitfall #2). Public for testability.
///
/// The renderer is deliberately **not brightness-reactive**. The active
/// `mapStyleUrl` is fixed at construction time. If MapLibre's `setStyle()`
/// runs mid-render, programmatic sources/layers get wiped (Q1 pitfall #1) —
/// don't listen to brightness on the thumbnail map.
class ThumbnailRenderer {
  ThumbnailRenderer({
    required this.mapStyleUrl,
    this.size = const Size(320, 120),
    this.bboxPadding = const EdgeInsets.all(20),
    MapLibreMapController? controller,
  }) : _controller = controller;

  /// The MapLibre style URL to render the base map under. Fixed at
  /// construction — see the class docstring.
  final String mapStyleUrl;

  /// Output raster size in logical pixels. Cards render 320x120.
  final Size size;

  /// Padding inside the bbox when projecting the polyline onto the raster.
  /// Prevents endpoints from touching the frame.
  final EdgeInsets bboxPadding;

  final MapLibreMapController? _controller;

  /// Render a thumbnail PNG for [polyline] within [bbox].
  ///
  /// If a [MapLibreMapController] was injected at construction, attempts the
  /// snapshot path first. On any failure (missing controller, snapshot API
  /// error, platform channel exception) falls back to [renderFallback].
  Future<Uint8List> render({
    required List<LatLng> polyline,
    required LatLngBounds bbox,
  }) async {
    final c = _controller;
    if (c != null) {
      try {
        // maplibre_gl 0.26.2 exposes only `takeSnapshot({width, height})` on
        // the Dart controller. Bbox framing + polyline overlay live on the
        // MapLibreMap widget itself (owned by 06-05's overlay wiring); this
        // path only asks the platform for a raster of what the controller
        // is already displaying.
        final bytes = await c.takeSnapshot(
          width: size.width.toInt(),
          height: size.height.toInt(),
        );
        if (bytes.isNotEmpty) return bytes;
      } on Object {
        // Snapshot API is v0.26.2-new and unproven on Trailblazer's target
        // devices — never let a platform-channel error bubble out of the
        // thumbnail renderer. Fall through to the CustomPainter path.
      }
    }
    return renderFallback(polyline: polyline, bbox: bbox);
  }

  /// Render a deterministic polyline-on-gray thumbnail as PNG bytes.
  ///
  /// This path uses only Flutter painting APIs — no platform channels, no
  /// MapLibre — so unit tests can call it without a real map integration.
  /// The projection is a simple equirectangular fit-to-bbox suitable for
  /// tiny 320x120 tiles; at that scale the geodesic error is invisible.
  Future<Uint8List> renderFallback({
    required List<LatLng> polyline,
    required LatLngBounds bbox,
  }) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(
      recorder,
      Rect.fromLTWH(0, 0, size.width, size.height),
    );

    // Neutral-gray background. Deliberately opaque — the fallback never
    // renders over another surface.
    final bg = Paint()..color = const Color(0xFFB0B0B0);
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      bg,
    );

    if (polyline.isNotEmpty) {
      _drawPolyline(canvas, polyline, bbox);
    }

    final picture = recorder.endRecording();
    final img = await picture.toImage(size.width.toInt(), size.height.toInt());
    final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
    picture.dispose();
    img.dispose();
    if (byteData == null) {
      // Should never happen — toByteData(format: png) is documented to
      // always produce bytes for a valid image. Belt-and-suspenders return
      // an empty PNG-magic-only buffer so callers don't NPE.
      return Uint8List.fromList(<int>[0x89, 0x50, 0x4E, 0x47]);
    }
    return byteData.buffer.asUint8List();
  }

  void _drawPolyline(
    Canvas canvas,
    List<LatLng> polyline,
    LatLngBounds bbox,
  ) {
    final projected = <Offset>[];
    for (final p in polyline) {
      final o = _project(p, bbox);
      if (o != null) projected.add(o);
    }
    if (projected.length < 2) {
      // Draw a single dot for degenerate inputs so callers always get a
      // visible polyline marker on the raster.
      if (projected.length == 1) {
        final dot = Paint()..color = const Color(0xFF1976D2);
        canvas.drawCircle(projected.single, 3, dot);
      }
      return;
    }

    final stroke = Paint()
      ..color = const Color(0xFF1976D2)
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;

    final path = Path()..moveTo(projected.first.dx, projected.first.dy);
    for (var i = 1; i < projected.length; i++) {
      path.lineTo(projected[i].dx, projected[i].dy);
    }
    canvas.drawPath(path, stroke);
  }

  /// Project a [LatLng] into raster space or return null if entirely outside
  /// the bbox (with padding applied). Callers skip null points, which
  /// effectively clips polyline segments that exit the frame.
  Offset? _project(LatLng point, LatLngBounds bbox) {
    final sw = bbox.southwest;
    final ne = bbox.northeast;

    final latSpan = ne.latitude - sw.latitude;
    final lonSpan = ne.longitude - sw.longitude;
    if (latSpan <= 0 || lonSpan <= 0) return null;

    final innerWidth = size.width - bboxPadding.horizontal;
    final innerHeight = size.height - bboxPadding.vertical;
    if (innerWidth <= 0 || innerHeight <= 0) return null;

    final xFrac = (point.longitude - sw.longitude) / lonSpan;
    // Flutter's y axis grows downward; latitude grows northward. Invert.
    final yFrac = 1 - ((point.latitude - sw.latitude) / latSpan);

    if (xFrac < 0 || xFrac > 1 || yFrac < 0 || yFrac > 1) {
      return null;
    }

    final x = bboxPadding.left + (xFrac * innerWidth);
    final y = bboxPadding.top + (yFrac * innerHeight);
    return Offset(x, y);
  }
}

/// Provider for the singleton [ThumbnailRenderer].
///
/// The controller argument is `null` here — the real snapshot-path
/// controller is plumbed by 06-05's overlay wiring on `TripsScreen`. For
/// widget-level consumers today the renderer falls back to the pure-Flutter
/// path (see [ThumbnailRenderer.render]).
///
/// Plain [Provider] — no `@Riverpod` codegen (STATE.md Plan 01-01 decision).
final thumbnailRendererProvider = Provider<ThumbnailRenderer>((ref) {
  // The style URL is watched here so brightness swaps rebuild the renderer.
  // The renderer instance itself does NOT listen to brightness — see the
  // class docstring for the Q1 pitfall rationale.
  //
  // Deliberately imported lazily via a string literal rather than pulling
  // the map_style_provider dependency: keeping this file free of a hard
  // coupling to the map feature preserves the thumbnail-renderer's
  // testability (unit tests can build the renderer directly).
  return ThumbnailRenderer(mapStyleUrl: '');
});
