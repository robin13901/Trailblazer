---
plan: "07-01"
phase: "07-coverage-rendering"
subsystem: "coverage-domain"
tags: ["coverage", "domain", "pure-dart", "colorimetry", "threshold"]
status: "complete"
completed: "2026-07-10"
duration: "7 min"

dependency-graph:
  requires:
    - "lib/features/coverage/domain/interval_union.dart (phase 6)"
    - "package:meta/meta.dart"
    - "dart:ui (Brightness)"
  provides:
    - "isFullyCovered() — COV-02 threshold function"
    - "classifyCoverage() — COV-03 fraction + floor"
    - "CoverageDatum — immutable per-way value object"
    - "CoverageColorPreset enum — 5 presets, amber default"
    - "CoverageColors — fullHex/partialHex value pair"
    - "forBrightness() extension — verbatim RESEARCH §REN-01 hex"
  affects:
    - "07-03 coverage geometry + data layer (consumes CoverageDatum, classifyCoverage)"
    - "07-04 coverage render layer (consumes CoverageColorPreset, forBrightness)"
    - "07-05 settings preset picker (consumes CoverageColorPreset.label, fromString)"

tech-stack:
  added: []
  patterns:
    - "Pure top-level functions for isolate-safe domain math"
    - "@immutable value objects with ==, hashCode, toString"
    - "Dart enum + extension for preset/color table"
    - "dart:ui Brightness (widget-free domain)"

key-files:
  created:
    - "lib/features/coverage/domain/coverage_datum.dart"
    - "lib/features/coverage/domain/coverage_threshold.dart"
    - "lib/features/coverage/domain/coverage_color_preset.dart"
    - "test/features/coverage/domain/coverage_threshold_test.dart"
    - "test/features/coverage/domain/coverage_color_preset_test.dart"
  modified: []

decisions:
  - id: "COV-02-buffer"
    summary: "15 m end-buffer threshold; 80 % fallback for ways ≤ 30 m"
    rationale: "GPS drift window at each node; proportional fallback prevents tiny stubs from never reaching full"
  - id: "COV-03-floor"
    summary: "Partial floor = max(50 m, 5 % of way length)"
    rationale: "Suppresses stray single-clip GPS hits on long roads; tune against golden corpus"
  - id: "REN-01-amber-default"
    summary: "Default preset is amber (#FF8C00 light / #FFA726 dark), not green"
    rationale: "Maximum pop over both MapTiler dataviz light and dark base maps; green is still a preset"
  - id: "domain-widget-free"
    summary: "Import dart:ui (not package:flutter/material.dart) for Brightness"
    rationale: "Keeps domain layer isolate-safe and widget-free; dart:ui is available in all Dart contexts"
---

# Phase 7 Plan 01: Coverage Domain Summary

**One-liner:** Isolate-safe coverage domain — COV-02/COV-03 threshold math + CoverageDatum value object + 5-preset CoverageColorPreset palette (amber default) with verbatim RESEARCH §REN-01 hex pairs, 63 unit tests green.

## What Was Built

Three pure-Dart domain files with no I/O, no Riverpod, no generated code — the foundation for the Phase 7 render and settings layers.

### coverage_datum.dart

`@immutable class CoverageDatum` carrying `fraction` (double [0,1]) and `isFull` (bool), with value equality, `hashCode`, `toString`. `const CoverageDatum.undriven()` convenience constructor for below-floor and undriven ways.

### coverage_threshold.dart

Two pure top-level functions:

- `isFullyCovered(unionLengthM, wayLengthM)` — COV-02. Ways > 30 m: threshold = wayLength − 30 m (15 m buffer × 2). Ways ≤ 30 m: threshold = wayLength × 0.8 (proportional fallback).
- `classifyCoverage(unionLengthM, wayLengthM)` — COV-03. Partial floor = max(kPartialFloorMeters=50, wayLength × kPartialFloorFraction=0.05). Below floor returns `CoverageDatum.undriven()`. Above floor: fraction clamped [0,1], isFull from `isFullyCovered`.

Named consts: `kCoverageBufferMeters`, `kPartialFloorMeters`, `kPartialFloorFraction` — tunable against golden corpus in 07-04.

### coverage_color_preset.dart

`enum CoverageColorPreset { amber, green, blue, purple, red }` with `fromString(String)` falling back to `amber`. `@immutable class CoverageColors { fullHex, partialHex }`. Extension `forBrightness(Brightness)` returning RESEARCH §REN-01 hex pairs verbatim for both light and dark modes. `label` getter for Settings swatches. Uses `dart:ui` for `Brightness` — no Flutter widget import.

## Decisions Made

| Decision | Choice | Rationale |
|----------|--------|-----------|
| COV-02 buffer | 15 m × 2 end-buffer; 80 % fallback for ≤ 30 m | GPS drift window; proportional fallback for short stubs |
| COV-03 partial floor | max(50 m, 5 % of way length) | Suppresses stray GPS clips on long roads |
| REN-01 default color | Amber (#FF8C00 light) | Max contrast over both dataviz light/dark; green retained as preset |
| Brightness source | dart:ui (not flutter/material) | Isolate-safe, widget-free domain layer |

## Test Coverage

63 tests across two files:

- **coverage_threshold_test.dart** — 6 `isFullyCovered` cases (long/short/boundary), 8 `classifyCoverage` cases (floor, just-past-floor, half, full, guard, clamp), 4 `CoverageDatum` value-object cases.
- **coverage_color_preset_test.dart** — 5-value count, green presence, `fromString` fallback, amber light/dark hex verbatim, all-preset hex format validation (7-char `#RRGGBB`), `CoverageColors` value equality.

All 63 tests pass. `flutter analyze` clean.

## Deviations from Plan

None — plan executed exactly as written. Minor lint fixes applied during Ralph Loop iterations:
- Replaced `[isFullyCovered]` doc comment reference with backtick syntax (comment_references info).
- Replaced `15.0`/`50.0` with `15`/`50` in `const double` declarations (prefer_int_literals info).
- Same fix in test file for `1.0` argument.

## Next Phase Readiness

Plans 07-03 (geometry + data layer) and 07-04 (render layer) can proceed immediately:
- Import `classifyCoverage` and `CoverageDatum` from `coverage_threshold.dart`.
- Import `CoverageColorPreset` and `forBrightness` from `coverage_color_preset.dart`.
- Named consts `kCoverageBufferMeters`, `kPartialFloorMeters`, `kPartialFloorFraction` are available for tuning in the render expression layer.

No blockers. No open questions for this plan.
