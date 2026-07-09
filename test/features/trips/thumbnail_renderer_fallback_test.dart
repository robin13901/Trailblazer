import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:auto_explore/features/trips/data/thumbnail_renderer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

/// PNG magic number (RFC 2083): first 8 bytes of every valid PNG.
const List<int> _kPngMagic = [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
];

bool _startsWithPngMagic(Uint8List bytes) {
  if (bytes.length < _kPngMagic.length) return false;
  for (var i = 0; i < _kPngMagic.length; i++) {
    if (bytes[i] != _kPngMagic[i]) return false;
  }
  return true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final berlinBbox = LatLngBounds(
    southwest: const LatLng(52.5, 13.35),
    northeast: const LatLng(52.55, 13.45),
  );

  ThumbnailRenderer renderer() =>
      ThumbnailRenderer(mapStyleUrl: 'https://example.invalid/style.json');

  Future<ui.Image> decode(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    return frame.image;
  }

  group('ThumbnailRenderer.renderFallback', () {
    test('returns a PNG-magic-prefixed Uint8List for a 4-point polyline',
        () async {
      final bytes = await renderer().renderFallback(
        polyline: const [
          LatLng(52.51, 13.36),
          LatLng(52.52, 13.38),
          LatLng(52.53, 13.40),
          LatLng(52.54, 13.42),
        ],
        bbox: berlinBbox,
      );

      expect(bytes, isA<Uint8List>());
      expect(bytes.length, greaterThan(_kPngMagic.length));
      expect(_startsWithPngMagic(bytes), isTrue);
    });

    test('empty polyline still produces a valid decode-able PNG', () async {
      final bytes = await renderer().renderFallback(
        polyline: const [],
        bbox: berlinBbox,
      );

      expect(_startsWithPngMagic(bytes), isTrue);

      // Must decode into a valid image (background-only tile).
      final img = await decode(bytes);
      addTearDown(img.dispose);
      expect(img.width, greaterThan(0));
      expect(img.height, greaterThan(0));
    });

    test('polyline entirely outside bbox still returns a valid PNG',
        () async {
      final bytes = await renderer().renderFallback(
        // Points far south-west of the Berlin bbox — all get clipped.
        polyline: const [
          LatLng(48, 8),
          LatLng(48.1, 8.1),
        ],
        bbox: berlinBbox,
      );

      expect(_startsWithPngMagic(bytes), isTrue);
      final img = await decode(bytes);
      addTearDown(img.dispose);
      expect(img.width, greaterThan(0));
    });

    test('two calls with the same input produce byte-identical output',
        () async {
      final r = renderer();
      final a = await r.renderFallback(
        polyline: const [
          LatLng(52.51, 13.36),
          LatLng(52.53, 13.40),
        ],
        bbox: berlinBbox,
      );
      final b = await r.renderFallback(
        polyline: const [
          LatLng(52.51, 13.36),
          LatLng(52.53, 13.40),
        ],
        bbox: berlinBbox,
      );

      expect(a, orderedEquals(b));
    });

    test('output PNG decodes to the configured 320x120 raster size',
        () async {
      final bytes = await renderer().renderFallback(
        polyline: const [
          LatLng(52.51, 13.36),
          LatLng(52.53, 13.40),
        ],
        bbox: berlinBbox,
      );

      final img = await decode(bytes);
      addTearDown(img.dispose);
      expect(img.width, 320);
      expect(img.height, 120);
    });
  });
}
