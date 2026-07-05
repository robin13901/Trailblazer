// Fixture generator for `tiny.osm.pbf` — the deterministic hand-crafted PBF
// used by `test/pbf/pbf_reader_test.dart`.
//
// Run: `dart run test/fixtures/build_tiny_pbf.dart` from `tool/osm_pipeline/`.
//
// Regeneration should be rare — the reader tests pin entity counts and tag
// values, not byte hashes, so small internal changes here (e.g. adding
// another Feldweg) won't break the tests as long as we keep the current
// counts.
//
// See 04-02-PLAN.md Task 3 for the fixture spec.
//
// ignore_for_file: avoid_print

import 'dart:io';
import 'dart:typed_data';

import 'proto_writer.dart';

Future<void> main() async {
  final bytes = buildTinyPbfBytes();
  final out = File('test/fixtures/tiny.osm.pbf');
  await out.writeAsBytes(bytes);
  print('Wrote ${out.path} — ${bytes.length} bytes');
}

/// Pure function: builds the raw `.osm.pbf` bytes for the tiny fixture.
///
/// Exposed so tests can regenerate in-memory and assert determinism without
/// touching disk.
Uint8List buildTinyPbfBytes() {
  // Two blobs: OSMHeader, then OSMData.
  final out = BytesBuilder(copy: false)
    ..add(_encodeBlob(type: 'OSMHeader', body: _buildHeaderBlock()))
    ..add(_encodeBlob(type: 'OSMData', body: _buildPrimitiveBlock()));
  return out.toBytes();
}

// -----------------------------------------------------------------------
// Blob envelope: 4-byte BE length prefix → BlobHeader → Blob (with zlib).
// -----------------------------------------------------------------------

Uint8List _encodeBlob({required String type, required Uint8List body}) {
  final compressed = ZLibCodec().encode(body);
  final blob = ProtoWriter()
    ..writeVarint(2, body.length) // raw_size
    ..writeBytes(3, compressed); // zlib_data
  final blobBytes = blob.takeBytes();

  final header = ProtoWriter()
    ..writeString(1, type) // type
    ..writeVarint(3, blobBytes.length); // datasize
  final headerBytes = header.takeBytes();

  final prefix = Uint8List(4);
  ByteData.sublistView(prefix).setUint32(0, headerBytes.length);

  return Uint8List.fromList([...prefix, ...headerBytes, ...blobBytes]);
}

// -----------------------------------------------------------------------
// OSMHeader block.
// -----------------------------------------------------------------------

Uint8List _buildHeaderBlock() {
  final w = ProtoWriter()
    // required_features: OsmSchema-V0.6 + DenseNodes (matches our reader).
    ..writeString(4, 'OsmSchema-V0.6')
    ..writeString(4, 'DenseNodes')
    ..writeString(16, 'trailblazer-tiny-fixture-builder') // writingprogram
    ..writeString(17, 'trailblazer-04-02-plan-task-3'); // source
  // No bbox — optional.
  return w.takeBytes();
}

// -----------------------------------------------------------------------
// PrimitiveBlock: string table + primitive groups + granularity/offsets.
// -----------------------------------------------------------------------

