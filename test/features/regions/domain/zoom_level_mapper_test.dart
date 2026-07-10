// Trailblazer Phase 8, Plan 08-01:
// Unit tests for zoom_level_mapper.dart — covers all breakpoints,
// fallback chain, and kFallbackLevels constant.

import 'package:auto_explore/features/regions/domain/zoom_level_mapper.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('zoomToAdminLevel', () {
    group('returns 2 (Deutschland) below zoom 6', () {
      test('zoom 0', () => expect(zoomToAdminLevel(0), 2));
      test('zoom 5.9', () => expect(zoomToAdminLevel(5.9), 2));
    });

    group('returns 4 (Bundesland) at zoom 6–8.x', () {
      test('zoom 6', () => expect(zoomToAdminLevel(6), 4));
      test('zoom 7', () => expect(zoomToAdminLevel(7), 4));
      test('zoom 8.9', () => expect(zoomToAdminLevel(8.9), 4));
    });

    group('returns 6 (Regierungsbezirk) at zoom 9–10.x', () {
      test('zoom 9', () => expect(zoomToAdminLevel(9), 6));
      test('zoom 10', () => expect(zoomToAdminLevel(10), 6));
      test('zoom 10.9', () => expect(zoomToAdminLevel(10.9), 6));
    });

    group('returns 8 (Landkreis) at zoom 11–12.x', () {
      test('zoom 11', () => expect(zoomToAdminLevel(11), 8));
      test('zoom 12', () => expect(zoomToAdminLevel(12), 8));
      test('zoom 12.9', () => expect(zoomToAdminLevel(12.9), 8));
    });

    group('returns 9 (Samtgemeinde) at zoom 13–14.x', () {
      test('zoom 13', () => expect(zoomToAdminLevel(13), 9));
      test('zoom 14', () => expect(zoomToAdminLevel(14), 9));
      test('zoom 14.9', () => expect(zoomToAdminLevel(14.9), 9));
    });

    group('returns 10 (Gemeinde/Ortsteil) at zoom 15+', () {
      test('zoom 15', () => expect(zoomToAdminLevel(15), 10));
      test('zoom 16', () => expect(zoomToAdminLevel(16), 10));
      test('zoom 20', () => expect(zoomToAdminLevel(20), 10));
    });
  });

  group('kFallbackLevels', () {
    test('is exactly [10, 9, 8, 6, 4, 2]', () {
      expect(kFallbackLevels, equals([10, 9, 8, 6, 4, 2]));
    });

    test('contains no unlisted levels', () {
      const valid = {2, 4, 6, 8, 9, 10};
      for (final level in kFallbackLevels) {
        expect(valid, contains(level));
      }
    });
  });

  group('fallbackLevelsFrom', () {
    test('zoom 16 -> [10, 9, 8, 6, 4, 2] (start from 10)', () {
      expect(fallbackLevelsFrom(16), equals([10, 9, 8, 6, 4, 2]));
    });

    test('zoom 15 -> [10, 9, 8, 6, 4, 2] (start from 10)', () {
      expect(fallbackLevelsFrom(15), equals([10, 9, 8, 6, 4, 2]));
    });

    test('zoom 14 -> [9, 8, 6, 4, 2] (start from 9)', () {
      expect(fallbackLevelsFrom(14), equals([9, 8, 6, 4, 2]));
    });

    test('zoom 11.5 -> [8, 6, 4, 2] (start from 8)', () {
      expect(fallbackLevelsFrom(11.5), equals([8, 6, 4, 2]));
    });

    test('zoom 9.5 -> [6, 4, 2] (start from 6)', () {
      expect(fallbackLevelsFrom(9.5), equals([6, 4, 2]));
    });

    test('zoom 7 -> [4, 2] (start from 4)', () {
      expect(fallbackLevelsFrom(7), equals([4, 2]));
    });

    test('zoom 3 -> [2] (Deutschland, final fallback)', () {
      expect(fallbackLevelsFrom(3), equals([2]));
    });

    test('result is never empty (pill never blank)', () {
      for (final zoom in [0.0, 3.0, 6.0, 9.0, 11.0, 13.0, 15.0, 20.0]) {
        expect(fallbackLevelsFrom(zoom), isNotEmpty,
            reason: 'zoom $zoom produced empty fallback list');
      }
    });
  });
}
