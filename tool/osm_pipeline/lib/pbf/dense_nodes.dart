import 'dart:convert';

import 'package:osm_pipeline/pbf/entities.dart';
import 'package:osm_pipeline/pbf/proto_reader.dart';

/// Expands a `DenseNodes` message into a plain `List<OsmNode>`.
///
/// See the PBF spec at https://wiki.openstreetmap.org/wiki/PBF_Format —
/// section "Ways and Relations", subsection "DenseNodes".
///
/// The `id[]`, `lat[]`, `lon[]` arrays are delta-encoded (each element is
/// added to the running sum of prior elements). Actual doubles are computed
/// as `1e-9 * (offset + granularity * decoded_int)`.
///
/// The `keys_vals[]` array is a flat interleaved list of
///   `key_idx_1, val_idx_1, key_idx_2, val_idx_2, ..., 0,
///    key_idx_1', val_idx_1', ..., 0, ...`
/// where `0` terminates each node's tag list. If `keys_vals[]` is empty,
/// no dense nodes have tags — the whole array is omitted (04-RESEARCH §12
/// pitfall codification).
abstract final class DenseNodesExpander {
  /// Expand [dense] into a `List<OsmNode>` using the [stringTable] and the
  /// `PrimitiveBlock` coordinate parameters ([granularity], [latOffset],
  /// [lonOffset]).
  static List<OsmNode> expand({
    required DenseNodesFields dense,
    required List<String> stringTable,
    required int granularity,
    required int latOffset,
    required int lonOffset,
  }) {
    final n = dense.ids.length;
    if (n == 0) return const [];
    if (dense.lats.length != n || dense.lons.length != n) {
      throw FormatException(
        'DenseNodes arity mismatch: ids=$n lats=${dense.lats.length} '
        'lons=${dense.lons.length}',
      );
    }

    final out = <OsmNode>[];
    var idRunning = 0;
    var latRunning = 0;
    var lonRunning = 0;

    // keys_vals cursor — advanced independently as we consume tags per node.
    final kv = dense.keysVals;
    var kvCursor = 0;

    for (var i = 0; i < n; i++) {
      idRunning += dense.ids[i];
      latRunning += dense.lats[i];
      lonRunning += dense.lons[i];

      var tags = const <String, String>{};
      if (kv.isNotEmpty && kvCursor < kv.length) {
        Map<String, String>? tagMap;
        while (kvCursor < kv.length && kv[kvCursor] != 0) {
          if (kvCursor + 1 >= kv.length) {
            throw const FormatException(
              'DenseNodes keys_vals: dangling key without a value',
            );
          }
          final k = kv[kvCursor];
          final v = kv[kvCursor + 1];
          kvCursor += 2;
          if (k < 0 || k >= stringTable.length ||
              v < 0 || v >= stringTable.length) {
            throw FormatException(
              'DenseNodes keys_vals: string-table index out of range '
              '(k=$k v=$v table_size=${stringTable.length})',
            );
          }
          (tagMap ??= <String, String>{})[stringTable[k]] = stringTable[v];
        }
        // Skip terminator 0. Not present means this was the last node's
        // tag block and the array ends without a trailing 0 — tolerate.
        if (kvCursor < kv.length && kv[kvCursor] == 0) kvCursor++;
        if (tagMap != null) tags = tagMap;
      }

      out.add(
        OsmNode(
          id: idRunning,
          tags: tags,
          lat: 1e-9 * (latOffset + granularity * latRunning),
          lng: 1e-9 * (lonOffset + granularity * lonRunning),
        ),
      );
    }
    return out;
  }
}

/// Raw field values decoded from a `DenseNodes` protobuf message.
///
/// Kept as a plain data holder so `DenseNodesExpander.expand` is a pure
/// function over (fields, string table, block coord params).
class DenseNodesFields {
  /// Create a raw dense-nodes bundle.
  const DenseNodesFields({
    required this.ids,
    required this.lats,
    required this.lons,
    required this.keysVals,
  });

  /// Decode a `DenseNodes` message body starting at [r]'s current position.
  ///
  /// Construction is non-trivial (iterates the protobuf field stream) and
  /// may throw, so this stays a static method not a factory constructor.
  // ignore: prefer_constructors_over_static_methods
  static DenseNodesFields decode(ProtoReader r) {
    var ids = const <int>[];
    var lats = const <int>[];
    var lons = const <int>[];
    var keysVals = const <int>[];
    while (true) {
      final tag = r.readTag();
      if (tag == null) break;
      switch (tag.fieldNumber) {
        case 1: // repeated sint64 id (packed, zig-zag)
          ids = r.readPackedSignedVarints();
        case 5: // optional DenseInfo — skip
          r.skipField(tag.wireType);
        case 8: // repeated sint64 lat (packed, zig-zag)
          lats = r.readPackedSignedVarints();
        case 9: // repeated sint64 lon (packed, zig-zag)
          lons = r.readPackedSignedVarints();
        case 10: // repeated int32 keys_vals (packed, unsigned)
          keysVals = r.readPackedVarints();
        default:
          r.skipField(tag.wireType);
      }
    }
    return DenseNodesFields(
      ids: ids,
      lats: lats,
      lons: lons,
      keysVals: keysVals,
    );
  }

  /// Delta-encoded node ids.
  final List<int> ids;

  /// Delta-encoded node latitudes (raw nano-degree deltas before scaling).
  final List<int> lats;

  /// Delta-encoded node longitudes (raw nano-degree deltas before scaling).
  final List<int> lons;

  /// Flat interleaved `key_idx, val_idx, ..., 0` per node — may be empty.
  final List<int> keysVals;
}

/// Convenience alias for utf8 decode of string-table entries. Kept here so
/// callers of `DenseNodesExpander` can build a String-table from the raw
/// PrimitiveBlock protobuf without importing `dart:convert` themselves.
String decodeStringTableEntry(List<int> bytes) => utf8.decode(bytes);
