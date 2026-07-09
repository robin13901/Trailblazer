---
phase: 07-coverage-rendering
plan: 05
type: execute
wave: 2
depends_on: ["07-01"]
files_modified:
  - lib/core/prefs/app_prefs.dart
  - lib/features/coverage/presentation/coverage_preset_provider.dart
  - lib/features/settings/presentation/widgets/coverage_color_section.dart
  - lib/features/settings/presentation/settings_screen.dart
  - test/features/coverage/presentation/coverage_preset_provider_test.dart
  - test/features/settings/presentation/coverage_color_section_test.dart
autonomous: true

must_haves:
  truths:
    - "The chosen coverage preset persists in AppPrefs and survives app restart"
    - "The Settings screen shows a Coverage color section with 5 preset swatches, the active one visibly selected"
    - "Tapping a swatch (pick-then-confirm) updates the persisted preset"
    - "coveragePresetProvider exposes the current CoverageColorPreset, defaulting to amber when unset"
  artifacts:
    - path: "lib/features/coverage/presentation/coverage_preset_provider.dart"
      provides: "CoveragePresetNotifier + coveragePresetProvider (NotifierProvider)"
      contains: "coveragePresetProvider"
    - path: "lib/features/settings/presentation/widgets/coverage_color_section.dart"
      provides: "CoverageColorSection with 5 swatch chips"
      contains: "class CoverageColorSection"
    - path: "lib/core/prefs/app_prefs.dart"
      provides: "getCoveragePreset/setCoveragePreset"
      contains: "kCoveragePreset"
  key_links:
    - from: "coverage_preset_provider.dart"
      to: "AppPrefs.getCoveragePreset/setCoveragePreset"
      via: "persist selected preset"
      pattern: "CoveragePreset"
    - from: "settings_screen.dart"
      to: "CoverageColorSection"
      via: "new ListView section between Data and Coming later"
      pattern: "CoverageColorSection"
---

<objective>
Add the user-facing coverage color picker (REN-06): a Settings section with 5
preset swatches (amber/green/blue/purple/red), pick-then-confirm, persisted in
AppPrefs, exposed via `coveragePresetProvider`. The live-map recolor on return
is wired in 07-06 (the bridge watches this provider) — this plan owns
persistence + UI + provider only, so it can run in parallel with the render
bridge.

Purpose: Lets the user choose their explored-road color from the curated
palette; the choice survives restart and drives the map recolor without a tile
reload.
Output: prefs methods + provider + Settings section + tests.
</objective>

<execution_context>
@~/.claude/get-shit-done/workflows/execute-plan.md
@~/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@.planning/phases/07-coverage-rendering/07-RESEARCH.md
@.planning/phases/07-coverage-rendering/07-CONTEXT.md

# The palette enum from 07-01
@lib/features/coverage/domain/coverage_color_preset.dart

# Persistence pattern to extend (SharedPreferencesAsync, no in-memory cache)
@lib/core/prefs/app_prefs.dart

# Where the section goes + existing section/tile idiom
@lib/features/settings/presentation/settings_screen.dart
</context>

<tasks>

<task type="auto">
  <name>Task 1: Persist coverage preset in AppPrefs</name>
  <files>lib/core/prefs/app_prefs.dart</files>
  <action>
Add to AppPrefs:
  static const String kCoveragePreset = 'coverage_preset';

  Future<CoverageColorPreset> getCoveragePreset() async {
    final s = await _prefs.getString(kCoveragePreset);
    return s == null ? CoverageColorPreset.amber
                     : CoverageColorPreset.fromString(s);
  }
  Future<void> setCoveragePreset(CoverageColorPreset p) =>
      _prefs.setString(kCoveragePreset, p.name);

Import coverage_color_preset.dart (package import). Keep the existing
admin-bundle methods untouched.
  </action>
  <verify>flutter analyze clean.</verify>
  <done>AppPrefs.getCoveragePreset() returns amber when unset, the stored preset otherwise; setCoveragePreset writes the enum name.</done>
</task>

<task type="auto">
  <name>Task 2: coveragePresetProvider (NotifierProvider, no codegen)</name>
  <files>lib/features/coverage/presentation/coverage_preset_provider.dart</files>
  <action>
