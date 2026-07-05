import 'dart:convert';
import 'dart:typed_data';

import 'package:osm_pipeline/pbf/dense_nodes.dart';
import 'package:osm_pipeline/pbf/entities.dart';
import 'package:osm_pipeline/pbf/proto_reader.dart';

/// Decodes a `PrimitiveBlock` (from an `OSMData` blob) into a lazy stream of
/// `OsmEntity` values.
///
/// PBF PrimitiveBlock shape:
///   1  StringTable stringtable
///   2  repeated PrimitiveGroup primitivegroup
///   17 optional int32 granularity          (default 100, nano-degrees)
///   18 optional int64 lat_offset           (default 0)
///   19 optional int64 lon_offset           (default 0)
///   20 optional int32 date_granularity     (unused here)
///
/// Each PrimitiveGroup carries one of: dense, nodes, ways, relations,
/// changesets. Changesets are always skipped.
abstract final class BlockDecoder {
  /// Turns [bytes] (a decompressed PrimitiveBlock) into a stream of entities.
  ///
  /// Skips changesets and empty groups. Unknown fields are ignored per
  /// protobuf forward-compat rules.
  static Stream<OsmEntity> decode(Uint8List bytes) async* {
    // First pass: read the block header + string table before we can decode
    // groups (groups reference string-table indices).
    final r = ProtoReader(bytes);
    var stringTable = const <String>[];
    final groupPayloads = <Uint8List>[];
    var granularity = 100;
    var latOffset = 0;
    var lonOffset = 0;
    while (true) {
      final tag = r.readTag();
      if (tag == null) break;
      switch (tag.fieldNumber) {
        case 1: // StringTable
          stringTable = _decodeStringTable(r.readLengthDelimited());
        case 2: // PrimitiveGroup — stash the raw payload for the second pass
          groupPayloads.add(r.readLengthDelimited());
        case 17: // granularity
          granularity = r.readVarint();
        case 19: // lon_offset
          lonOffset = r.readVarint();
        case 18: // lat_offset
          latOffset = r.readVarint();
        default:
          r.skipField(tag.wireType);
      }
    }

    // Second pass: decode each group in order. Yields lazily so downstream
    // consumers can back-pressure via the async* protocol.
    for (final payload in groupPayloads) {
      yield* _decodeGroup(
        payload,
        stringTable: stringTable,
        granularity: granularity,
        latOffset: latOffset,
        lonOffset: lonOffset,
      );
    }
  }

  static Stream<OsmEntity> _decodeGroup(
    Uint8List payload, {
    required List<String> stringTable,
    required int granularity,
    required int latOffset,
    required int lonOffset,
  }) async* {
    final r = ProtoReader(payload);
    while (true) {
      final tag = r.readTag();
      if (tag == null) break;
      switch (tag.fieldNumber) {
        case 1: // repeated Node — non-dense
          final nodeBytes = r.readLengthDelimited();
          yield _decodeNode(
            nodeBytes,
            stringTable: stringTable,
            granularity: granularity,
            latOffset: latOffset,
            lonOffset: lonOffset,
          );
        case 2: // optional DenseNodes
          final dense = DenseNodesFields.decode(
            ProtoReader(r.readLengthDelimited()),
          );
          final nodes = DenseNodesExpander.expand(
            dense: dense,
            stringTable: stringTable,
            granularity: granularity,
            latOffset: latOffset,
            lonOffset: lonOffset,
          );
          for (final n in nodes) {
            yield n;
          }
        case 3: // repeated Way
          yield _decodeWay(
            r.readLengthDelimited(),
            stringTable: stringTable,
          );
        case 4: // repeated Relation
          yield _decodeRelation(
            r.readLengthDelimited(),
            stringTable: stringTable,
          );
        case 5: // repeated ChangeSet — deliberately skipped
          r.skipField(tag.wireType);
        default:
          r.skipField(tag.wireType);
      }
    }
  }

