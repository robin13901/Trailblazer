---
id: 04-02
phase: 04-osm-pipeline
plan: 02
type: execute
wave: 2
depends_on: [04-01]
files_modified:
  - tool/osm_pipeline/pubspec.yaml
  - tool/osm_pipeline/lib/pbf/blob_reader.dart
  - tool/osm_pipeline/lib/pbf/block_decoder.dart
  - tool/osm_pipeline/lib/pbf/dense_nodes.dart
  - tool/osm_pipeline/lib/pbf/pbf_reader.dart
  - tool/osm_pipeline/lib/pbf/entities.dart
  - tool/osm_pipeline/test/pbf/pbf_reader_test.dart
  - tool/osm_pipeline/test/fixtures/tiny.osm.pbf
  - tool/osm_pipeline/test/fixtures/README.md
autonomous: true
requirements: []

must_haves:
  truths:
    - "PbfReader.stream() yields async iterables of OsmNode, OsmWay, OsmRelation with tags — from a real .osm.pbf file"
    - "Reader is streaming: peak heap for the tiny fixture stays under 50 MB (delta over baseline)"
    - "Reader handles both DenseNodes (delta-encoded, packed) and non-dense Node arrays"
    - "Reader skips unknown blob types and empty PrimitiveGroups without crashing"
    - "Malformed blob header or truncated zlib block throws PipelineError with the source byte offset, does not silently swallow"
    - "Tiny hand-crafted fixture PBF (< 10 KB) is committed under test/fixtures/ and covers: 1 Kfz way crossing 1 admin boundary, 1 Feldweg (highway=track), 1 multipolygon admin relation with outer+inner"
  artifacts:
    - path: "tool/osm_pipeline/lib/pbf/pbf_reader.dart"
      provides: "PbfReader class with Stream<OsmEntity> stream(File pbf) — sole entrypoint downstream stages use"
    - path: "tool/osm_pipeline/lib/pbf/entities.dart"
      provides: "OsmNode, OsmWay, OsmRelation sealed class hierarchy with tags map and lat/lng/refs fields"
    - path: "tool/osm_pipeline/test/fixtures/tiny.osm.pbf"
      provides: "Hand-crafted deterministic PBF fixture — < 10 KB — for algorithmic edge-case coverage"
  key_links:
    - from: "tool/osm_pipeline/lib/pbf/pbf_reader.dart"
      to: "tool/osm_pipeline/lib/pbf/blob_reader.dart"
      via: "streaming zlib decode of each blob"
      pattern: "BlobReader"
    - from: "tool/osm_pipeline/lib/pbf/pbf_reader.dart"
      to: "tool/osm_pipeline/lib/pbf/dense_nodes.dart"
      via: "DenseNode delta-decoding helper"
      pattern: "expandDenseNodes"
---

## Goal

Pure-Dart streaming PBF reader that plans 04-03 and 04-04 can consume — yielding tagged `OsmNode`, `OsmWay`, `OsmRelation` entities from any Geofabrik-shaped `.osm.pbf` file, memory-bounded regardless of PBF size.

## Context

