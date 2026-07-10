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
//   1. lineColor case expression picks correct fullHex/partialHex per brightness.
//   2. lineOpacity has the 0.92 full branch and the ['max',0.25,...] partial branch.
//   3. lineWidth is an 'interpolate' expression with the documented zoom stops.
//   4. coverageOverlayApplierProvider default is MapLibreCoverageOverlayApplier.

import 'dart:ui' show Brightness;

import 'package:auto_explore/features/coverage/domain/coverage_color_preset.dart';
import 'package:auto_explore/features/coverage/presentation/coverage_overlay_layers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // -------------------------------------------------------------------------
  // lineColor expressions per brightness
  // -------------------------------------------------------------------------

  group('coverageLinePaintExpressions — lineColor', () {
    test('amber light: fullHex = #FF8C00, partialHex = #FFCD6B', () {
      final exprs = coverageLinePaintExpressions(
        CoverageColorPreset.amber,
        Brightness.light,
      );
      final lineColor = exprs.lineColor;
      // Structure: ['case', ['==', ['get','is_full'], 1], fullHex, partialHex]
      expect(lineColor[0], equals('case'));
      expect(lineColor[2], equals('#FF8C00')); // full hex
      expect(lineColor[3], equals('#FFCD6B')); // partial hex
    });

    test('amber dark: fullHex = #FFA726, partialHex = #FFD54F', () {
      final exprs = coverageLinePaintExpressions(
        CoverageColorPreset.amber,
        Brightness.dark,
      );
      final lineColor = exprs.lineColor;
      expect(lineColor[2], equals('#FFA726')); // full hex dark
      expect(lineColor[3], equals('#FFD54F')); // partial hex dark
    });

    test('lineColor case expression has correct is_full == 1 condition', () {
      final exprs = coverageLinePaintExpressions(
        CoverageColorPreset.amber,
        Brightness.light,
      );
      final lineColor = exprs.lineColor;
      // lineColor[1] is the condition: ['==', ['get', 'is_full'], 1]
      final condition = lineColor[1] as List;
      expect(condition[0], equals('=='));
      final getExpr = condition[1] as List;
      expect(getExpr[0], equals('get'));
      expect(getExpr[1], equals('is_full'));
      expect(condition[2], equals(1)); // int, not bool
    });

    test('green light: fullHex = #2ECC71', () {
      final exprs = coverageLinePaintExpressions(
        CoverageColorPreset.green,
        Brightness.light,
      );
      expect(exprs.lineColor[2], equals('#2ECC71'));
    });
  });

  // -------------------------------------------------------------------------
  // lineOpacity expressions
  // -------------------------------------------------------------------------

  group('coverageLinePaintExpressions — lineOpacity', () {
    test('lineOpacity structure is a case expression', () {
      final exprs = coverageLinePaintExpressions(
        CoverageColorPreset.amber,
        Brightness.light,
      );
      final op = exprs.lineOpacity;
      expect(op[0], equals('case'));
    });

    test('full-way opacity is 0.92', () {
      final exprs = coverageLinePaintExpressions(
        CoverageColorPreset.amber,
        Brightness.light,
      );
      final op = exprs.lineOpacity;
      // Structure: ['case', condition, 0.92, partialBranch]
      expect(op[2], closeTo(0.92, 1e-10));
    });

    test('partial-way opacity branch starts with max', () {
      final exprs = coverageLinePaintExpressions(
        CoverageColorPreset.amber,
        Brightness.light,
      );
      final op = exprs.lineOpacity;
      // op[3] = partial branch: ['max', 0.25, ['*', 0.85, ['get','fraction']]]
      final partialBranch = op[3] as List;
      expect(partialBranch[0], equals('max'));
    });

    test('partial-way opacity floor is 0.25', () {
      final exprs = coverageLinePaintExpressions(
        CoverageColorPreset.amber,
        Brightness.light,
      );
      final partialBranch = exprs.lineOpacity[3] as List;
      // partialBranch[1] = floor value
      expect(partialBranch[1], closeTo(0.25, 1e-10));
    });

    test('partial-way opacity scale factor is 0.85', () {
      final exprs = coverageLinePaintExpressions(
        CoverageColorPreset.amber,
        Brightness.light,
      );
      final partialBranch = exprs.lineOpacity[3] as List;
      // partialBranch[2] = ['*', 0.85, ['get','fraction']]
      final mulExpr = partialBranch[2] as List;
      expect(mulExpr[0], equals('*'));
      expect(mulExpr[1], closeTo(0.85, 1e-10));
      // mulExpr[2] = ['get', 'fraction']
      final getExpr = mulExpr[2] as List;
      expect(getExpr[0], equals('get'));
      expect(getExpr[1], equals('fraction'));
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