  static OsmNode _decodeNode(
    Uint8List bytes, {
    required List<String> stringTable,
    required int granularity,
    required int latOffset,
    required int lonOffset,
  }) {
    final r = ProtoReader(bytes);
    var id = 0;
    var lat = 0;
    var lon = 0;
    var keys = const <int>[];
    var vals = const <int>[];
    while (true) {
      final tag = r.readTag();
      if (tag == null) break;
      switch (tag.fieldNumber) {
        case 1: // required sint64 id
          id = r.readSignedVarint();
        case 2: // repeated uint32 keys (packed)
          keys = r.readPackedVarints();
        case 3: // repeated uint32 vals (packed)
          vals = r.readPackedVarints();
        case 8: // required sint64 lat
          lat = r.readSignedVarint();
        case 9: // required sint64 lon
          lon = r.readSignedVarint();
        default:
          r.skipField(tag.wireType);
      }
    }
    return OsmNode(
      id: id,
      tags: _resolveTags(keys, vals, stringTable),
      lat: 1e-9 * (latOffset + granularity * lat),
      lng: 1e-9 * (lonOffset + granularity * lon),
    );
  }

  static OsmWay _decodeWay(
    Uint8List bytes, {
    required List<String> stringTable,
  }) {
    final r = ProtoReader(bytes);
    var id = 0;
    var keys = const <int>[];
    var vals = const <int>[];
    var refs = const <int>[];
    while (true) {
      final tag = r.readTag();
      if (tag == null) break;
      switch (tag.fieldNumber) {
        case 1: // required int64 id
          id = r.readVarint();
        case 2: // repeated uint32 keys (packed)
          keys = r.readPackedVarints();
        case 3: // repeated uint32 vals (packed)
          vals = r.readPackedVarints();
        case 8: // repeated sint64 refs (packed, zig-zag, delta-encoded)
          refs = r.readPackedSignedVarints();
        default:
          r.skipField(tag.wireType);
      }
    }
    // Delta-decode refs.
    var running = 0;
    final decodedRefs = List<int>.filled(refs.length, 0);
    for (var i = 0; i < refs.length; i++) {
      running += refs[i];
      decodedRefs[i] = running;
    }
    return OsmWay(
      id: id,
      tags: _resolveTags(keys, vals, stringTable),
      nodeRefs: decodedRefs,
    );
  }

  static OsmRelation _decodeRelation(
    Uint8List bytes, {
    required List<String> stringTable,
  }) {
    final r = ProtoReader(bytes);
    var id = 0;
    var keys = const <int>[];
    var vals = const <int>[];
    var rolesSid = const <int>[];
    var memIds = const <int>[];
    var memTypes = const <int>[];
    while (true) {
      final tag = r.readTag();
      if (tag == null) break;
      switch (tag.fieldNumber) {
        case 1: // required int64 id
          id = r.readVarint();
        case 2: // repeated uint32 keys
          keys = r.readPackedVarints();
        case 3: // repeated uint32 vals
          vals = r.readPackedVarints();
        case 8: // repeated int32 roles_sid (packed)
          rolesSid = r.readPackedVarints();
        case 9: // repeated sint64 memids (packed, delta)
          memIds = r.readPackedSignedVarints();
        case 10: // repeated MemberType memtypes (packed enum)
          memTypes = r.readPackedVarints();
        default:
          r.skipField(tag.wireType);
      }
    }
    // Delta-decode member ids; zip with types + roles.
    final members = <RelationMember>[];
    var running = 0;
    for (var i = 0; i < memIds.length; i++) {
      running += memIds[i];
      final type = _memberType(i < memTypes.length ? memTypes[i] : 0);
      final roleIdx = i < rolesSid.length ? rolesSid[i] : 0;
      final role = roleIdx >= 0 && roleIdx < stringTable.length
          ? stringTable[roleIdx]
          : '';
      members.add(
        RelationMember(refId: running, type: type, role: role),
      );
    }
    return OsmRelation(
      id: id,
      tags: _resolveTags(keys, vals, stringTable),
      members: members,
    );
  }

