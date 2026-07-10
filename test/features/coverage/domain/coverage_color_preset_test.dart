// Trailblazer Phase 7, Plan 07-01:
// Unit tests for CoverageColorPreset palette.

import 'dart:ui';

import 'package:auto_explore/features/coverage/domain/coverage_color_preset.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CoverageColorPreset enum', () {
    test('has exactly 5 values', () {
      expect(CoverageColorPreset.values.length, equals(5));
    });

    test('contains CoverageColorPreset.green', () {
      expect(
        CoverageColorPreset.values,
        contains(CoverageColorPreset.green),
      );
    });

    test('fromString("green") == green', () {
      expect(
        CoverageColorPreset.fromString('green'),
        equals(CoverageColorPreset.green),
      );
    });

    test('fromString("bogus") falls back to amber (default)', () {
      expect(
        CoverageColorPreset.fromString('bogus'),
        equals(CoverageColorPreset.amber),
      );
    });

    test('fromString("") falls back to amber', () {
      expect(
        CoverageColorPreset.fromString(''),
        equals(CoverageColorPreset.amber),
      );
    });

    test('fromString round-trips all preset names', () {
      for (final preset in CoverageColorPreset.values) {
        expect(CoverageColorPreset.fromString(preset.name), equals(preset));
      }
    });
  });

  group('CoverageColorPreset.label', () {
    test('each preset has a non-empty label', () {
      for (final preset in CoverageColorPreset.values) {
        expect(preset.label, isNotEmpty);
      }
    });

    test('amber label is "Amber"', () {
      expect(CoverageColorPreset.amber.label, equals('Amber'));
    });

    test('green label is "Green"', () {
      expect(CoverageColorPreset.green.label, equals('Green'));
    });
  });

  group('forBrightness — amber (default preset)', () {
    test('light fullHex is #FF8C00', () {
      expect(
        CoverageColorPreset.amber.forBrightness(Brightness.light).fullHex,
        equals('#FF8C00'),
      );
    });

    test('light partialHex is #FFCD6B', () {
      expect(
        CoverageColorPreset.amber.forBrightness(Brightness.light).partialHex,
        equals('#FFCD6B'),
      );
    });

    test('dark fullHex is #FFA726', () {
      expect(
        CoverageColorPreset.amber.forBrightness(Brightness.dark).fullHex,
        equals('#FFA726'),
      );
    });

    test('dark partialHex is #FFD54F', () {
      expect(
        CoverageColorPreset.amber.forBrightness(Brightness.dark).partialHex,
        equals('#FFD54F'),
      );
    });

    test('light and dark return distinct fullHex values', () {
      final light =
          CoverageColorPreset.amber.forBrightness(Brightness.light).fullHex;
      final dark =
          CoverageColorPreset.amber.forBrightness(Brightness.dark).fullHex;
      expect(light, isNot(equals(dark)));
    });
  });

  group('forBrightness — RESEARCH §REN-01 verbatim hex check', () {
    // Green
    test('green light full is #2ECC71', () {
      expect(
        CoverageColorPreset.green.forBrightness(Brightness.light).fullHex,
        equals('#2ECC71'),
      );
    });
    test('green dark full is #4CAF50', () {
      expect(
        CoverageColorPreset.green.forBrightness(Brightness.dark).fullHex,
        equals('#4CAF50'),
      );
    });

    // Blue
    test('blue light full is #2196F3', () {
      expect(
        CoverageColorPreset.blue.forBrightness(Brightness.light).fullHex,
        equals('#2196F3'),
      );
    });
    test('blue dark full is #42A5F5', () {
      expect(
        CoverageColorPreset.blue.forBrightness(Brightness.dark).fullHex,
        equals('#42A5F5'),
      );
    });

    // Purple
    test('purple light full is #9C27B0', () {
      expect(
        CoverageColorPreset.purple.forBrightness(Brightness.light).fullHex,
        equals('#9C27B0'),
      );
    });

    // Red
    test('red light full is #E53935', () {
      expect(
        CoverageColorPreset.red.forBrightness(Brightness.light).fullHex,
        equals('#E53935'),
      );
    });
    test('red dark full is #EF5350', () {
      expect(
        CoverageColorPreset.red.forBrightness(Brightness.dark).fullHex,
        equals('#EF5350'),
      );
    });
  });

  group('forBrightness — all presets return valid 7-char hex strings', () {
    final hexPattern = RegExp(r'^#[0-9A-Fa-f]{6}$');

    for (final preset in CoverageColorPreset.values) {
      for (final brightness in Brightness.values) {
        test('${preset.name} ${brightness.name} fullHex is valid #RRGGBB', () {
          final colors = preset.forBrightness(brightness);
          expect(
            colors.fullHex,
            matches(hexPattern),
            reason: '${preset.name} ${brightness.name} fullHex',
          );
        });

        test('${preset.name} ${brightness.name} partialHex is valid #RRGGBB',
            () {
          final colors = preset.forBrightness(brightness);
          expect(
            colors.partialHex,
            matches(hexPattern),
            reason: '${preset.name} ${brightness.name} partialHex',
          );
        });
      }
    }
  });

  group('CoverageColors value object', () {
    test('equality by value', () {
      const a = CoverageColors(fullHex: '#FF8C00', partialHex: '#FFCD6B');
      const b = CoverageColors(fullHex: '#FF8C00', partialHex: '#FFCD6B');
      const c = CoverageColors(fullHex: '#FF0000', partialHex: '#FFCD6B');
      expect(a, equals(b));
      expect(a, isNot(equals(c)));
    });

    test('hashCode consistent with equality', () {
      const a = CoverageColors(fullHex: '#FF8C00', partialHex: '#FFCD6B');
      const b = CoverageColors(fullHex: '#FF8C00', partialHex: '#FFCD6B');
      expect(a.hashCode, equals(b.hashCode));
    });

    test('toString includes hex values', () {
      const colors = CoverageColors(fullHex: '#FF8C00', partialHex: '#FFCD6B');
      expect(colors.toString(), contains('#FF8C00'));
      expect(colors.toString(), contains('#FFCD6B'));
    });
  });
}