- 04-RESEARCH.md §1 chose pure-Dart streaming parse over `osmium`/`imposm3` — no external binary prerequisite on the Windows dev box.
- Evaluate `osm_pbf_parser` on pub.dev first. If maintenance is stale (last publish > 2 years, unresolved analyzer errors, no null-safety), vendor a minimal reader following the [OSM PBF spec](https://wiki.openstreetmap.org/wiki/PBF_Format) — the surface we need is small.
- Fallback exit criterion (04-RESEARCH §1): if the pure-Dart parse cannot process full-Germany PBF in < 2 hours OR exceeds 4 GB heap, escalate to shelling out to `osmium export`. Do NOT attempt this fallback in 04-02 — carry it as a documented risk; 04-10 (full-Germany run) triggers the escalation only if the smoke's actual timings show it.
- The reader is used from the main isolate today. Plan 04-10 may push it into an isolate pool if the full-Germany timing demands it — keep the reader isolate-portable (no dart:io globals, all state instance-local).
- Commit a **hand-crafted tiny fixture PBF**. Full Berlin extract is ~60 MB — too big for git. Fixture must be < 10 KB.

## Tasks

<task type="auto">
  <name>Task 1: Evaluate osm_pbf_parser; pick vendor vs pub.dev</name>
  <files>
    tool/osm_pipeline/pubspec.yaml
    tool/osm_pipeline/lib/pbf/pbf_reader.dart
  </files>
  <intent>Decide the parse strategy before writing production code.</intent>
  <action>
    Run `dart pub search osm_pbf_parser` and inspect the top result. Check:
    - Last publish date (must be within 24 months)
    - Null-safety: yes
    - Analyzer clean under `very_good_analysis`
    - API surface: does it expose a **streaming** interface (async iterator or callback per PrimitiveGroup)? Materializing whole-PBF into memory disqualifies it.

    If it passes all four criteria: add it to `pubspec.yaml` under `dependencies` (alphabetized — `sort_pub_dependencies` applies) and skeleton `pbf_reader.dart` becomes a thin wrapper.

    If it fails ANY criterion: vendor a minimal reader. Add to `dependencies`:
    ```yaml
    archive: ^3.6.0        # for zlib decompression of blob payload
    fixnum: ^1.1.0         # int64 for OSM IDs
    protobuf: ^3.1.0       # protoc-generated OSMPBF messages OR hand-coded varint reader
    ```
    (Alphabetized. If you hand-code varint decoding instead of protoc, drop `protobuf` — still cheaper than the toolchain setup.)

    Record the decision as a doc comment at the top of `pbf_reader.dart`:
    ```
    /// PBF reader strategy: [vendored | osm_pbf_parser@x.y.z]
    /// Rationale: <one paragraph — evaluation criteria hit/miss>
    ```

    **Recommendation from planner:** vendor a minimal reader. The format is stable since 2015; the surface is ~600 LOC; and it removes an external dep from the critical path. But do the survey first — if a well-maintained package exists, use it.
  </action>
  <verify>
    `dart pub search osm_pbf_parser` output captured in a comment or in this plan's execution log.
    Decision recorded at top of `pbf_reader.dart`.
    `dart pub get` succeeds.
  </verify>
</task>

<task type="auto">
  <name>Task 2: Implement streaming PBF reader</name>
  <files>
    tool/osm_pipeline/lib/pbf/blob_reader.dart
    tool/osm_pipeline/lib/pbf/block_decoder.dart
    tool/osm_pipeline/lib/pbf/dense_nodes.dart
    tool/osm_pipeline/lib/pbf/pbf_reader.dart
    tool/osm_pipeline/lib/pbf/entities.dart
  </files>
  <intent>Turn a .osm.pbf file into a Stream of OsmEntity with tags.</intent>
  <action>
    Layer the reader so each file has a single responsibility:

    **`entities.dart`** — data model:
    ```dart
    sealed class OsmEntity {
      int get id;
      Map<String, String> get tags;
    }
    class OsmNode extends OsmEntity {
      final double lat, lng;
      // + id, tags
    }
    class OsmWay extends OsmEntity {
      final List<int> nodeRefs;
      // + id, tags
    }
    class OsmRelation extends OsmEntity {
      final List<RelationMember> members;
      // + id, tags
    }
    class RelationMember {
      final int refId;
      final String type;   // 'node' | 'way' | 'relation'
      final String role;   // 'outer' | 'inner' | 'admin_centre' | ...
    }
    ```

    **`blob_reader.dart`** — reads one blob at a time from a `RandomAccessFile`:
    - Reads 4-byte big-endian BlobHeader length prefix
    - Reads the BlobHeader (protobuf) — extracts `type` ('OSMHeader' or 'OSMData') and `datasize`
    - Reads the Blob payload (`datasize` bytes)
    - If the blob is zlib-compressed (`zlib_data` set), decompresses via `archive` package's ZLibDecoder
    - Emits `RawBlock(type, decompressedBytes)` synchronously per call — caller drives the loop

    **`block_decoder.dart`** — turns a `RawBlock` into `OsmEntity` iterables:
    - Parses PrimitiveBlock (has string_table + primitivegroup[])
    - For each PrimitiveGroup, yields OsmNode/OsmWay/OsmRelation
    - **Skips changesets** (we never need them)
    - **Skips node tags on dense nodes** unless the tag string is non-empty (dense nodes without tags dominate PBF size — 04-RESEARCH §10)

    **`dense_nodes.dart`** — expands DenseNodes:
    - Delta-decode id[], lat[], lng[]
    - Convert to actual doubles using `granularity` (nano-degrees, typically 100) + `lat_offset`/`lon_offset` from the PrimitiveBlock header
    - Walk `keys_vals[]` — a flat array of `key_idx, val_idx, key_idx, val_idx, ..., 0, ...` where `0` terminates each node's tag list (04-RESEARCH §12 pitfall codification)

    **`pbf_reader.dart`** — the public entrypoint:
    ```dart
    class PbfReader {
      Stream<OsmEntity> stream(File pbf) async* {
        final raf = await pbf.open();
        try {
          while (await _hasMore(raf)) {
            final block = await BlobReader.readNext(raf);
            if (block == null) break;
            if (block.type == 'OSMHeader') {
              _header = HeaderBlock.decode(block.bytes);
              continue;
            }
            yield* BlockDecoder.decode(block.bytes);
          }
        } finally {
          await raf.close();
        }
      }

      /// Populated after first OSMHeader is read. Downstream consumers use
      /// this to seed the pipeline's `pbf_date` metadata (04-RESEARCH §9).
      HeaderBlock? get header => _header;
      HeaderBlock? _header;
    }
    ```

    **Error handling** — wrap boundary I/O and decode failures in `PipelineError` (from 04-01) with `cause` set to the underlying `FormatException` / `FileSystemException` and a `sourceOffset` field on the error so downstream logs can point at the bad byte.

    **Memory discipline:**
    - Never hold more than one decompressed PrimitiveBlock in memory at a time.
    - Do NOT convert node tags eagerly for all dense nodes — plan 04-03 will filter ways first; unreferenced node tags never need construction.
    - Do NOT sort or deduplicate — downstream stages own that.

    Windows-specific: use `RandomAccessFile` (works on all platforms) — do not `File.openRead()`-then-chunk, that model breaks on the 4-byte-length + N-byte-payload framing.
  </action>
  <verify>
    `flutter analyze` clean (or only pipeline-scoped warnings, zero errors).
    Manual smoke: `dart run tool/osm_pipeline/bin/smoke_pbf.dart tool/osm_pipeline/test/fixtures/tiny.osm.pbf` prints entity counts (add a tiny throwaway `smoke_pbf.dart` if useful during dev — delete before committing OR keep as a `bin/` diagnostic tool; either fine).
  </verify>
</task>

<task type="auto">
  <name>Task 3: Hand-craft tiny fixture PBF + unit tests</name>
  <files>
    tool/osm_pipeline/test/fixtures/tiny.osm.pbf
    tool/osm_pipeline/test/fixtures/README.md
    tool/osm_pipeline/test/pbf/pbf_reader_test.dart
  </files>
  <intent>Prove the reader works on a deterministic fixture that covers our edge cases without shipping a 60 MB Berlin extract.</intent>
  <action>
    Build the fixture PBF programmatically at first-test setup time (do NOT commit binary blob that anyone might edit — commit the generator).

    Approach: write a small Dart script `tool/osm_pipeline/test/fixtures/build_tiny_pbf.dart` that emits `tiny.osm.pbf` from hand-declared entities:

    Entities (all IDs deliberately small integers for readability):
    - Nodes 1..10 forming a Kfz way (`highway=primary`, `name=Musterstraße`) crossing a fake admin boundary
    - Nodes 11..14 forming a Feldweg (`highway=track`)
    - Nodes 20..30 forming the outer ring of admin_level=8 multipolygon "Testgemeinde"
    - Nodes 40..43 forming the inner ring (an enclave — for the multipolygon-inner test case, 04-RESEARCH §12 pitfall #1)
    - Way 1 refs nodes 1..10, tag `highway=primary`
    - Way 2 refs nodes 11..14, tag `highway=track`
    - Way 3 refs nodes 20..30, tag `boundary=administrative` (outer)
    - Way 4 refs nodes 40..43, tag `boundary=administrative` (inner)
    - Relation 1: `type=multipolygon`, `admin_level=8`, `name=Testgemeinde`, members: way 3 (outer), way 4 (inner)

    Commit both:
    - `test/fixtures/build_tiny_pbf.dart` (the generator)
    - `test/fixtures/tiny.osm.pbf` (the output — < 10 KB, deterministic bytes)
    - `test/fixtures/README.md` documenting: what's in the fixture, how to regenerate (`dart run test/fixtures/build_tiny_pbf.dart`), and that regeneration should be a rare event (any regen makes the byte-level pinning test noisy — pin only entity counts, not byte hashes).

    Write `test/pbf/pbf_reader_test.dart`:

    - `test('reads tiny fixture: 24 nodes, 4 ways, 1 relation', ...)` — asserts counts.
    - `test('way 1 has tag highway=primary and 10 node refs', ...)` — spot-check.
    - `test('relation 1 has 2 members with roles outer, inner', ...)` — multipolygon shape.
    - `test('OSMHeader is parsed and reader.header is non-null after first entity', ...)` — header extraction (for later `pbf_date`).
    - `test('malformed truncated PBF throws PipelineError with sourceOffset', ...)` — corrupt the fixture by truncating; assert failure mode.
    - `test('streaming: consuming 5 entities then breaking closes the file', ...)` — memory/leak discipline (verify with `raf.close()` mock or `dart:io` file-handle count check if trivial; else just document as manual smoke).

    Run: `cd tool/osm_pipeline && dart test`.
  </action>
  <verify>
    `cd tool/osm_pipeline && dart test test/pbf/` — all tests pass.
    `test/fixtures/tiny.osm.pbf` exists and is < 10 KB (`ls -la tool/osm_pipeline/test/fixtures/tiny.osm.pbf`).
    `dart run tool/osm_pipeline/test/fixtures/build_tiny_pbf.dart` regenerates the fixture and produces byte-identical output on a second run (determinism check).
  </verify>
</task>

## Verification

- `cd tool/osm_pipeline && dart test` — green (all args + pbf tests).
- `flutter analyze` at repo root — clean.
- Peak memory during `test/pbf/pbf_reader_test.dart` stays under 50 MB (`--reporter=json` + a simple ProcessInfo.currentRss check is optional; skip if flaky).
- `git ls-files tool/osm_pipeline/test/fixtures/tiny.osm.pbf` — file is tracked.

## Deviation Handling

- If `osm_pbf_parser` on pub.dev is well-maintained AND streams correctly: use it. Vendored reader is the preferred fallback, not the goal.
- If protoc/protobuf toolchain setup is friction: hand-code varint + wire-type decoding in `blob_reader.dart` — the format section we need is ~200 LOC and stable since 2015.
- If the fixture generator produces non-deterministic bytes across runs (protoc string_table ordering can vary), sort string_table entries before emission — determinism is a hard requirement for the byte-count assertion.
- If any test hangs on Windows (`dart test` occasional stalls on file locks), use `--concurrency=1` and open an issue in the executor log — do NOT ship a flaky test.
- Iterate up to 3 times per task; report failing analyzer/test output verbatim if blocked.
