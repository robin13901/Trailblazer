/// Vector-tile provider configuration for the MapLibre map screen.
///
/// This model is the seam between the injected `MAPTILER_KEY` (delivered via
/// `--dart-define=MAPTILER_KEY=...` or `--dart-define-from-file=env/dev.json`)
/// and the runtime style URL that the map widget consumes.
///
/// Pure Dart — no Flutter, no `dart:io`, no I/O of any kind. Safe to construct
/// eagerly in `main()` before the widget tree is built, and safe to unit-test
/// without a `TestWidgetsFlutterBinding`.
///
/// See:
/// - `.planning/phases/04-osm-pipeline/04-11-STYLE-SPIKE.md` — empirical
///   verification that these style IDs resolve on the MapTiler Cloud free
///   tier. Do NOT change enum values without a fresh spike.
/// - `.planning/phases/04-osm-pipeline/04-11-maptiler-provider-and-key-plumbing-PLAN.md`
///   — the contract this model implements.
library;

/// MapTiler style catalog covered by 04-11-STYLE-SPIKE.md.
///
/// Enum values populated from the spike doc. Do NOT change without a fresh
/// spike — MapTiler's free-tier catalog is not guaranteed stable across
/// accounts or over time.
enum MapTilerStyle {
  /// Muted grayscale — RESEARCH-recommended default for the light theme.
  dataviz,

  /// Dark counterpart to [dataviz] — RESEARCH-recommended default for the dark
  /// theme.
  datavizDark,

  /// Fallback light style if [dataviz] is ever gated on a future account.
  streetsV2,

  /// Fallback dark style — pair for [streetsV2].
  streetsV2Dark,
}

/// MapTiler-URL-path segment for each [MapTilerStyle] variant.
extension MapTilerStyleId on MapTilerStyle {
  /// The exact style-ID string MapTiler expects in the URL path. Verified
  /// against the free-tier account in 04-11-STYLE-SPIKE.md.
  String get id {
    switch (this) {
      case MapTilerStyle.dataviz:
        return 'dataviz';
      case MapTilerStyle.datavizDark:
        return 'dataviz-dark';
      case MapTilerStyle.streetsV2:
        return 'streets-v2';
      case MapTilerStyle.streetsV2Dark:
        return 'streets-v2-dark';
    }
  }
}

/// Immutable tile-provider configuration.
///
/// Owns the `(lightStyle, darkStyle, apiKey, language)` tuple and resolves
/// style URLs via [styleUrl]. Callers with an empty key MUST check [hasKey]
/// first — the resolver asserts on empty keys in debug builds so the failure
/// surfaces during development rather than silently rendering blank tiles.
class TileProviderConfig {
  /// Construct a config with an explicit light + dark style pair and an
  /// injected API key. Pass `apiKey: ''` when `--dart-define=MAPTILER_KEY` is
  /// missing — [hasKey] will report `false` and callers can diagnose.
  ///
  /// [language] is the ISO-639-1 2-letter code appended to the style URL as
  /// `&language=<code>` so MapTiler serves place / road labels localized to
  /// that language where OpenMapTiles data provides a `{name:<code>}` field.
  /// Defaults to `'de'` (04-16-1 UX polish). See [resolveMapLanguage] for
  /// system-locale-aware selection.
  const TileProviderConfig({
    required this.lightStyle,
    required this.darkStyle,
    required this.apiKey,
    this.language = 'de',
  });

  /// Style ID served when the app runs under a light theme.
  final MapTilerStyle lightStyle;

  /// Style ID served when the app runs under a dark theme.
  final MapTilerStyle darkStyle;

  /// The MapTiler API key. Empty string when `--dart-define=MAPTILER_KEY` is
  /// missing at build time. Never logged; never persisted.
  final String apiKey;

  /// ISO-639-1 2-letter language code for map labels.
  ///
  /// Threaded into [styleUrl] as `&language=<code>`. Defaults to `'de'` per
  /// Plan 04-16-1 (2026-07-08 UX polish). Use [resolveMapLanguage] to
  /// choose from `Platform.localeName`.
  final String language;

  /// `true` iff [apiKey] is non-empty. Callers MUST check this before
  /// invoking [styleUrl].
  bool get hasKey => apiKey.isNotEmpty;

  /// Resolve the MapTiler `style.json` URL for [style].
  ///
  /// Debug builds assert that [hasKey] is `true` — an empty key produces an
  /// unusable URL. Release builds construct the URL regardless (the map load
  /// will fail with an HTTP error, which the diagnostics logger catches
  /// upstream).
  ///
  /// Plan 04-18 (2026-07-08): the `&language=<code>` query param is
  /// currently a NO-OP on MapTiler's free-tier hosted styles. The
  /// `dataviz-dark` / `dataviz` / `streets-v2` `style.json` bodies hardcode
  /// `text-field` layout properties to `{name:en}` and
  /// `coalesce(name:en, name)`; the server returns byte-identical JSON
  /// whether `&language=de` is present or absent. To restore German
  /// labels, either upgrade MapTiler tier OR add a client-side style
  /// rewrite (see 04-18-LANGUAGE-INVESTIGATION.md for the full analysis
  /// and rewrite sketch). Keeping the param wired keeps the
  /// infrastructure ready for when we revisit.
  // TODO(04-18): revisit MapTiler language once we upgrade tier OR
  // implement client-side style-JSON rewrite. See
  // .planning/phases/04-osm-pipeline/04-18-LANGUAGE-INVESTIGATION.md.
  Uri styleUrl(MapTilerStyle style) {
    assert(hasKey, 'apiKey is empty — check --dart-define=MAPTILER_KEY');
    return Uri.parse(
      'https://api.maptiler.com/maps/${style.id}/style.json'
      '?key=$apiKey&language=$language',
    );
  }
}

/// Set of ISO-639-1 language codes MapTiler's OpenMapTiles-schema styles
/// support via the `?language=<code>` URL param.
///
/// Curated from MapTiler docs (as of 2026-07-08). Any code outside this set
/// falls back to `'de'` in [resolveMapLanguage].
const kMapTilerSupportedLanguages = <String>{
  'en',
  'de',
  'es',
  'fr',
  'it',
  'ja',
  'ko',
  'nl',
  'pt',
  'ru',
  'tr',
  'uk',
  'vi',
  'zh',
};

/// Resolve a MapTiler-supported language code from a platform-locale string.
///
/// [platformLocale] is typically `Platform.localeName` (e.g. `de_DE`,
/// `en-US`, `zh-Hans`). Splits on `_` or `-`, lowercases, and returns the
/// leading 2-letter code iff it appears in [kMapTilerSupportedLanguages];
/// otherwise defaults to `'de'` per Plan 04-16-1.
///
/// Pure function — no `dart:io` reference — so the helper is safely called
/// from `main.dart` (which owns the `Platform.localeName` read) without
/// dragging platform IO into this pure-Dart config module.
String resolveMapLanguage(String platformLocale) {
  final raw = platformLocale.split(RegExp('[_-]')).first.toLowerCase();
  return kMapTilerSupportedLanguages.contains(raw) ? raw : 'de';
}
