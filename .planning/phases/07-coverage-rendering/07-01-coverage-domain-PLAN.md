---
phase: 07-coverage-rendering
plan: 01
type: execute
wave: 1
depends_on: []
files_modified:
  - lib/features/coverage/domain/coverage_threshold.dart
  - lib/features/coverage/domain/coverage_datum.dart
  - lib/features/coverage/domain/coverage_color_preset.dart
  - test/features/coverage/domain/coverage_threshold_test.dart
  - test/features/coverage/domain/coverage_color_preset_test.dart
autonomous: true

must_haves:
  truths:
    - "A way is classified fully-explored iff union length >= (way length - 15m - 15m), with a proportional fallback for ways <= 30m"
    - "A partial way exposes a coverage fraction in [0,1] and an is_full flag"
    - "There are exactly 5 color presets, one of which is green, each resolving full+partial hex per Brightness"
    - "The default preset is amber (orange), NOT green (REN-01 deviation)"
  artifacts:
    - path: "lib/features/coverage/domain/coverage_threshold.dart"
      provides: "isFullyCovered + coverageFraction pure functions (COV-02/COV-03)"
      contains: "isFullyCovered"
    - path: "lib/features/coverage/domain/coverage_datum.dart"
      provides: "CoverageDatum immutable value (fraction, isFull) per way"
      contains: "class CoverageDatum"
    - path: "lib/features/coverage/domain/coverage_color_preset.dart"
      provides: "CoverageColorPreset enum + CoverageColors + forBrightness"
      contains: "enum CoverageColorPreset"
  key_links:
    - from: "coverage_threshold.dart"
      to: "interval_union.dart"
      via: "reuse drivenLengthMeters for union-length"
      pattern: "drivenLengthMeters"
---

<objective>
Build the pure-Dart coverage domain layer for Phase 7: the fully-explored
threshold (COV-02), the partial-coverage fraction + floor logic (COV-03), the
`CoverageDatum` per-way value object, and the `CoverageColorPreset` palette
(REN-01/REN-06). No I/O, no Riverpod, no MapLibre — this is the isolate-safe
foundation both the geometry/data layer (07-03) and the render layer (07-04)
build on.

Purpose: Locks the coverage math and the 5-preset palette (orange default,
green as one option) in a testable, dependency-free module so downstream
render + settings work has a single source of truth.
Output: 3 domain files + 2 test files, all green under `flutter test`.
</objective>

<execution_context>
@~/.claude/get-shit-done/workflows/execute-plan.md
@~/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@.planning/phases/07-coverage-rendering/07-RESEARCH.md
@.planning/phases/07-coverage-rendering/07-CONTEXT.md

# Reuse these — do NOT reinvent
@lib/features/coverage/domain/interval_union.dart

# Palette + dark-mode strategy is fully specified in RESEARCH §"REN-01" and
# §"Color Preset Architecture" — copy those hex values verbatim.
</context>

<tasks>

<task type="auto">
  <name>Task 1: Coverage threshold + fraction pure functions (COV-02, COV-03)</name>
  <files>lib/features/coverage/domain/coverage_threshold.dart, lib/features/coverage/domain/coverage_datum.dart</files>
  <action>
Create `coverage_datum.dart` with an `@immutable class CoverageDatum` carrying
`final double fraction` (clamped [0,1]) and `final bool isFull`, with `==`,
`hashCode`, `toString`. Add a `const CoverageDatum.undriven()` convenience
(fraction 0, isFull false) if useful.

Create `coverage_threshold.dart` with two pure top-level functions (no I/O):

  bool isFullyCovered(double unionLengthM, double wayLengthM)
    - const kBufferM = 15.0;
    - if wayLengthM <= 30.0: return unionLengthM >= wayLengthM * 0.8;
    - else: return unionLengthM >= (wayLengthM - kBufferM - kBufferM);
    (verbatim from RESEARCH §COV-02)

  CoverageDatum classifyCoverage(double unionLengthM, double wayLengthM)
    - Minimum partial floor: a way shows partial ONLY when
      unionLengthM >= max(50.0, wayLengthM * 0.05) (RESEARCH §REN-03 floor).
      Below the floor -> return CoverageDatum(fraction: 0, isFull: false)
      (treated as undriven for render purposes).
    - fraction = (unionLengthM / wayLengthM).clamp(0.0, 1.0) (guard wayLengthM<=0 -> 0).
    - isFull = isFullyCovered(unionLengthM, wayLengthM).
    - Return CoverageDatum(fraction: fraction, isFull: isFull).

