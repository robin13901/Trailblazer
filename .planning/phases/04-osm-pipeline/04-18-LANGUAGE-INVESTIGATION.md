---
id: 04-18-language-investigation
phase: 04-osm-pipeline
plan: 18
date: 2026-07-08
verdict: DEFER (MapTiler free-tier limitation)
---

# Task 4: MapTiler German-label investigation

## TL;DR

**The `?language=` query param has NO server-side effect on the MapTiler
free-tier `dataviz-dark` / `dataviz` / `streets-v2` / `streets-v2-dark`
hosted styles.** These styles hardcode `text-field` expressions to
`{name:en}` or `coalesce(name:en, name)` at the JSON level. The server
returns byte-identical style JSONs whether `&language=de` is present or
absent.

**Root cause:** MapTiler's "language switcher" feature requires a paid
tier (Team / Pro / Enterprise). The free tier serves the vanilla
English-preferred style JSONs.

**Decision:** DEFER per plan §Task 4 outcome (3) and plan §Deviations.
The plan explicitly sanctions this outcome: *"If Task 4's curl reveals
a paid-tier requirement for German labels, document + defer; do NOT
block the phase."*

**Follow-up todo added to STATE.md.** Alternatives when we revisit:
1. Upgrade MapTiler tier (paid) — enables `?language=` server-side.
2. Client-side rewrite: fetch style JSON, rewrite all `text-field`
   expressions to `coalesce(name:de, name)`, serve inline JSON via
   `MapLibreMap.styleString`. ~50 LOC. Cache the rewritten JSON.
3. Switch provider: Protomaps self-hosted styles let us set
   `{name:de}` directly. Bigger change; deferred to Phase 11.
4. Post-load `setLayerProperties` sweep: after style loads, walk
   layers, override each `text-field` via
   `mapController.setLayerProperties(layerId, SymbolLayerProperties(
   textField: ...))`. Fiddly and duplicates state; not recommended.

## Curl reproduction

```bash
KEY="r8gTEWx0iy12Mmmc2Jxs"
curl -s "https://api.maptiler.com/maps/dataviz-dark/style.json?key=$KEY&language=de" -o C:/tmp/dataviz_de.json
curl -s "https://api.maptiler.com/maps/dataviz-dark/style.json?key=$KEY" -o C:/tmp/dataviz_nolang.json
diff -q C:/tmp/dataviz_de.json C:/tmp/dataviz_nolang.json
# no output — files are byte-identical
```

Both files: 24 659 bytes exact.

## Text-field expressions (dataviz-dark, `&language=de`)

Extracted programmatically via Python (`json.load` + walk layers):

```
"{name:en}"
  used by: Ocean labels, City labels, Country labels, Continent labels (4)

["coalesce", ["get", "name:en"], ["get", "name"]]
  used by: Sea labels, Lakeline labels, Road labels, Town labels, State labels (5)

"{name}"
  used by: Place labels, Village labels (2)
```

Cross-checked `streets-v2` (7 layers use `coalesce(name:en, name)`,
5 layers use `{name:en}`, 12 layers use `{name}`, others use
`{ref}` / `{housenumber}`). Same pattern — English-first coalesce.

**No layer uses `{name:de}` or a `?language`-templated field.** The
`?language=de` query param has no server-side effect on the hosted
`style.json`.

## What this means for behaviour

- **Cities / countries / continents** (top-priority labels at low zoom):
  `text-field: "{name:en}"` — hardcoded English, always. "Germany"
  never becomes "Deutschland" without a client-side rewrite.
- **Sea / lake / road / town / state labels**:
  `coalesce(name:en, name)` — prefer English, fall back to native.
  If the underlying OSM feature has `name:en=Munich` AND `name=München`,
  MapTiler returns "Munich".
- **Place / village labels**: `{name}` — always native. This IS German
  where OSM has `name=` populated in German (which for German villages
  is the vast majority of the time). So village names DID render in
  German on the drive — the user just saw the mostly-English higher-
  priority labels.

## Verified fix path (for future re-adoption)

Option 2 (client-side rewrite) sketch:

```dart
// pseudocode
final rawJson = await http.get(config.styleUrl(...));
final style = jsonDecode(rawJson.body) as Map<String, dynamic>;
for (final layer in style['layers'] as List) {
  final layout = layer['layout'] as Map<String, dynamic>?;
  if (layout?.containsKey('text-field') ?? false) {
    layout!['text-field'] = ['coalesce', ['get', 'name:de'], ['get', 'name']];
  }
}
// pass inline JSON string to MapLibreMap.styleString
```

This works — MapLibreMap.styleString accepts either a URL or an inline
JSON string. Sprite + glyph fetches continue to hit the MapTiler CDN
(remain functional; only the `text-field` layout property changes).

Estimated size of the rewritten style JSON: ~24 KB. Small enough to
inline every time; no need to cache.

## Code changes made in this plan

None to the app code path. The existing `TileProviderConfig.language`
field (added in 04-16-1) and the `&language=` URL param remain — they
are dormant infrastructure ready for the day MapTiler enables
`?language=` on the free tier, or for the day we switch to a paid
tier.

Added a `TODO(04-18)` in `tile_provider_config.dart` above the
`&language=` URL construction so the next developer to touch this
file discovers the deferral rationale immediately.

## STATE.md follow-up entry

To be added in the continuation run's metadata commit:

> **Phase 4 (04-18 follow-up):** MapTiler free-tier hosted styles
> hardcode `{name:en}` / `coalesce(name:en, name)` in `text-field`
> layout properties; `?language=de` has NO server-side effect. Curl
> proof + rewrite sketch in `04-18-LANGUAGE-INVESTIGATION.md`. To
> restore German labels, either upgrade MapTiler tier OR add a
> client-side style-JSON rewrite (~50 LOC). Deferred to Phase 11 or
> the next time UX prioritizes it.
