import 'package:osm_pipeline/pmtiles/layer_schema.dart';
import 'package:test/test.dart';

void main() {
  group('Layers constants', () {
    test('exposes four layer names', () {
      expect(Layers.roads, 'roads');
      expect(Layers.adminBoundaries, 'admin_boundaries');
      expect(Layers.water, 'water');
      expect(Layers.labels, 'labels');
    });
  });

  group('collapseHighwayKind', () {
    test('collapses link variants to parent kind', () {
      expect(collapseHighwayKind('motorway_link'), 'motorway');
      expect(collapseHighwayKind('trunk_link'), 'trunk');
      expect(collapseHighwayKind('primary_link'), 'primary');
      expect(collapseHighwayKind('secondary_link'), 'secondary');
      expect(collapseHighwayKind('tertiary_link'), 'tertiary');
    });

    test('preserves top-tier kinds unchanged', () {
      expect(collapseHighwayKind('motorway'), 'motorway');
      expect(collapseHighwayKind('trunk'), 'trunk');
      expect(collapseHighwayKind('primary'), 'primary');
      expect(collapseHighwayKind('secondary'), 'secondary');
      expect(collapseHighwayKind('tertiary'), 'tertiary');
    });

    test('collapses lower-tier residential/unclassified variants to minor', () {
      expect(collapseHighwayKind('residential'), 'minor');
      expect(collapseHighwayKind('unclassified'), 'minor');
      expect(collapseHighwayKind('living_street'), 'minor');
      expect(collapseHighwayKind('road'), 'minor');
    });

    test('surfaces track and path unchanged', () {
      expect(collapseHighwayKind('track'), 'track');
      expect(collapseHighwayKind('path'), 'path');
    });

    test('collapses unknown values to other', () {
      expect(collapseHighwayKind('anything_weird'), 'other');
      expect(collapseHighwayKind(''), 'other');
      expect(collapseHighwayKind('cycleway'), 'other');
    });
  });

  group('minZoomForRoadKind', () {
    test('honours Protomaps ladder', () {
      expect(minZoomForRoadKind('motorway'), 5);
      expect(minZoomForRoadKind('trunk'), 6);
      expect(minZoomForRoadKind('primary'), 7);
      expect(minZoomForRoadKind('secondary'), 9);
      expect(minZoomForRoadKind('tertiary'), 10);
      expect(minZoomForRoadKind('minor'), 11);
      expect(minZoomForRoadKind('track'), 11);
      expect(minZoomForRoadKind('path'), 11);
    });

    test('defaults unknown kinds to 11', () {
      expect(minZoomForRoadKind('other'), 11);
      expect(minZoomForRoadKind(''), 11);
    });
  });

  group('adminKindForLevel', () {
    test('maps documented levels', () {
      expect(adminKindForLevel(2), 'country');
      expect(adminKindForLevel(4), 'state');
      expect(adminKindForLevel(6), 'county');
      expect(adminKindForLevel(8), 'municipality');
      expect(adminKindForLevel(9), 'district');
      expect(adminKindForLevel(10), 'suburb');
    });

    test('collapses out-of-range levels to other', () {
      expect(adminKindForLevel(1), 'other');
      expect(adminKindForLevel(3), 'other');
      expect(adminKindForLevel(11), 'other');
    });
  });

  group('minZoomForAdminLevel', () {
    test('honours the 04-RESEARCH §3 ladder', () {
      expect(minZoomForAdminLevel(2), 0);
      expect(minZoomForAdminLevel(4), 0);
      expect(minZoomForAdminLevel(6), 6);
      expect(minZoomForAdminLevel(8), 9);
      expect(minZoomForAdminLevel(9), 9);
      expect(minZoomForAdminLevel(10), 9);
    });
  });
}
