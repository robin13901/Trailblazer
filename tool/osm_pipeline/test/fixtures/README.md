# Test fixtures — `tiny.osm.pbf`

Hand-crafted deterministic `.osm.pbf` used by `test/pbf/pbf_reader_test.dart`.

## Contents

24 nodes, 4 ways, 1 relation:

| Entity        | id  | Highlights                                        |
| ------------- | --- | ------------------------------------------------- |
| Nodes 1–10    |     | Musterstraße (Kfz way body, ~52.50 N / 13.40 E)   |
| Nodes 11–14   |     | Feldweg (`highway=track` body)                    |
| Nodes 20–25   |     | Admin multipolygon outer ring (hexagon)           |
| Nodes 40–43   |     | Admin multipolygon inner ring (rectangle enclave) |
| Way 1         | 1   | `highway=primary`, `name=Musterstraße`, `ref=M1`  |
| Way 2         | 2   | `highway=track`                                   |
| Way 3         | 3   | `boundary=administrative`, closed hexagon outer   |
| Way 4         | 4   | `boundary=administrative`, closed rectangle inner |
| Relation 1    | 1   | `type=multipolygon`, `admin_level=8`, `name=Testgemeinde`, members `[way 3 (outer), way 4 (inner)]` |

The fixture covers the algorithmic edge cases called out by 04-RESEARCH §12:
- Multipolygon with inner enclave
- Streaming reader must handle DenseNodes (all 24 nodes are dense)
- Tag-carrying ways + tag-carrying relation

## Regenerating

The fixture is committed as bytes and also as a Dart generator. Regenerate
with:

```bash
cd tool/osm_pipeline
dart run test/fixtures/build_tiny_pbf.dart
```

Regeneration should be **rare** — the tests pin entity counts and specific
tag values, not byte hashes. The one exception is
`test('committed fixture bytes match a fresh regeneration')`, which asserts
that the checked-in bytes still match a fresh generator run. If you change
the generator, re-run the command above to refresh `tiny.osm.pbf`.

## Size

Current: 478 bytes (well under the 10 KB budget in 04-02 must_haves).
