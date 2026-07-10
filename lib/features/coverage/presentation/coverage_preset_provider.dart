// Trailblazer Phase 7, Plan 07-05:
// Riverpod provider for the user-chosen coverage color preset (REN-06).
// Plain AsyncNotifier — no @Riverpod codegen per project rules.

import 'package:auto_explore/core/prefs/app_prefs.dart';
import 'package:auto_explore/features/coverage/domain/coverage_color_preset.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

// ---------------------------------------------------------------------------
// CoveragePresetNotifier
// ---------------------------------------------------------------------------

/// Manages the user's chosen [CoverageColorPreset], hydrating from [AppPrefs]
/// on first access and persisting writes back through it.
///
/// Defaults to [CoverageColorPreset.amber] when no value is stored.
class CoveragePresetNotifier extends AsyncNotifier<CoverageColorPreset> {
  @override
  Future<CoverageColorPreset> build() =>
      ref.watch(appPrefsProvider).getCoveragePreset();

  /// Persists [preset] to [AppPrefs] and immediately updates the in-memory
  /// state so the UI reacts without waiting for a rebuild.
  Future<void> select(CoverageColorPreset preset) async {
    await ref.read(appPrefsProvider).setCoveragePreset(preset);
    state = AsyncData(preset);
  }
}

/// AsyncNotifierProvider for the coverage color preset.
///
/// Consumers that need async loading should watch this provider directly.
/// Consumers that want a synchronous value with an amber fallback should
/// use [coveragePresetValueProvider] instead.
final coveragePresetProvider =
    AsyncNotifierProvider<CoveragePresetNotifier, CoverageColorPreset>(
  CoveragePresetNotifier.new,
);

// ---------------------------------------------------------------------------
// Synchronous convenience provider
// ---------------------------------------------------------------------------

/// A synchronous convenience that exposes the current [CoverageColorPreset],
/// falling back to [CoverageColorPreset.amber] while the async load is in
/// progress or if no value is stored.
///
/// Used by the map bridge and the UI to avoid async boilerplate in widgets
/// that do not need loading/error state.
final coveragePresetValueProvider = Provider<CoverageColorPreset>(
  (ref) =>
      ref.watch(coveragePresetProvider).value ?? CoverageColorPreset.amber,
);
