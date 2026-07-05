---
phase: 04-osm-pipeline
plan: 02
subsystem: pipeline-io
tags: [pbf, dart, streaming, protobuf, zlib, fixture-generator, osm]

# Dependency graph
requires:
  - phase: 04-osm-pipeline
    provides: CONTEXT.md pure-Dart preference (single-developer, single-machine dev box)
  - phase: 04-osm-pipeline
    provides: RESEARCH.md §1 (pure-Dart streaming PBF over shell-out to osmium)
  - phase: 04-osm-pipeline
    provides: 04-01 CLI scaffold (PipelineError, path-imported sub-package)
provides:
  - "PbfReader.stream(File) → Stream<OsmEntity> — the sole entrypoint plans 04-03/04-04/04-05 consume"
  - "Sealed OsmEntity hierarchy (OsmNode, OsmWay, OsmRelation) with tags map + RelationMember/OsmMemberType"
  - "HeaderBlock captured on reader.header for later pbf_date metadata (04-RESEARCH §9)"
  - "PipelineParseError with sourceOffset attached — surfaces byte-precise failure diagnostics"
  - "Hand-crafted deterministic tiny.osm.pbf fixture (478 bytes) + build_tiny_pbf.dart generator"
  - "Minimal vendored proto reader/writer (~250 LOC total) — no protobuf/protoc dependency"
affects: [04-03, 04-04, 04-05, 04-06, 04-10, 05-osm-db]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Vendored protobuf wire-format decoder (varint + length-delimited only) — proto_reader.dart"
    - "Layered PBF reader: entities / proto_reader / blob_reader / dense_nodes / block_decoder / pbf_reader"
    - "async* streaming: one PrimitiveBlock decompressed at a time; back-pressure via Stream protocol"
    - "Byte-deterministic fixture generator + on-disk pinning test (dual guard against generator drift)"
    - "PipelineParseError.sourceOffset — byte-precise diagnostic on binary-format failures"

key-files:
  created:
    - "tool/osm_pipeline/lib/pbf/pbf_reader.dart"
    - "tool/osm_pipeline/lib/pbf/entities.dart"
    - "tool/osm_pipeline/lib/pbf/blob_reader.dart"
    - "tool/osm_pipeline/lib/pbf/block_decoder.dart"
    - "tool/osm_pipeline/lib/pbf/dense_nodes.dart"
    - "tool/osm_pipeline/lib/pbf/proto_reader.dart"
    - "tool/osm_pipeline/test/pbf/pbf_reader_test.dart"
    - "tool/osm_pipeline/test/fixtures/build_tiny_pbf.dart"
    - "tool/osm_pipeline/test/fixtures/proto_writer.dart"
    - "tool/osm_pipeline/test/fixtures/tiny.osm.pbf"
    - "tool/osm_pipeline/test/fixtures/README.md"
  modified:
    - "tool/osm_pipeline/lib/cli/errors.dart (added PipelineParseError)"
    - ".gitignore (un-ignore tiny.osm.pbf via ! negation)"
    - ".planning/STATE.md (7 new decision entries under Plan 04-02)"

key-decisions:
  - "Vendored PBF reader (dart_osmpbf@0.0.1 fails streaming criterion — materializes into Lists)"
  - "Zero new pubspec deps: hand-coded varint + length-delimited only; dart:io ZLibCodec for zlib"
  - "PipelineParseError extends sealed PipelineError; sourceOffset: int? for byte-precise diagnostics"
  - "One PrimitiveBlock in memory at a time; dense-node tags built only when keys_vals is non-empty"
  - "Fixture: 478 bytes; generator + bytes both committed; determinism enforced by dual tests"
  - "Reader is isolate-portable — no dart:io globals; plan 04-10 may parallelize without refactor"

patterns-established:
  - "Vendored protobuf subset: `ProtoReader` (varint / signed-varint / length-delimited / packed) + `ProtoWriter` mirror for fixture authoring — no `protobuf` package"
  - "Layered streaming pipeline stage: raw bytes → BlobReader → BlockDecoder (async*) → OsmEntity stream"
  - "Fixture authoring: generator function returns raw bytes; test asserts committed bytes == fresh regeneration"

