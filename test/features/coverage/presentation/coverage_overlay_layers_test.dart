// Trailblazer Phase 7, Plan 07-04:
// Unit tests for the coverage overlay paint-expression builder and provider.
//
// Widget tests cannot build a real MapLibreMapController (platform view
// not available in the test host). We therefore test the PUBLIC pure
// expression builder coverageLinePaintExpressions() directly — that function
// is extracted from _paint() precisely to make the expression logic
// unit-testable without a controller.
//
// Coverage:
//   1. lineColor is a solid ['literal', fullHex] per brightness (gradient
//      removed 2026-07-13 — coverage line is the trimmed on-road GPS trail).
//   2. lineOpacity is a constant ['literal', 0.92].
//   3. lineWidth is an 'interpolate' expression with the documented zoom stops.
//   4. coverageOverlayApplierProvider default is MapLibreCoverageOverlayApplier.

import 'dart:ui' show Brightness;

import 'package:auto_explore/features/coverage/domain/coverage_color_preset.dart';
import 'package:auto_explore/features/coverage/presentation/coverage_overlay_layers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // -------------------------------------------------------------------------
  // lineColor expressions per brightness — solid single color
  // -------------------------------------------------------------------------

  group('coverageLinePaintExpressions — lineColor', () {
    test('amber light: solid fullHex #FF8C00', () {
      final exprs = coverageLinePaintExpressions(
        CoverageColorPreset.amber,
        Brightness.light,
      );
      final lineColor = exprs.lineColor;
      // Structure: ['literal', fullHex] — no case/gradient.
      expect(lineColor[0], equals('literal'));
      expect(lineColor[1], equals('#FF8C00'));
    });

    test('amber dark: solid fullHex #FFA726', () {
      final exprs = coverageLinePaintExpressions(
        CoverageColorPreset.amber,
        Brightness.dark,
      );
      expect(exprs.lineColor[1], equals('#FFA726'));
    });

    test('green light: solid fullHex #2ECC71', () {
      final exprs = coverageLinePaintExpressions(
        CoverageColorPreset.green,
        Brightness.light,
      );
      expect(exprs.lineColor[1], equals('#2ECC71'));
    });
  });

  // -------------------------------------------------------------------------
  // lineOpacity expression — constant full opacity
  // -------------------------------------------------------------------------

  group('coverageLinePaintExpressions — lineOpacity', () {
    test('opacity is a constant 0.92 literal', () {
      final exprs = coverageLinePaintExpressions(
        CoverageColorPreset.amber,
        Brightness.light,
      );
      final op = exprs.lineOpacity;
      expect(op[0], equals('literal'));
      expect(op[1], closeTo(0.92, 1e-10));
    });
  });

  // -------------------------------------------------------------------------
  // lineWidth expression (zoom interpolation)
  // -------------------------------------------------------------------------

  group('coverageLinePaintExpressions — lineWidth', () {
    test('lineWidth is an interpolate expression', () {
      final exprs = coverageLinePaintExpressions(
        CoverageColorPreset.amber,
        Brightness.light,
      );
      final w = exprs.lineWidth;
      expect(w[0], equals('interpolate'));
    });

    test('lineWidth uses linear interpolation', () {
      final w = coverageLinePaintExpressions(
        CoverageColorPreset.amber,
        Brightness.light,
      ).lineWidth;
      final interpolationType = w[1] as List;
      expect(interpolationType[0], equals('linear'));
    });

    test('lineWidth interpolates on zoom', () {
      final w = coverageLinePaintExpressions(
        CoverageColorPreset.amber,
        Brightness.light,
      ).lineWidth;
      final inputExpr = w[2] as List;
      expect(inputExpr[0], equals('zoom'));
    });

    test('lineWidth has correct zoom stops: z8=2.5, z11=3.0, z13=4.0, z15=5.0, z18=7.0',
        () {
      final w = coverageLinePaintExpressions(
        CoverageColorPreset.amber,
        Brightness.light,
      ).lineWidth;
      // Stops start at index 3: zoom, value, zoom, value, ...
      // [interpolate, [linear], [zoom], 8, 2.5, 11, 3.0, 13, 4.0, 15, 5.0, 18, 7.0]
      expect(w[3], equals(8));
      expect(w[4], closeTo(2.5, 1e-10));
      expect(w[5], equals(11));
      expect(w[6], closeTo(3.0, 1e-10));
      expect(w[7], equals(13));
      expect(w[8], closeTo(4.0, 1e-10));
      expect(w[9], equals(15));
      expect(w[10], closeTo(5.0, 1e-10));
      expect(w[11], equals(18));
      expect(w[12], closeTo(7.0, 1e-10));
    });
  });

  // -------------------------------------------------------------------------
  // Provider default type
  // -------------------------------------------------------------------------

  group('coverageOverlayApplierProvider', () {
    test('default is MapLibreCoverageOverlayApplier', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final applier = container.read(coverageOverlayApplierProvider);
      expect(applier, isA<MapLibreCoverageOverlayApplier>());
    });
  });
}
