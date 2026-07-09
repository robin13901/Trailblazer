import 'dart:io';
import 'dart:typed_data';

import 'package:auto_explore/features/trips/data/thumbnail_providers.dart';
import 'package:auto_explore/features/trips/data/thumbnail_renderer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

/// Small helper for logging thumbnail-render failures without importing the
/// full app logger surface.
final Logger _log = Logger('trip_thumbnail');

/// Card thumbnail for a trip.
///
/// Consumes [thumbnailCacheProvider]. On a cache hit renders an [Image.file]
/// directly. On a miss it delegates to [_RenderingPlaceholder] which shows
/// a neutral placeholder and kicks off an async render via
/// [thumbnailRendererProvider]; when render completes it stores the PNG in
/// the cache and TripThumbnail rebuilds via the `.select(...)` watch.
///
/// The parent (`TripCard`, owned by 06-05) provides `tripId`, `polyline`,
/// and `bbox`. The widget owns nothing else — no timers, no state.
class TripThumbnail extends ConsumerWidget {
  const TripThumbnail({
    required this.tripId,
    required this.polyline,
    required this.bbox,
    this.width = 320,
    this.height = 120,
    super.key,
  });

  final int tripId;
  final List<LatLng> polyline;
  final LatLngBounds bbox;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cached = ref.watch(
      thumbnailCacheProvider.select((s) => s.paths[tripId]),
    );
    if (cached != null) {
      return Image.file(
        File(cached),
        width: width,
        height: height,
        fit: BoxFit.cover,
      );
    }
    return _RenderingPlaceholder(
      tripId: tripId,
      polyline: polyline,
      bbox: bbox,
      width: width,
      height: height,
    );
  }
}

/// Renders a neutral placeholder while an async fallback render populates
/// the [thumbnailCacheProvider] for [tripId]. Once the render finishes,
/// [TripThumbnail]'s `.select(...)` watch picks up the new path and swaps
/// this widget out for the cached [Image.file].
class _RenderingPlaceholder extends ConsumerStatefulWidget {
  const _RenderingPlaceholder({
    required this.tripId,
    required this.polyline,
    required this.bbox,
    required this.width,
    required this.height,
  });

  final int tripId;
  final List<LatLng> polyline;
  final LatLngBounds bbox;
  final double width;
  final double height;

  @override
  ConsumerState<_RenderingPlaceholder> createState() =>
      _RenderingPlaceholderState();
}

class _RenderingPlaceholderState extends ConsumerState<_RenderingPlaceholder> {
  bool _kickedOff = false;

  @override
  void initState() {
    super.initState();
    // Kick off after the first frame so the placeholder paints immediately.
    WidgetsBinding.instance.addPostFrameCallback((_) => _startRender());
  }

  Future<void> _startRender() async {
    if (_kickedOff) return;
    _kickedOff = true;

    final renderer = ref.read(thumbnailRendererProvider);
    final cache = ref.read(thumbnailCacheProvider.notifier);
    try {
      final bytes = await renderer.renderFallback(
        polyline: widget.polyline,
        bbox: widget.bbox,
      );
      if (!mounted) return;
      if (bytes.isEmpty) return;
      await cache.store(widget.tripId, Uint8List.fromList(bytes));
    } on Object catch (e, st) {
      _log.warning(
        'Thumbnail render failed for trip ${widget.tripId}',
        e,
        st,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ColoredBox(
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
      child: SizedBox(width: widget.width, height: widget.height),
    );
  }
}