Expose named consts for the floor (kPartialFloorMeters=50.0,
kPartialFloorFraction=0.05) and buffer so 07-04 tuning and tests reference them.
Document that floor/opacity values are tunable against the golden corpus.

Package imports only. `withValues` not relevant here. No Riverpod.
  </action>
  <verify>flutter analyze (clean); functions compile with no lint warnings.</verify>
  <done>isFullyCovered + classifyCoverage exist as pure functions; CoverageDatum is an immutable value with fraction+isFull; floor + buffer are named consts.</done>
</task>

<task type="auto">
  <name>Task 2: CoverageColorPreset palette with per-brightness hex (REN-01/REN-06)</name>
  <files>lib/features/coverage/domain/coverage_color_preset.dart</files>
  <action>
Create `coverage_color_preset.dart`:

  enum CoverageColorPreset { amber, green, blue, purple, red;
    static CoverageColorPreset fromString(String s) => values.firstWhere(
      (e) => e.name == s, orElse: () => CoverageColorPreset.amber); }

  Default = amber (orange) — this is the REN-01 deviation from "warm green".

  @immutable class CoverageColors { const CoverageColors({required this.fullHex,
    required this.partialHex}); final String fullHex; final String partialHex; }

  extension CoverageColorPresetColors on CoverageColorPreset {
    CoverageColors forBrightness(Brightness b) { ... }
  }

Use the EXACT hex pairs from RESEARCH §REN-01 table (light + dark variants):
  amber:  light #FF8C00/#FFCD6B  dark #FFA726/#FFD54F
  green:  light #2ECC71/#A8E6CF  dark #4CAF50/#A5D6A7
  blue:   light #2196F3/#90CAF9  dark #42A5F5/#BBDEFB
  purple: light #9C27B0/#CE93D8  dark #AB47BC/#E1BEE7
  red:    light #E53935/#FFCDD2  dark #EF5350/#FFCDD2

Also expose a human label getter (`String get label`) for the Settings swatches
(e.g. amber -> 'Amber', green -> 'Green', ...). Import `dart:ui` (Brightness) or
`package:flutter/material.dart` for Brightness — prefer `dart:ui` to keep the
domain widget-free. Package imports only.
  </action>
  <verify>flutter analyze clean; enum has 5 values; forBrightness returns distinct hex for light vs dark.</verify>
  <done>CoverageColorPreset has exactly 5 members incl. green; amber is default via fromString fallback; forBrightness(Brightness) returns the correct full/partial hex pair per RESEARCH table.</done>
</task>

<task type="auto">
  <name>Task 3: Unit tests for threshold + palette</name>
  <files>test/features/coverage/domain/coverage_threshold_test.dart, test/features/coverage/domain/coverage_color_preset_test.dart</files>
  <action>
`coverage_threshold_test.dart` — table-driven cases:
  - Long way (1000m), union 970m -> isFull true (>= 1000-30).
  - Long way (1000m), union 969m -> isFull false.
  - Short way (25m), union 20m -> isFull true (>= 25*0.8=20).
  - Short way (25m), union 19m -> isFull false.
  - Floor: 1000m autobahn, union 30m (3%) -> classifyCoverage fraction 0 (below max(50, 50)).
  - Just past floor: 1000m way, union 60m -> fraction ~0.06, isFull false.
  - Half driven: 1000m, union 500m -> fraction 0.5.
  - wayLengthM <= 0 guard -> fraction 0, no throw.

`coverage_color_preset_test.dart`:
  - values.length == 5 and contains CoverageColorPreset.green.
  - fromString('green') == green; fromString('bogus') == amber (default).
  - amber.forBrightness(Brightness.light).fullHex == '#FF8C00';
    amber.forBrightness(Brightness.dark).fullHex == '#FFA726'.
  - every preset returns non-empty 7-char '#RRGGBB' for both brightnesses.

Run `flutter test test/features/coverage/domain/` (this plan touches pure logic
— run tests inline per CLAUDE.md tiered Ralph Loop).
  </action>
  <verify>flutter test test/features/coverage/domain/ passes; flutter analyze clean.</verify>
  <done>All threshold + palette tests green.</done>
</task>

</tasks>

<verification>
- `flutter analyze` clean.
- `flutter test test/features/coverage/domain/` green.
- No new deps added to pubspec.yaml.
</verification>

<success_criteria>
Pure coverage domain (threshold, fraction+floor, CoverageDatum, 5-preset palette
with amber default and green option) exists and is fully unit-tested with zero
external dependencies.
</success_criteria>

<output>
After completion, create `.planning/phases/07-coverage-rendering/07-01-SUMMARY.md`
</output>
