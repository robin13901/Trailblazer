// Trailblazer Phase 6, Plan 06-07 (re-drive #4 — detail-screen crash fix):
// TripRouteView — a static, map-free render of a trip's route.
//
// WHY: the detail screen previously mounted a SECOND full MapLibreMap, i.e. a
// second native GL/EGL surface (~500 MB) on top of the Map tab's — the device
// OOM-crashed on navigation. This widget draws the route geometry the detail
// screen already computes (raw GPS polyline + matched interval segments) with
// a CustomPainter on a themed background. No platform view, no second GL
// context, negligible memory.
//
// It is deliberately NOT a slippy map — no OSM tiles behind the route. If the
// user wants tiles on the detail screen, the fallback is to reuse the single
// Map-tab MapLibre instance (a larger change, tracked separately).

import 'dart:math' as math;

import 'package:auto_explore/features/trips/presentation/widgets/trip_overlay_layers.dart';
import 'package:flutter/material.dart';
import 'package:maplibre_gl/maplibre_gl.dart' show LatLng, LatLngBounds;

/// Static route render for the trip-detail screen.
///
/// Draws [TripDetailData.rawPolyline] in [rawColor] (muted) and
/// [TripDetailData.matchedSegments] in [matchedColor] (accent) on a themed
/// background, framed to [TripDetailData.bounds] (falling back to the polyline
/// extent). Renders an empty-state message when there is no geometry.
class TripRouteView extends StatelessWidget {
  const TripRouteView({
    required this.data,
    required this.rawColor,
    required this.matchedColor,
    super.key,
  });

  final TripDetailData data;
  final Color rawColor;
  final Color matchedColor;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bounds = data.bounds ?? _boundsOf(data.rawPolyline);

    if (bounds == null || data.rawPolyline.length < 2) {
      return ColoredBox(
        color: scheme.surfaceContainerHighest,
        child: Center(
          child: Text(
            'Keine Route zum Anzeigen.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
          ),
        ),
      );
    }

    return ColoredBox(
      color: scheme.surfaceContainerHighest,
      child: CustomPaint(
        painter: _RoutePainter(
          rawPolyline: data.rawPolyline,
          matchedSegments: data.matchedSegments,
          bounds: bounds,
          rawColor: rawColor,
          matchedColor: matchedColor,
        ),
        // Fill the available space; CustomPaint needs a size to paint into.
        child: const SizedBox.expand(),
      ),
    );
  }

  static LatLngBounds? _boundsOf(List<LatLng> polyline) {
    if (polyline.length < 2) return null;
    var minLat = polyline.first.latitude;
    var maxLat = minLat;
    var minLon = polyline.first.longitude;
    var maxLon = minLon;
    for (final p in polyline) {
      minLat = math.min(minLat, p.latitude);
      maxLat = math.max(maxLat, p.latitude);
      minLon = math.min(minLon, p.longitude);
      maxLon = math.max(maxLon, p.longitude);
    }
    if (maxLat - minLat < 1e-4) {
      minLat -= 5e-4;
      maxLat += 5e-4;
    }
    if (maxLon - minLon < 1e-4) {
      minLon -= 5e-4;
      maxLon += 5e-4;
    }
    return LatLngBounds(
      southwest: LatLng(minLat, minLon),
      northeast: LatLng(maxLat, maxLon),
    );
  }
}

class _RoutePainter extends CustomPainter {
  _RoutePainter({
    required this.rawPolyline,
    required this.matchedSegments,
    required this.bounds,
    required this.rawColor,
    required this.matchedColor,
  });

  final List<LatLng> rawPolyline;
  final List<List<LatLng>> matchedSegments;
  final LatLngBounds bounds;
  final Color rawColor;
  final Color matchedColor;

  static const double _padding = 24;

  @override
  void paint(Canvas canvas, Size size) {
    final sw = bounds.southwest;
    final ne = bounds.northeast;
    final latSpan = ne.latitude - sw.latitude;
    final lonSpan = ne.longitude - sw.longitude;
    if (latSpan <= 0 || lonSpan <= 0) return;

    final innerW = size.width - _padding * 2;
    final innerH = size.height - _padding * 2;
    if (innerW <= 0 || innerH <= 0) return;

    // Equirectangular fit, preserving aspect ratio. Longitude degrees are
    // narrower than latitude degrees at this latitude, so weight the E-W span
    // by cos(lat) when choosing the fit scale — otherwise the route looks
    // stretched horizontally.
    final cosLat = math.cos((sw.latitude + ne.latitude) / 2 * math.pi / 180);
    final geoW = lonSpan * (cosLat == 0 ? 1 : cosLat);
    final geoH = latSpan;
    final scale = math.min(innerW / geoW, innerH / geoH);
    final drawW = geoW * scale;
    final drawH = geoH * scale;
    final offsetX = _padding + (innerW - drawW) / 2;
    final offsetY = _padding + (innerH - drawH) / 2;

    Offset project(LatLng p) {
      final xFrac = (p.longitude - sw.longitude) / lonSpan;
      // Latitude grows north; screen y grows down → invert.
      final yFrac = 1 - (p.latitude - sw.latitude) / latSpan;
      return Offset(offsetX + xFrac * drawW, offsetY + yFrac * drawH);
    }

    // Raw trace first (muted, underneath), then matched segments (accent, on
    // top) so the driven portions read clearly against the raw path.
    _drawPolyline(canvas, rawPolyline, project, rawColor, 3, 0.9);
    for (final seg in matchedSegments) {
      _drawPolyline(canvas, seg, project, matchedColor, 5, 1);
    }
  }

  void _drawPolyline(
    Canvas canvas,
    List<LatLng> pts,
    Offset Function(LatLng) project,
    Color color,
    double width,
    double opacity,
  ) {
    if (pts.length < 2) return;
    final paint = Paint()
      ..color = color.withValues(alpha: opacity)
      ..strokeWidth = width
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final path = Path();
    final first = project(pts.first);
    path.moveTo(first.dx, first.dy);
    for (var i = 1; i < pts.length; i++) {
      final o = project(pts[i]);
      path.lineTo(o.dx, o.dy);
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_RoutePainter old) =>
      old.rawPolyline != rawPolyline ||
      old.matchedSegments != matchedSegments ||
      old.bounds != bounds ||
      old.rawColor != rawColor ||
      old.matchedColor != matchedColor;
}
