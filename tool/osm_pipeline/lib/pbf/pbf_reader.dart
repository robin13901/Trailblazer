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
/// Task 2 fills in the layered implementation:
///   * `blob_reader.dart` — reads BlobHeader + Blob, decompresses payload
///   * `block_decoder.dart` — turns a decoded block into `OsmEntity`
///   * `dense_nodes.dart`  — expands the DenseNodes delta-encoded arrays
///   * `entities.dart`     — the `OsmNode` / `OsmWay` / `OsmRelation` model
///   * `pbf_reader.dart`   — the public entrypoint (this file)
library;

/// Streaming reader for OpenStreetMap Protocol Buffer (`.osm.pbf`) files.
///
/// Task 2 fleshes out `stream(File pbf)`; today this class exists only to
/// pin the vendor-vs-package decision (see the file-level doc comment).
class PbfReader {
  // Task 2 fills this in.
}
