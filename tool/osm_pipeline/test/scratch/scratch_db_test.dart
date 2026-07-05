import 'dart:typed_data';

import 'package:osm_pipeline/scratch/scratch_db.dart';
import 'package:test/test.dart';

void main() {
  group('ScratchDb', () {
    late ScratchDb db;

    setUp(() {
      db = ScratchDb.openTempFile();
    });

    tearDown(() {
      db.close(deleteFile: true);
    });

    test('opens with expected pragmas + creates all four tables', () {
      // Round-trip check: each table exists via a SELECT COUNT(*).
      expect(db.countRows('nodes_raw'), 0);
      expect(db.countRows('ways_raw'), 0);
      expect(db.countRows('relations_raw'), 0);
      expect(db.countRows('filter_stats'), 0);

      final journal = db.raw.select('PRAGMA journal_mode;').first;
      expect(journal.values.first.toString().toLowerCase(), 'off');
    });

    test('insertWayKfz + insertNode round-trip via flush + read', () {
      db
        ..insertWayKfz(
          id: 1,
          nodeIds: const [10, 11, 12],
          isDirectional: true,
          onewayTag: 'yes',
          highway: 'primary',
          name: 'Musterstraße',
          ref: 'M1',
          maxspeed: '50',
        )
        ..insertNode(id: 10, lat: 52.5, lng: 13.4)
        ..insertNode(id: 11, lat: 52.5001, lng: 13.4001)
        ..insertNode(id: 12, lat: 52.5002, lng: 13.4002)
        ..flush();

      expect(db.countRows('ways_raw'), 1);
      expect(db.countRows('nodes_raw'), 3);

      final rows =
          db.raw.select('SELECT * FROM ways_raw WHERE id = 1;');
      expect(rows, hasLength(1));
      final row = rows.first;
      expect(row['source'], 'kfz');
      expect(row['is_counting'], 1);
      expect(row['is_directional'], 1);
      expect(row['oneway_tag'], 'yes');
      expect(row['highway'], 'primary');
      expect(row['name'], 'Musterstraße');
      expect(row['ref'], 'M1');
      expect(row['maxspeed'], '50');
      // Feldweg-only columns are null for Kfz.
      expect(row['surface'], isNull);
      expect(row['motor_vehicle'], isNull);
      expect(row['service'], isNull);

      final nodeIds =
          decodeNodeIds(Uint8List.fromList(row['node_ids'] as List<int>));
      expect(nodeIds, orderedEquals([10, 11, 12]));
    });

    test('insertWayFeldweg persists Feldweg-specific columns', () {
      db
        ..insertWayFeldweg(
          id: 42,
          nodeIds: const [20, 21],
          highway: 'track',
          name: null,
          surface: 'gravel',
          motorVehicle: null,
          service: null,
        )
        ..flush();

      final row =
          db.raw.select('SELECT * FROM ways_raw WHERE id = 42;').first;
      expect(row['source'], 'feldweg');
      expect(row['is_counting'], 0);
      expect(row['is_directional'], 0);
      expect(row['highway'], 'track');
      expect(row['surface'], 'gravel');
      // Kfz-only columns are null for Feldweg.
      expect(row['maxspeed'], isNull);
      expect(row['ref'], isNull);
      expect(row['oneway_tag'], isNull);
    });

    test('bumpStat increments filter_stats atomically', () {
      db
        ..bumpStat('highway_road')
        ..bumpStat('highway_road')
        ..bumpStat('highway_road')
        ..bumpStat('deleted_node_ref')
        ..flush();

      expect(db.readStat('highway_road'), 3);
      expect(db.readStat('deleted_node_ref'), 1);
      expect(db.readStat('nonexistent_key'), 0);
    });

    test('encodeNodeIds / decodeNodeIds round-trip preserves order + values',
        () {
      const ids = [1, 2, 100, -5, 1 << 40];
      final bytes = encodeNodeIds(ids);
      expect(bytes.length, 4 + ids.length * 8);
      final decoded = decodeNodeIds(bytes);
      expect(decoded, orderedEquals(ids));
    });

    test('empty node-id list encodes to a 4-byte header only', () {
      final bytes = encodeNodeIds(const <int>[]);
      expect(bytes.length, 4);
      expect(decodeNodeIds(bytes), isEmpty);
    });
  });
}