# Metrics
duration: 20min
completed: 2026-07-05
---

# Phase 4 Plan 02: PBF Streaming Reader + Fixture Summary

**Vendored streaming PBF reader shipped — `PbfReader.stream(File) → Stream<OsmEntity>` yields tagged `OsmNode`/`OsmWay`/`OsmRelation` from any Geofabrik-shaped `.osm.pbf`, memory-bounded via async*; zero protobuf toolchain (hand-coded varint + `dart:io` ZLibCodec); hand-crafted 478-byte deterministic `tiny.osm.pbf` fixture + 9 new tests all green.**

## Performance

- **Duration:** ~20 min
- **Started:** 2026-07-05T17:01:20Z
- **Completed:** 2026-07-05T17:21:02Z
- **Tasks:** 3
- **Files created:** 11 (6 source + 3 test/fixture assets + 1 test file + 1 README)
- **Files modified:** 3 (errors.dart, .gitignore, STATE.md)
- **Tests added:** 9 (all green — 18 sub-package total, up from 9)

## Accomplishments

- Vendored a minimal streaming PBF reader inside `tool/osm_pipeline/lib/pbf/` — no `protobuf` package, no `archive` package, no `dart_osmpbf` dependency. The pub.dev survey found exactly one Dart PBF parser (`dart_osmpbf@0.0.1`, published 2024-07-30). It failed the streaming criterion (materializes into `List<OsmNode>` / `List<OsmWay>` / `List<OsmRelation>`) and hard-throws on non-dense nodes and changesets. Vendoring cost about ~600 LOC and removes an external toolchain dependency from the critical path (04-RESEARCH §1).
- Layered the reader into six files each with a single job: `entities.dart` (sealed `OsmEntity`), `proto_reader.dart` (hand-coded varint / length-delimited / packed decoders), `blob_reader.dart` (BlobHeader + Blob + zlib via `dart:io`'s `ZLibCodec`), `dense_nodes.dart` (delta expander + keys_vals cursor), `block_decoder.dart` (PrimitiveBlock → `Stream<OsmEntity>` via `async*`), and `pbf_reader.dart` (public API with `header` getter for the `OSMHeader` block).
- Added `PipelineParseError` to the sealed `PipelineError` hierarchy from 04-01, carrying an optional `sourceOffset: int?`. Malformed BlobHeader, truncated payload, or zlib decode failure now surfaces with the byte offset of the failing record — the 04-02 must_have "does not silently swallow" is met.
- Memory discipline: only one decompressed PrimitiveBlock is materialised at a time (the `async*` protocol back-pressures on the consumer). Dense-node tags are built only when the `keys_vals[]` array is non-empty. No sorting, dedup, or full-file materialisation anywhere.
- Hand-crafted `test/fixtures/tiny.osm.pbf` (478 bytes — well under the 10 KB budget). Contents: 24 dense nodes, 4 ways (1 Kfz `highway=primary` with `name`/`ref` tags, 1 Feldweg `highway=track`, 1 admin outer hexagon, 1 admin inner rectangle enclave), 1 multipolygon relation `admin_level=8 name=Testgemeinde` with `outer` + `inner` roles. Covers 04-RESEARCH §12 pitfall #1 (multipolygon inner enclave).
- Fixture authored via a companion `test/fixtures/build_tiny_pbf.dart` generator plus a mirror `proto_writer.dart` (~90 LOC — the write side of the varint + length-delimited subset). The generator is exposed as a pure `buildTinyPbfBytes()` function so tests can regenerate in-memory and assert determinism without touching disk.
- Wrote 9 new tests in `test/pbf/pbf_reader_test.dart`: entity-count check (24 / 4 / 1), way spot-check (tags + refs), relation spot-check (outer + inner roles), header capture, lat/lng sanity, truncated-PBF `PipelineParseError` with `sourceOffset`, streaming file-handle discipline (break after 5 → regenerate over the same path), generator determinism across two runs, and on-disk pinning against the fresh generator output.
- `.gitignore` un-ignores the fixture via `!tool/osm_pipeline/test/fixtures/tiny.osm.pbf` after the broad `**/*.osm.pbf` rule — the fixture is a committed binary asset; other `.osm.pbf` files remain gitignored.
- Reader is isolate-portable: no `dart:io` globals, all state instance-local. Plan 04-10 can push into an isolate pool if the full-Germany run demands it without refactoring the reader.
- `dart analyze` inside `tool/osm_pipeline/` clean; `flutter analyze` at repo root clean; `dart test` inside `tool/osm_pipeline/` green (all 18 tests).

## Task Commits

Each task committed atomically; no `git add -A`:

1. **Task 1: Evaluate osm_pbf_parser; pick vendored reader** — `eb76c47` (feat)
   - Skeleton `lib/pbf/pbf_reader.dart` with the vendor-vs-package decision recorded verbatim in the file-level doc comment
2. **Task 2: Implement streaming PBF reader** — `b6abf30` (feat)
   - `lib/pbf/{entities.dart, proto_reader.dart, blob_reader.dart, block_decoder.dart, dense_nodes.dart, pbf_reader.dart}` (6 new files, ~800 LOC)
   - `lib/cli/errors.dart` gains `PipelineParseError` with `sourceOffset`
3. **Task 3: Hand-craft tiny fixture PBF + unit tests** — `abebc90` (test)
   - `test/fixtures/{build_tiny_pbf.dart, proto_writer.dart, README.md, tiny.osm.pbf}`
   - `test/pbf/pbf_reader_test.dart` (9 new tests)
   - `.gitignore` un-ignore for `tiny.osm.pbf`

**Plan metadata commit:** to be created after this summary lands.

## Files Created/Modified

**Created (11):**

- `tool/osm_pipeline/lib/pbf/pbf_reader.dart` — public `PbfReader` class; `stream(File pbf)` async* generator; `header` getter for OSMHeader capture; file-level doc records the vendor decision
- `tool/osm_pipeline/lib/pbf/entities.dart` — sealed `OsmEntity` = `OsmNode` (lat, lng) | `OsmWay` (nodeRefs) | `OsmRelation` (members); `RelationMember` + `OsmMemberType` enum; `HeaderBlock` + `HeaderBoundingBox`
- `tool/osm_pipeline/lib/pbf/proto_reader.dart` — cursor-style protobuf decoder (varint, signed-varint zig-zag, length-delimited, packed varints, packed signed varints, big-endian uint32 for the 4-byte prefix); ~180 LOC
- `tool/osm_pipeline/lib/pbf/blob_reader.dart` — `BlobReader.readNext(RandomAccessFile)`; reads 4-byte BE prefix → BlobHeader → Blob; decompresses `zlib_data` via `dart:io` `ZLibCodec`; hard bounds on header (64 KB) and payload (64 MB); wraps all failures as `PipelineParseError` with the source offset
- `tool/osm_pipeline/lib/pbf/dense_nodes.dart` — `DenseNodesFields.decode` reads the raw fields; `DenseNodesExpander.expand` delta-decodes ids/lat/lon and walks the `keys_vals[]` cursor with `0`-terminated tag lists; empty keys_vals means no dense-node tags (04-RESEARCH §12)
- `tool/osm_pipeline/lib/pbf/block_decoder.dart` — `BlockDecoder.decode(bytes)` async* generator; two-pass PrimitiveBlock decode (string table first, then groups); `_decodeNode` for non-dense nodes; `_decodeWay` with delta-decoded refs; `_decodeRelation` with delta-decoded member ids + zipped roles/types; changesets deliberately skipped; `HeaderBlockDecoder` for the OSMHeader blob
- `tool/osm_pipeline/test/pbf/pbf_reader_test.dart` — 9 new tests (18 sub-package total)
- `tool/osm_pipeline/test/fixtures/build_tiny_pbf.dart` — deterministic fixture generator; also exposes `buildTinyPbfBytes()` for in-memory determinism tests
- `tool/osm_pipeline/test/fixtures/proto_writer.dart` — write-side mirror of `ProtoReader`; `BytesBuilder`-backed; used only by the fixture generator
- `tool/osm_pipeline/test/fixtures/tiny.osm.pbf` — 478-byte committed binary fixture
- `tool/osm_pipeline/test/fixtures/README.md` — inventory + regeneration procedure

**Modified (3):**

- `tool/osm_pipeline/lib/cli/errors.dart` — added `final class PipelineParseError extends PipelineError` with `sourceOffset: int?`; toString appends `[sourceOffset: N]` when present
- `.gitignore` — added `!tool/osm_pipeline/test/fixtures/tiny.osm.pbf` un-ignore after the broad `**/*.osm.pbf` rule
- `.planning/STATE.md` — 7 new decision entries under Plan 04-02 (parse strategy, layering, PipelineParseError, memory discipline, fixture determinism, isolate-portability, inline-ignore doc pattern)

## Decisions Made

See STATE.md "Plan 04-02" decision block (7 entries) for the full rationale. Key highlights:

- **Vendored, not packaged.** `dart_osmpbf@0.0.1` fails the streaming criterion (materializes into Lists) and hard-throws on non-dense nodes / changesets. Vendoring costs ~600 LOC and removes an external toolchain dep from the critical path.
- **Zero new pubspec deps.** Hand-coded protobuf wire-format decoder (varint + length-delimited only). `dart:io`'s built-in `ZLibCodec` handles zlib. No `protobuf`, no `archive`, no `fixnum` — cheaper than the protoc setup.
- **`PipelineParseError` with `sourceOffset`.** Byte-precise diagnostics on binary-format failures; extends the sealed `PipelineError` from 04-01.
- **Streaming discipline.** `async*` back-pressures on the consumer; only one PrimitiveBlock decompressed at a time; dense-node tags built lazily.
- **Isolate-portable reader.** No `dart:io` globals, all state instance-local — plan 04-10 can parallelize without refactor.
- **Deterministic fixture generator + on-disk pinning.** Two-guard system: `test('regeneration is deterministic')` catches generator drift; `test('committed fixture matches fresh regeneration')` catches drift between the generator and the checked-in bytes.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Sealed `PipelineError` prevented cross-file subclasses**

- **Found during:** Task 2 (creating `PipelineParseError` for `BlobReader` failures)
- **Issue:** First attempt put `PipelineParseError` in a new `lib/pbf/pipeline_error.dart` file. Dart refused: subclasses of a `sealed` class must live in the same library. Compile error.
- **Fix:** Moved `PipelineParseError` into the existing `lib/cli/errors.dart` alongside `PipelineArgsError` and `PipelineIoError`. Updated `blob_reader.dart`'s import accordingly. This is the correct design — all `PipelineError` subclasses are boundary types owned by the CLI package, not the pbf/reader package.
- **Files modified:** `tool/osm_pipeline/lib/cli/errors.dart`, `tool/osm_pipeline/lib/pbf/blob_reader.dart`
- **Verification:** `dart analyze` clean; error message referenced by tests appears with `sourceOffset` attached.
- **Committed in:** `b6abf30` (Task 2 commit)

**2. [Rule 2 - Missing Critical] Analyzer info-level lints on new pbf/ files**

- **Found during:** Task 2 (running `dart analyze` inside the sub-package)
- **Issue:** `very_good_analysis` enforces `omit_local_variable_types`, `prefer_constructors_over_static_methods`, and `comment_references` at info level. First pass produced 19 analyzer notices. The pre-push hook runs `flutter analyze --fatal-infos` at the repo root, so info-level issues would block push.
- **Fix:**
  - Ran `dart fix --apply lib/pbf/` — resolved 15 `omit_local_variable_types` findings automatically.
  - Replaced `const ZLibCodec()` with `ZLibCodec()` — the `ZLibCodec` constructor is not const in Dart 3.5+ (`const_with_non_const` error, not just an info).
  - Added a 4-line doc comment + `// ignore: prefer_constructors_over_static_methods` above `DenseNodesFields.decode` — the static-method shape is intentional (iterates the protobuf field stream, may throw).
  - Removed an unused local `ways = <List<int>>[]` scaffold variable in `build_tiny_pbf.dart` left over from an earlier draft.
  - Dropped the `library;` directive at the top of `build_tiny_pbf.dart` (`unnecessary_library_directive` — script file, no library-scope doc comment).
  - Removed the `[id]` doc-reference in `entities.dart` library-level doc (`comment_references` — `id` is a member of the sealed class, not visible from the library-level comment).
  - Added trailing commas in `pbf_reader_test.dart` at two multi-line `expect(...)` call sites.
- **Files modified:** `lib/pbf/blob_reader.dart`, `lib/pbf/block_decoder.dart`, `lib/pbf/dense_nodes.dart`, `lib/pbf/entities.dart`, `test/fixtures/build_tiny_pbf.dart`, `test/pbf/pbf_reader_test.dart`
- **Verification:** `dart analyze` inside `tool/osm_pipeline/` reports "No issues found!"; `flutter analyze` at repo root reports "No issues found!"; pre-push hook expected green.
- **Committed in:** `b6abf30` (Task 2 lints) + `abebc90` (Task 3 test/fixture lints)

**3. [Rule 3 - Blocking] Committed fixture would have been silently gitignored**

- **Found during:** Task 3 (running `git add` on the fixture)
- **Issue:** `.gitignore` from Plan 04-01 had `tool/osm_pipeline/**/*.osm.pbf` to keep large PBF extracts out of the repo. That pattern also matched the intentional 478-byte `tiny.osm.pbf` fixture — git would have silently refused to stage it, and the reader tests would run "green" against a non-existent file on any fresh clone (well, red — `File.exists` would fail in setUpAll).
- **Fix:** Added `!tool/osm_pipeline/test/fixtures/tiny.osm.pbf` immediately below the broad rule. `git check-ignore` confirms the fixture is now tracked; other `.osm.pbf` files remain ignored.
- **Files modified:** `.gitignore`
- **Verification:** `git check-ignore tool/osm_pipeline/test/fixtures/tiny.osm.pbf` exits 1 (not ignored); `git add` staged it successfully.
- **Committed in:** `abebc90` (Task 3 commit)

---

**Total deviations:** 3 auto-fixed (1 blocker for sealed-class layout, 1 missing-critical lint hygiene, 1 blocker for gitignore).
**Impact on plan:** All essential. The sealed-class blocker is a language-level constraint we would have hit regardless. The lint hygiene keeps the pre-push hook green (tiered Ralph-Loop invariant). The gitignore fix prevents a "works locally, breaks on CI" trap. No scope creep, no architectural changes.

## Issues Encountered

- **CRLF line-ending warnings on Windows.** Git reports `LF will be replaced by CRLF the next time Git touches it` for every newly staged text file. Not a bug — Windows checkout with core.autocrlf. Files land with LF in the repo and CRLF in the working tree. No action needed.
- **`dart pub search` subcommand does not exist in Dart 3.12.** Used the pub.dev REST API directly (`curl https://pub.dev/api/search?q=osm_pbf`) instead. Documented the alternative in the vendor-decision doc comment.

## User Setup Required

None — no external service configuration required. The vendored reader has no runtime prerequisites beyond the Dart SDK already installed for the app.

## Next Phase Readiness

**Ready:**

- Plans 04-03 and 04-04 (highway filter + admin-relation extraction) can consume `PbfReader.stream()` directly. The single-entrypoint contract is honored.
- Plan 04-09 (Kfz filter task) can spot-check its output against the tiny fixture's 24-node / 4-way / 1-relation shape.
- Plan 04-05 (segmented intersection) can rely on the outer + inner ring shape captured in the fixture as a smoke-test target for the multipolygon-inner enclave case (04-RESEARCH §12 pitfall #1).
- Plan 04-10 (full-Germany run) can parallelize via isolate pool without touching the reader — no shared mutable state to migrate.

**Blockers / concerns:**

- None new. The vendored reader has not yet been exercised against a real Geofabrik PBF — that shakedown happens in plan 04-03 (highway filter) when the pipeline consumes the reader over Berlin-bbox. If that reveals corner cases (non-standard BlobHeader fields, `lzma_data` payloads, etc.), the fixes land there — the reader is designed to tolerate unknown protobuf fields via the `skipField(wireType)` path.
- WSL2 tippecanoe install (Plan 04-07 concern) unchanged.

---
*Phase: 04-osm-pipeline*
*Completed: 2026-07-05*