/// Node inventory (24 total). Coordinates deliberately clustered near a
/// fake Musterdorf so the header BBox math is trivial to eyeball.
const _fixtureNodes = <_FixtureNode>[
  // Kfz way (Musterstraße, nodes 1..10, running east along lat=52.5)
  _FixtureNode(1, 52.5000, 13.4000),
  _FixtureNode(2, 52.5001, 13.4010),
  _FixtureNode(3, 52.5002, 13.4020),
  _FixtureNode(4, 52.5003, 13.4030),
  _FixtureNode(5, 52.5004, 13.4040),
  _FixtureNode(6, 52.5005, 13.4050),
  _FixtureNode(7, 52.5006, 13.4060),
  _FixtureNode(8, 52.5007, 13.4070),
  _FixtureNode(9, 52.5008, 13.4080),
  _FixtureNode(10, 52.5009, 13.4090),
  // Feldweg (highway=track, nodes 11..14)
  _FixtureNode(11, 52.5100, 13.4100),
  _FixtureNode(12, 52.5101, 13.4110),
  _FixtureNode(13, 52.5102, 13.4120),
  _FixtureNode(14, 52.5103, 13.4130),
  // Admin multipolygon outer ring (nodes 20..25 — a hexagon, closed by
  // referencing node 20 again in way 3)
  _FixtureNode(20, 52.4900, 13.3900),
  _FixtureNode(21, 52.4900, 13.4200),
  _FixtureNode(22, 52.5050, 13.4300),
  _FixtureNode(23, 52.5200, 13.4200),
  _FixtureNode(24, 52.5200, 13.3900),
  _FixtureNode(25, 52.5050, 13.3800),
  // Admin multipolygon inner ring (nodes 40..43 — an enclave rectangle)
  _FixtureNode(40, 52.5040, 13.4020),
  _FixtureNode(41, 52.5040, 13.4080),
  _FixtureNode(42, 52.5070, 13.4080),
  _FixtureNode(43, 52.5070, 13.4020),
];

