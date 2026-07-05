import 'package:osm_pipeline/admin/admin_relation_filter.dart';
import 'package:osm_pipeline/pbf/entities.dart';
import 'package:test/test.dart';

OsmRelation _relation(Map<String, String> tags, {int id = 1}) => OsmRelation(
      id: id,
      tags: tags,
      members: const [],
    );

void main() {
  group('isAdminRelation', () {
    test('accepts type=boundary + boundary=administrative + level=2', () {
      final r = _relation({
        'type': 'boundary',
        'boundary': 'administrative',
        'admin_level': '2',
        'name': 'Deutschland',
      });
      expect(isAdminRelation(r), isTrue);
    });

    for (final lvl in kTargetAdminLevels) {
      test('accepts admin_level=$lvl on a properly tagged relation', () {
        final r = _relation({
          'type': 'boundary',
          'boundary': 'administrative',
          'admin_level': '$lvl',
        });
        expect(isAdminRelation(r), isTrue);
      });
    }

    test('rejects admin_level=3 (Regierungsbezirk — out of scope)', () {
      final r = _relation({
        'type': 'boundary',
        'boundary': 'administrative',
        'admin_level': '3',
      });
      expect(isAdminRelation(r), isFalse);
    });

    test('rejects admin_level=11 (finer than Ortsteil)', () {
      final r = _relation({
        'type': 'boundary',
        'boundary': 'administrative',
        'admin_level': '11',
      });
      expect(isAdminRelation(r), isFalse);
    });

    test('rejects a natural=water multipolygon (not administrative)', () {
      final r = _relation({
        'type': 'multipolygon',
        'natural': 'water',
        'name': 'Bodensee',
      });
      expect(isAdminRelation(r), isFalse);
    });

    test('rejects boundary=maritime', () {
      final r = _relation({
        'type': 'boundary',
        'boundary': 'maritime',
        'admin_level': '4',
      });
      expect(isAdminRelation(r), isFalse);
    });

    test(
        'accepts type=multipolygon + boundary=administrative + admin_level=8 '
        '(Landkreise are empirically tagged this way in DE)', () {
      final r = _relation({
        'type': 'multipolygon',
        'boundary': 'administrative',
        'admin_level': '8',
      });
      expect(isAdminRelation(r), isTrue);
    });

    test('rejects when admin_level is missing', () {
      final r = _relation({
        'type': 'boundary',
        'boundary': 'administrative',
      });
      expect(isAdminRelation(r), isFalse);
    });

    test('rejects when admin_level is non-numeric', () {
      final r = _relation({
        'type': 'boundary',
        'boundary': 'administrative',
        'admin_level': 'foo',
      });
      expect(isAdminRelation(r), isFalse);
    });
  });

  group('kCityStateNames', () {
    test('contains exactly the three DE city-states', () {
      expect(kCityStateNames, {'Berlin', 'Hamburg', 'Bremen'});
    });
  });
}
