import 'package:osm_pipeline/admin/admin_relation_filter.dart';
import 'package:osm_pipeline/admin/multipolygon_assembler.dart';
import 'package:osm_pipeline/admin/wkb_writer.dart';
import 'package:osm_pipeline/pbf/entities.dart';
import 'package:osm_pipeline/scratch/scratch_db_admin_ext.dart';
import 'package:test/test.dart';

// Directly exercises the city-state dual-write BRANCH — the same logic
// extractAdminRegions runs, but at unit level so we don't need to hand-craft
// a whole new PBF fixture just for the Berlin name.
Future<void> writeWithDualIfCityState({
  required OsmRelation rel,
  required Map<int, OsmWay> waysById,
  required Map<int, ({double lat, double lng})> nodesById,
  required InMemoryAdminScratchWriter writer,
}) async {
  final mp = MultipolygonAssembler.assemble(
    rel,
    waysById,
    (nid) => nodesById[nid],
    null,
  );
  if (mp == null) return;
  final lvl = int.parse(rel.tags['admin_level']!);
  final name = rel.tags['name']!;
  final wkb = encodeMultiPolygon(mp);
  final b = mp.bbox();

  var regionId = writer.rows.length;
  regionId++;
  await writer.insertAdminRegion(
    regionId: regionId,
    osmRelationId: rel.id,
    adminLevel: lvl,
    name: name,
    geometryWkb: wkb,
    bboxMinLat: b.minLat,
    bboxMaxLat: b.maxLat,
    bboxMinLng: b.minLng,
    bboxMaxLng: b.maxLng,
  );

  if (lvl == 4 && kCityStateNames.contains(name)) {
    regionId++;
    await writer.insertAdminRegion(
      regionId: regionId,
      osmRelationId: rel.id,
      adminLevel: 6,
      name: name,
      geometryWkb: wkb,
      bboxMinLat: b.minLat,
      bboxMaxLat: b.maxLat,
      bboxMinLng: b.minLng,
      bboxMaxLng: b.maxLng,
    );
  }
}

void main() {
  group('city-state dual-write (pitfall #10)', () {
    late Map<int, OsmWay> waysById;
    late Map<int, ({double lat, double lng})> nodesById;

    setUp(() {
      waysById = {
        1: const OsmWay(
          id: 1,
          tags: {},
          nodeRefs: [10, 11, 12, 13, 10],
        ),
      };
      nodesById = {
        10: (lat: 52.3, lng: 13.0),
        11: (lat: 52.3, lng: 13.8),
        12: (lat: 52.7, lng: 13.8),
        13: (lat: 52.7, lng: 13.0),
      };
    });

    OsmRelation cityStateRelation(String name, int level) => OsmRelation(
          id: 62422,
          tags: {
            'type': 'boundary',
            'boundary': 'administrative',
            'admin_level': '$level',
            'name': name,
          },
          members: const [
            RelationMember(refId: 1, type: OsmMemberType.way, role: 'outer'),
          ],
        );

    test('Berlin at level=4 → 2 rows (level 4 + level 6)', () async {
      final writer = InMemoryAdminScratchWriter()..applyAdminSchema();
      await writeWithDualIfCityState(
        rel: cityStateRelation('Berlin', 4),
        waysById: waysById,
        nodesById: nodesById,
        writer: writer,
      );
      expect(writer.rows.length, 2);
      expect(writer.rows[0].adminLevel, 4);
      expect(writer.rows[1].adminLevel, 6);
      expect(writer.rows[0].osmRelationId, writer.rows[1].osmRelationId,
          reason: 'both writes trace back to the same OSM relation',);
      expect(writer.rows[0].name, 'Berlin');
      expect(writer.rows[1].name, 'Berlin');
    });

    test('Hamburg at level=4 → 2 rows', () async {
      final writer = InMemoryAdminScratchWriter()..applyAdminSchema();
      await writeWithDualIfCityState(
        rel: cityStateRelation('Hamburg', 4),
        waysById: waysById,
        nodesById: nodesById,
        writer: writer,
      );
      expect(writer.rows.length, 2);
    });

    test('Bremen at level=4 → 2 rows', () async {
      final writer = InMemoryAdminScratchWriter()..applyAdminSchema();
      await writeWithDualIfCityState(
        rel: cityStateRelation('Bremen', 4),
        waysById: waysById,
        nodesById: nodesById,
        writer: writer,
      );
      expect(writer.rows.length, 2);
    });

    test('München at level=4 → 1 row (not a city-state)', () async {
      final writer = InMemoryAdminScratchWriter()..applyAdminSchema();
      await writeWithDualIfCityState(
        rel: cityStateRelation('München', 4),
        waysById: waysById,
        nodesById: nodesById,
        writer: writer,
      );
      expect(writer.rows.length, 1);
      expect(writer.rows.single.adminLevel, 4);
    });

    test('Berlin at level=6 → 1 row (dual-write only triggers from level=4)',
        () async {
      final writer = InMemoryAdminScratchWriter()..applyAdminSchema();
      await writeWithDualIfCityState(
        rel: cityStateRelation('Berlin', 6),
        waysById: waysById,
        nodesById: nodesById,
        writer: writer,
      );
      expect(writer.rows.length, 1);
      expect(writer.rows.single.adminLevel, 6);
    });
  });
}