Uint8List _buildPrimitiveBlock() {
  // ---- 1. Build the string table (index 0 must be empty per PBF spec). ----
  final strings = <String>[
    '', // index 0 — reserved empty string
    'highway',
    'primary',
    'track',
    'name',
    'Musterstraße',
    'boundary',
    'administrative',
    'type',
    'multipolygon',
    'admin_level',
    '8',
    'Testgemeinde',
    'outer',
    'inner',
    'ref',
    'M1',
  ];
  final stringIdx = <String, int>{
    for (var i = 0; i < strings.length; i++) strings[i]: i,
  };

  int s(String key) {
    final v = stringIdx[key];
    if (v == null) {
      throw StateError('String table missing entry: "$key"');
    }
    return v;
  }

  // ---- 2. StringTable protobuf (field 1 of PrimitiveBlock). ----
  final stringTable = ProtoWriter();
  for (final str in strings) {
    stringTable.writeString(1, str); // repeated bytes s
  }
  final stringTableBytes = stringTable.takeBytes();

  // ---- 3. PrimitiveGroup 1: DenseNodes (all 24 nodes). ----
  const granularity = 100; // spec default
  const latOffset = 0;
  const lonOffset = 0;

  final ids = <int>[];
  final lats = <int>[];
  final lons = <int>[];
  var prevId = 0;
  var prevLat = 0;
  var prevLon = 0;
  for (final n in _fixtureNodes) {
    final nanoLat = (n.lat / 1e-9).round(); // WGS84 → nano-degrees
    final nanoLon = (n.lng / 1e-9).round();
    // Reverse the reader's formula: nanoLat = latOffset + granularity * stored
    // => stored = (nanoLat - latOffset) / granularity
    final storedLat = ((nanoLat - latOffset) / granularity).round();
    final storedLon = ((nanoLon - lonOffset) / granularity).round();
    ids.add(n.id - prevId);
    lats.add(storedLat - prevLat);
    lons.add(storedLon - prevLon);
    prevId = n.id;
    prevLat = storedLat;
    prevLon = storedLon;
  }

  final denseBody = ProtoWriter()
    ..writePackedSignedVarints(1, ids) // id[]
    ..writePackedSignedVarints(8, lats) // lat[]
    ..writePackedSignedVarints(9, lons); // lon[]
  // keys_vals omitted — no dense-node tags in this fixture.
  final denseBytes = denseBody.takeBytes();
  final group1 = ProtoWriter()..writeBytes(2, denseBytes); // dense
  final group1Bytes = group1.takeBytes();

  // ---- 4. PrimitiveGroup 2: four Ways. ----
  Uint8List encodeWay({
    required int id,
    required List<int> nodeRefs,
    required List<MapEntry<int, int>> keyVals,
  }) {
    // refs are delta-encoded, packed signed varints.
    final deltas = <int>[];
    var prev = 0;
    for (final ref in nodeRefs) {
      deltas.add(ref - prev);
      prev = ref;
    }
    final w = ProtoWriter()
      ..writeVarint(1, id) // id
      ..writePackedVarints(2, [for (final kv in keyVals) kv.key]) // keys
      ..writePackedVarints(3, [for (final kv in keyVals) kv.value]) // vals
      ..writePackedSignedVarints(8, deltas); // refs
    return w.takeBytes();
  }

  // Way 1: Kfz Musterstraße, highway=primary, name=Musterstraße, ref=M1
  final way1 = encodeWay(
    id: 1,
    nodeRefs: const [1, 2, 3, 4, 5, 6, 7, 8, 9, 10],
    keyVals: [
      MapEntry(s('highway'), s('primary')),
      MapEntry(s('name'), s('Musterstraße')),
      MapEntry(s('ref'), s('M1')),
    ],
  );
  // Way 2: Feldweg, highway=track
  final way2 = encodeWay(
    id: 2,
    nodeRefs: const [11, 12, 13, 14],
    keyVals: [MapEntry(s('highway'), s('track'))],
  );
  // Way 3: admin outer ring, boundary=administrative — closed on node 20
  final way3 = encodeWay(
    id: 3,
    nodeRefs: const [20, 21, 22, 23, 24, 25, 20],
    keyVals: [MapEntry(s('boundary'), s('administrative'))],
  );
  // Way 4: admin inner ring, boundary=administrative — closed on node 40
  final way4 = encodeWay(
    id: 4,
    nodeRefs: const [40, 41, 42, 43, 40],
    keyVals: [MapEntry(s('boundary'), s('administrative'))],
  );

  final group2 = ProtoWriter()
    ..writeBytes(3, way1) // repeated Way
    ..writeBytes(3, way2)
    ..writeBytes(3, way3)
    ..writeBytes(3, way4);
  final group2Bytes = group2.takeBytes();

  // ---- 5. PrimitiveGroup 3: one Relation (multipolygon Testgemeinde). ----
  //   members = [(way 3, outer), (way 4, inner)]
  final relBody = ProtoWriter()
    ..writeVarint(1, 1) // id
    ..writePackedVarints(2, [
      s('type'),
      s('admin_level'),
      s('name'),
      s('boundary'),
    ]) // keys
    ..writePackedVarints(3, [
      s('multipolygon'),
      s('8'),
      s('Testgemeinde'),
      s('administrative'),
    ]) // vals
    ..writePackedVarints(8, [s('outer'), s('inner')]) // roles_sid
    // memids: delta-encoded [3, 1] (way 3, then delta +1 → way 4)
    ..writePackedSignedVarints(9, [3, 1])
    // memtypes: 1 = WAY, 1 = WAY (packed enum varints)
    ..writePackedVarints(10, [1, 1]);
  final relBytes = relBody.takeBytes();

  final group3 = ProtoWriter()..writeBytes(4, relBytes); // repeated Relation
  final group3Bytes = group3.takeBytes();

  // ---- 6. Assemble PrimitiveBlock. ----
  final block = ProtoWriter()
    ..writeBytes(1, stringTableBytes) // stringtable
    ..writeBytes(2, group1Bytes) // primitivegroup (nodes)
    ..writeBytes(2, group2Bytes) // primitivegroup (ways)
    ..writeBytes(2, group3Bytes) // primitivegroup (relations)
    ..writeVarint(17, granularity)
    ..writeVarint(19, lonOffset)
    ..writeVarint(18, latOffset);
  return block.takeBytes();
}

class _FixtureNode {
  const _FixtureNode(this.id, this.lat, this.lng);
  final int id;
  final double lat;
  final double lng;
}
