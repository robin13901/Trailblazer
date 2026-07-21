// Trailblazer Phase 8, Plan 08-04 (Wave 2):
// FocusPillProvider — debounced live camera -> region name + coverage %.
//
// Two drivers:
//   * IDLE (not recording): watches liveCameraProvider; on each camera change
//     (re)starts a 150 ms trailing debounce, then resolves the region under the
//     map CENTER at the ZOOM-DERIVED level (fallbackLevelsFrom) — so a zoomed-
//     out view shows the coarser containing region.
//   * RECORDING (live driving): watches liveFixProvider; on each accepted GPS
//     fix (re)starts the same debounce, then resolves the region under the FIX
//     coordinate using the FINEST-level-first chain (smallest region always —
//     e.g. "Kleinheubach", never "Landkreis Miltenberg" / "Bayern"),
//     independent of camera zoom. This makes the pill switch live as the driver
//     crosses a town boundary (on-device request 2026-07-21). While recording,
//     the camera driver is suppressed so a coarse zoom-derived resolve can't
//     clobber the fine live-fix one (the native camera follows the GPS puck, so
//     onCameraMove fires continuously during a drive).
//
// Neither path recomputes coverage — percent is always a cheap cache PK read.
//
// Hold-last-value anti-flicker: state is NEVER reset to blank between resolves
// — only overwritten when a fresh resolve completes (CONTEXT.md lines 29, 55).
//
// Out-of-order guard: monotonically increasing _requestId ensures a slow
// resolve cannot clobber a newer one (prevents jitter on rapid pans/fixes).
//
// Plain NotifierProvider — no @Riverpod codegen (STATE.md Plan 01-01).
// Package imports only.

import 'dart:async';

import 'package:auto_explore/features/admin/data/admin_region_providers.dart';
import 'package:auto_explore/features/coverage/data/coverage_providers.dart';
import 'package:auto_explore/features/map/presentation/providers/live_camera_provider.dart';
import 'package:auto_explore/features/regions/domain/region_coverage.dart';
import 'package:auto_explore/features/regions/domain/zoom_level_mapper.dart';
import 'package:auto_explore/features/trips/domain/live_fix_sample.dart';
import 'package:auto_explore/features/trips/domain/tracking_state.dart';
import 'package:auto_explore/features/trips/presentation/providers/tracking_state_provider.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Pill display state — name over coverage %.
///
/// [name] is null ONLY before the very first successful resolve (initial
/// value). After the first resolve the notifier always holds the last known
/// name, even during a new in-flight resolve.
@immutable
class FocusPillState {
  const FocusPillState({this.name, this.percentLabel});

  /// Region name, e.g. "Grebenhain". Null only before first resolve.
  final String? name;

  /// One-decimal coverage string, e.g. "26.4%". Null when the region exists
  /// but has no cache row yet (widget shows "—%" placeholder).
  final String? percentLabel;

  /// True once the first resolve has completed and a name is held.
  bool get hasValue => name != null;
}

/// Debounce interval for the trailing timer. 150 ms is a good balance:
/// fast enough to feel live during smooth pan/zoom, long enough to coalesce
/// rapid OS touch-move events and avoid excessive region lookups.
const Duration _kDebounce = Duration(milliseconds: 150);

/// Watches [liveCameraProvider], debounces, resolves the containing admin
/// region at the zoom-derived level (with a parent-level fallback chain),
/// reads the coverage cache row, and exposes a [FocusPillState].
///
/// Holds last value while resolving — state is NEVER blank after first resolve.
class FocusPillNotifier extends Notifier<FocusPillState> {
  Timer? _debounce;
  int _requestId = 0;

  @override
  FocusPillState build() {
    // Cancel any pending timer when Riverpod disposes this notifier (e.g.
    // when the provider is no longer watched or the container is disposed).
    // Use cascade to satisfy cascade_invocations lint.
    ref
      ..onDispose(() {
        _debounce?.cancel();
        _debounce = null;
      })

      // Listen to the live camera without triggering a state reset. Using
      // ref.listen keeps the "hold-last-value" contract: the notifier's state
      // is NOT set back to a blank value on each camera change.
      //
      // Suppressed while recording: the native camera follows the GPS puck, so
      // onCameraMove fires continuously during a drive. A coarse zoom-derived
      // camera resolve would otherwise race with — and clobber — the fine
      // live-fix resolve below. During recording the fix stream owns the pill.
      ..listen<LiveCamera?>(liveCameraProvider, (_, next) {
        if (next == null) return;
        if (_isRecording()) return;
        _debounce?.cancel();
        _debounce = Timer(
          _kDebounce,
          () => _resolve(
            lat: next.latitude,
            lon: next.longitude,
            // IDLE: resolve at the zoom-derived level so a zoomed-out view
            // shows the coarser containing region.
            levels: fallbackLevelsFrom(next.zoom),
          ),
        );
      })

      // Listen to accepted GPS fixes. While recording, each fix (re)starts the
      // debounce and resolves the SMALLEST region containing the fix — always
      // finest-level-first so we show "Kleinheubach", not the enclosing
      // Landkreis / Bundesland (on-device request 2026-07-21).
      ..listen<AsyncValue<LiveFixSample>>(liveFixProvider, (_, next) {
        if (next case AsyncData(:final value)) {
          _debounce?.cancel();
          _debounce = Timer(
            _kDebounce,
            () => _resolve(
              lat: value.lat,
              lon: value.lon,
              // RECORDING: always start at the finest level (smallest region).
              levels: kFallbackLevels,
            ),
          );
        }
      });

    // Initial state: blank — name is null until the first resolve completes.
    return const FocusPillState();
  }