Plain NotifierProvider per project rule (NO @Riverpod). Because the initial
value comes from an async AppPrefs read, use an AsyncNotifier OR seed with amber
and hydrate:
  Preferred: `class CoveragePresetNotifier extends AsyncNotifier<CoverageColorPreset>`
    Future<CoverageColorPreset> build() => ref.watch(appPrefsProvider).getCoveragePreset();
    Future<void> select(CoverageColorPreset p) async {
      await ref.read(appPrefsProvider).setCoveragePreset(p);
      state = AsyncData(p);
    }
  final coveragePresetProvider =
    AsyncNotifierProvider<CoveragePresetNotifier, CoverageColorPreset>(
      CoveragePresetNotifier.new);

  Also expose a synchronous convenience for the bridge/UI:
    `final coveragePresetValueProvider = Provider<CoverageColorPreset>((ref) =>
       ref.watch(coveragePresetProvider).valueOrNull ?? CoverageColorPreset.amber);`
  so consumers (07-06 bridge, the swatch highlight) get a non-async value with
  an amber fallback during hydration.

Confirm AsyncNotifier/AsyncNotifierProvider are the plain (non-codegen) Riverpod
classes — they are (flutter_riverpod exports them). Package imports only.
  </action>
  <verify>flutter analyze clean.</verify>
  <done>coveragePresetProvider hydrates from AppPrefs, select() persists + updates state; coveragePresetValueProvider gives a sync amber-fallback value.</done>
</task>

<task type="auto">
  <name>Task 3: CoverageColorSection swatches + wire into Settings</name>
  <files>lib/features/settings/presentation/widgets/coverage_color_section.dart, lib/features/settings/presentation/settings_screen.dart</files>
  <action>
Create `CoverageColorSection extends ConsumerWidget`:
  - Reads coveragePresetValueProvider for the active preset.
  - Renders a Row (or Wrap) of 5 tappable swatches — one per
    CoverageColorPreset.values. Each swatch: a Container circle (~36dp) filled
    with the preset's LIGHT full hex (parse hex -> Color; add a small hex->Color
    helper or reuse one — do NOT depend on colorToHex which goes the other way;
    write `Color _hexToColor(String hex)`), with a selected indicator
    (border + check icon) when it equals the active preset.
  - Tapping a swatch calls
    `ref.read(coveragePresetProvider.notifier).select(preset)` (pick-then-confirm
    — the CONTEXT model: selection persists; the live map is the preview and
    recolors when the user returns to it via the 07-06 bridge). Add a subtitle
    ListTile explaining "Applies to your explored roads on the map."
  - Use `withValues(alpha:)` for any translucency, never withOpacity.
  - Accessible: wrap swatches in Semantics with the preset label; min 44dp tap
    target.

Wire into settings_screen.dart: add a `_SectionHeader('Coverage')` +
`CoverageColorSection()` block between the Data section and the 'Coming later'
section. SettingsScreen is currently a StatelessWidget with const children —
CoverageColorSection is a ConsumerWidget so it can stay const; no need to
convert SettingsScreen to Consumer. Add the import.

Test files:
  coverage_preset_provider_test.dart — ProviderContainer with an AppPrefs
    backed by SharedPreferences in-memory/mock (grep test/ for existing
    SharedPreferencesAsync test setup / setMockInitialValues). Assert default
    amber, select(green) persists + state updates, re-read reflects green.
  coverage_color_section_test.dart — pumpWidget the section inside a
    ProviderScope + MaterialApp; assert 5 swatches render; tapping the green
    swatch calls select and the selected indicator moves. Use a container
    override for coveragePresetProvider if needed.

Run `flutter test test/features/coverage/presentation/coverage_preset_provider_test.dart
test/features/settings/` inline (behavior-sensitive + widget).
  </action>
  <verify>flutter test for the two new tests green; flutter analyze clean; Settings screen shows the Coverage section.</verify>
  <done>Settings has a Coverage color section with 5 selectable swatches; selection persists via AppPrefs and updates coveragePresetProvider.</done>
</task>

</tasks>

<verification>
- `flutter analyze` clean.
- `flutter test test/features/coverage/ test/features/settings/` green.
- Preset persists across a fresh AppPrefs read (restart-equivalent) in the test.
</verification>

<success_criteria>
User can pick one of 5 coverage color presets in Settings (pick-then-confirm),
the choice persists in AppPrefs and is exposed via coveragePresetProvider for
the map bridge to react to. No free color wheel (5 curated presets only, green
included, amber default).
</success_criteria>

<output>
After completion, create `.planning/phases/07-coverage-rendering/07-05-SUMMARY.md`
</output>