  static OsmMemberType _memberType(int raw) {
    // Values per PBF spec `Relation.MemberType`:
    //   0 = NODE, 1 = WAY, 2 = RELATION.
    switch (raw) {
      case 1:
        return OsmMemberType.way;
      case 2:
        return OsmMemberType.relation;
      case 0:
      default:
        return OsmMemberType.node;
    }
  }

  static Map<String, String> _resolveTags(
    List<int> keys,
    List<int> vals,
    List<String> stringTable,
  ) {
    if (keys.isEmpty) return const {};
    if (keys.length != vals.length) {
      throw FormatException(
        'Tag key/val length mismatch: keys=${keys.length} vals=${vals.length}',
      );
    }
    final tags = <String, String>{};
    for (var i = 0; i < keys.length; i++) {
      final k = keys[i];
      final v = vals[i];
      if (k < 0 || k >= stringTable.length ||
          v < 0 || v >= stringTable.length) {
        throw FormatException(
          'Tag string-table index out of range (k=$k v=$v '
          'table_size=${stringTable.length})',
        );
      }
      tags[stringTable[k]] = stringTable[v];
    }
    return tags;
  }

  static List<String> _decodeStringTable(Uint8List bytes) {
    final r = ProtoReader(bytes);
    final out = <String>[];
    while (true) {
      final tag = r.readTag();
      if (tag == null) break;
      if (tag.fieldNumber == 1) {
        out.add(utf8.decode(r.readLengthDelimited()));
      } else {
        r.skipField(tag.wireType);
      }
    }
    return out;
  }
}

/// Decodes an `OSMHeader` blob into a [HeaderBlock].
abstract final class HeaderBlockDecoder {
  /// Decode a decompressed `OSMHeader` payload.
  static HeaderBlock decode(Uint8List bytes) {
    final r = ProtoReader(bytes);
    HeaderBoundingBox? bbox;
    final required = <String>[];
    final optional = <String>[];
    String? writingProgram;
    String? source;
    int? osmosisReplTs;
    while (true) {
      final tag = r.readTag();
      if (tag == null) break;
      switch (tag.fieldNumber) {
        case 1: // optional HeaderBBox
          bbox = _decodeHeaderBBox(r.readLengthDelimited());
        case 4: // repeated string required_features
          required.add(utf8.decode(r.readLengthDelimited()));
        case 5: // repeated string optional_features
          optional.add(utf8.decode(r.readLengthDelimited()));
        case 16: // optional string writingprogram
          writingProgram = utf8.decode(r.readLengthDelimited());
        case 17: // optional string source
          source = utf8.decode(r.readLengthDelimited());
        case 32: // optional int64 osmosis_replication_timestamp
          osmosisReplTs = r.readVarint();
        default:
          r.skipField(tag.wireType);
      }
    }
    return HeaderBlock(
      requiredFeatures: required,
      optionalFeatures: optional,
      bbox: bbox,
      writingProgram: writingProgram,
      source: source,
      osmosisReplicationTimestamp: osmosisReplTs,
    );
  }

  static HeaderBoundingBox _decodeHeaderBBox(Uint8List bytes) {
    final r = ProtoReader(bytes);
    var left = 0;
    var right = 0;
    var top = 0;
    var bottom = 0;
    while (true) {
      final tag = r.readTag();
      if (tag == null) break;
      switch (tag.fieldNumber) {
        case 1: // required sint64 left  (nano-degrees)
          left = r.readSignedVarint();
        case 2: // required sint64 right
          right = r.readSignedVarint();
        case 3: // required sint64 top
          top = r.readSignedVarint();
        case 4: // required sint64 bottom
          bottom = r.readSignedVarint();
        default:
          r.skipField(tag.wireType);
      }
    }
    return HeaderBoundingBox(
      left: 1e-9 * left,
      right: 1e-9 * right,
      top: 1e-9 * top,
      bottom: 1e-9 * bottom,
    );
  }
}