  /// True while a trip is actively recording. Read (not watched) so it does
  /// not itself trigger a rebuild — the fix/camera listeners drive updates.
  bool _isRecording() => ref.read(trackingStateProvider) is TrackingRecording;

  /// Async resolve: look up the containing region + cache row, then update
  /// state. A monotonically increasing [_requestId] guards against
  /// out-of-order completions on rapid pans/fixes.
  ///
  /// [levels] is the fallback chain to try in order (first non-null wins).
  /// Callers pass the zoom-derived chain when idle, or [kFallbackLevels]
  /// (finest-first) while recording so the pill shows the smallest region.
  Future<void> _resolve({
    required double lat,
    required double lon,
    required List<int> levels,
  }) async {
    final myId = ++_requestId;

    final lookup = ref.read(adminRegionLookupProvider);
    await lookup.ensureLoaded();

    // Walk the fallback chain: first non-null region wins. The bundle has no
    // level-2 (country) polygon, so a `[2]`-only chain (country zoom) resolves
    // nothing here — Deutschland is handled explicitly below.
    final region = await () async {
      for (final level in levels) {
        if (level == 2) continue; // no country polygon in the bundle
        final r = await lookup.regionAt(lat, lon, level);
        if (r != null) return r;
      }
      return null;
    }();

    // Out-of-order guard: only commit if this is still the latest request.
    if (myId != _requestId) return;

    // No admin region resolved at any finer level. Distinguish "zoomed out /
    // over water but still within Germany" from "genuinely outside Germany".
    // Level 4 (Bundesländer) tiles the whole country, so a point-in-any-L4
    // test answers "are we over Germany?". (bug 2026-07-11: pill froze on the
    // last Bundesland at country zoom and when panning abroad, because the old
    // code kept the last value whenever the chain missed.)
    if (region == null) {
      final inGermany = await lookup.regionAt(lat, lon, 4) != null;
      if (myId != _requestId) return;
      state = inGermany
          // Over DE at a level with no polygon (country zoom / small water
          // gap): show the national label. No national % is computed (issue #2
          // — no true country denominator), so percent stays blank ("—%").
          ? const FocusPillState(name: 'Deutschland')
          // Genuinely outside all German polygons: neutral placeholder rather
          // than a stale region (user decision 2026-07-11).
          : const FocusPillState(name: '—');
      return;
    }

    // Coverage cache: PK point-read — very fast.
    final cacheDao = ref.read(coverageCacheDaoProvider);
    final row = await cacheDao.getByRegionId(region.osmId.toString());

    // Denominator MUST match the regions tab (region_browser_provider): prefer
    // the bundled real per-region Kfz total, fall back to the haversine bbox
    // total. Using totalLengthM alone (the fetched-ways haversine sum) inflates
    // the % badly — e.g. Kleinheubach showed 29,1 % on the pill vs the correct
    // 9,8 % on the card (bug 2026-07-17).
    final total = row?.realTotalLengthM ?? row?.totalLengthM ?? 0;
    String? percentLabel;
    if (row != null && total > 0) {
      percentLabel = formatPercent(
        coveragePercent(row.drivenLengthM, total),
      );
    }
    // row == null or total <= 0 → percentLabel stays null →
    // widget renders "—%" placeholder

    // Out-of-order guard: only commit if this is still the latest request.
    if (myId != _requestId) return;

    state = FocusPillState(
      name: region.nameDe ?? region.name,
      percentLabel: percentLabel,
    );
  }
}

/// Live focus-pill state provider.
///
/// Resolves the admin region under the current map center (from zoom-derived
/// level with parent fallback), reads its coverage %, and exposes a
/// [FocusPillState] that the FocusAreaPill widget renders.
///
/// Plain [NotifierProvider] — no `@Riverpod` codegen.
final focusPillProvider =
    NotifierProvider<FocusPillNotifier, FocusPillState>(FocusPillNotifier.new);
