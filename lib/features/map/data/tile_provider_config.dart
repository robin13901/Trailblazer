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
/// Owns the `(lightStyle, darkStyle, apiKey)` tuple and resolves style URLs
/// via [styleUrl]. Callers with an empty key MUST check [hasKey] first — the
/// resolver asserts on empty keys in debug builds so the failure surfaces
/// during development rather than silently rendering blank tiles.
class TileProviderConfig {
  /// Construct a config with an explicit light + dark style pair and an
  /// injected API key. Pass `apiKey: ''` when `--dart-define=MAPTILER_KEY` is
  /// missing — [hasKey] will report `false` and callers can diagnose.
  const TileProviderConfig({
    required this.lightStyle,
    required this.darkStyle,
    required this.apiKey,
  });

  /// Style ID served when the app runs under a light theme.
  final MapTilerStyle lightStyle;

  /// Style ID served when the app runs under a dark theme.
  final MapTilerStyle darkStyle;

  /// The MapTiler API key. Empty string when `--dart-define=MAPTILER_KEY` is
  /// missing at build time. Never logged; never persisted.
  final String apiKey;

  /// `true` iff [apiKey] is non-empty. Callers MUST check this before
  /// invoking [styleUrl].
  bool get hasKey => apiKey.isNotEmpty;

  /// Resolve the MapTiler `style.json` URL for [style].
  ///
  /// Debug builds assert that [hasKey] is `true` — an empty key produces an
  /// unusable URL. Release builds construct the URL regardless (the map load
  /// will fail with an HTTP error, which the diagnostics logger catches
  /// upstream).
  Uri styleUrl(MapTilerStyle style) {
    assert(hasKey, 'apiKey is empty — check --dart-define=MAPTILER_KEY');
    return Uri.parse(
      'https://api.maptiler.com/maps/${style.id}/style.json?key=$apiKey',
    );
  }
}
