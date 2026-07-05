/// PBF reader strategy: vendored (hand-coded, zero external protobuf deps).
///
/// Rationale (04-02 Task 1 evaluation): `dart pub search` (via pub.dev API)
/// surfaced exactly one Dart PBF parser — `dart_osmpbf@0.0.1` (published
/// 2024-07-30, uses `very_good_analysis ^6.0.0`). It fails two of the four
/// evaluation criteria set in 04-02:
///   1. Streaming: NO — it materializes the entire PBF into `List<OsmNode>`,
///      `List<OsmWay>`, `List<OsmRelation>` before returning. Full-Germany
///      would blow the 4 GB heap budget instantly (04-RESEARCH §1).
///   2. API surface: throws `Exception('Nodes not supported')` on non-dense
///      nodes and `Exception('Changesets not supported')` — hard-coded
///      limitations we would have to work around.
///
/// It passes the other two criteria (last publish within 24 months;
/// null-safe) but the streaming failure is disqualifying by itself.
///
/// Chosen alternative: vendor a minimal reader inside `lib/pbf/`. The PBF
/// format is stable since 2015, the surface we need is ~600 LOC, and it
/// removes an external protobuf toolchain from our critical path. We also
/// avoid `protoc`/`protobuf` package overhead by hand-decoding the small
/// subset of protobuf wire format we need (varint + length-delimited only).
/// zlib decompression uses `dart:io`'s built-in `ZLibCodec`.
///
/// Layering (each file has one job):
///   * `blob_reader.dart` — reads BlobHeader + Blob, decompresses payload
///   * `block_decoder.dart` — turns a decoded block into `OsmEntity`
///   * `dense_nodes.dart`  — expands the DenseNodes delta-encoded arrays
///   * `entities.dart`     — the `OsmNode` / `OsmWay` / `OsmRelation` model
///   * `pbf_reader.dart`   — the public entrypoint (this file)
library;

import 'dart:io';

import 'package:osm_pipeline/pbf/blob_reader.dart';
import 'package:osm_pipeline/pbf/block_decoder.dart';
import 'package:osm_pipeline/pbf/entities.dart';

/// Streaming reader for OpenStreetMap Protocol Buffer (`.osm.pbf`) files.
///
/// Yields `OsmNode`, `OsmWay`, `OsmRelation` lazily; memory-bounded regardless
/// of PBF size — only one decompressed PrimitiveBlock is held at a time.
///
/// Isolate-portable: no `dart:io` globals, no static mutable state. All
/// per-file state (the parsed OSM header) lives on the instance.
class PbfReader {
  /// Streams every OSM entity in [pbf] as a `Stream<OsmEntity>`.
  ///
  /// The `OSMHeader` block (always the first blob) is captured on [header]
  /// before any entity is yielded so downstream stages can seed the
  /// pipeline's `pbf_date` metadata (04-RESEARCH §9). Unknown blob types
  /// and empty PrimitiveGroups are skipped without failure.
  ///
  /// Errors — malformed BlobHeader, truncated payload, zlib decode failure —
  /// surface as `PipelineParseError` with the source byte offset attached.
  Stream<OsmEntity> stream(File pbf) async* {
    final raf = await pbf.open();
    try {
      while (true) {
        final block = await BlobReader.readNext(raf);
        if (block == null) break;
        switch (block.type) {
          case 'OSMHeader':
            _header = HeaderBlockDecoder.decode(block.bytes);
          case 'OSMData':
            yield* BlockDecoder.decode(block.bytes);
          default:
            // Forward-compat: unknown blob types are ignored per PBF spec.
            continue;
        }
      }
    } finally {
      await raf.close();
    }
  }

  /// Populated after the first `OSMHeader` block is read. Null until then.
  HeaderBlock? get header => _header;
  HeaderBlock? _header;
}
