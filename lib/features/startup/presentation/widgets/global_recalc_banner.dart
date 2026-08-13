// One-shot startup recalc banner (2026-07-26).
//
// Watches [globalRecalcProgressProvider] and, when non-null, renders a
// GlassPill-style banner over the map showing the app-wide progress of the
// one-time global re-match + coverage rebuild:
//   - rematching  → "Neuberechnung … Fahrt N/M" + determinate bar
//   - recomputing → "Abdeckung wird neu berechnet … N/M" + determinate bar
//                    (falls back to an indeterminate bar until the first count
//                    lands / when no tiles need clipping)
// It renders nothing when the provider is null (idle / migration done).
//
// German UI text throughout (the app is all German).

import 'package:auto_explore/features/coverage/domain/coverage_color_preset.dart';
import 'package:auto_explore/features/coverage/presentation/coverage_preset_provider.dart';
import 'package:auto_explore/features/map/presentation/widgets/glass_pill.dart';
import 'package:auto_explore/features/startup/data/global_recalc_progress_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// App-wide banner for the one-time global recalc migration. Visible on launch
/// (mounted on the Map screen) so the user sees the re-match + coverage rebuild
/// progress rather than a seemingly-frozen app.
class GlobalRecalcBanner extends ConsumerWidget {
  const GlobalRecalcBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(globalRecalcProgressProvider);
    if (state == null) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final preset = ref.watch(coveragePresetValueProvider);
    final lineColor = _hexToColor(
      preset.forBrightness(theme.brightness).fullHex,
    );

    final isRematching = state.phase == GlobalRecalcPhase.rematching;
    final isOverlayFetch = state.phase == GlobalRecalcPhase.overlayFetching;
    final hasCount = state.total > 0;
    final value = hasCount ? state.done / state.total : null;

    final String title;
    if (isRematching) {
      title = hasCount
          ? 'Neuberechnung … Fahrt ${state.done}/${state.total}'
          : 'Neuberechnung …';
    } else if (isOverlayFetch) {
      title = hasCount
          ? 'Kartenlinie wird geladen … ${state.done}/${state.total}'
          : 'Kartenlinie wird geladen …';
    } else {
      title = hasCount
          ? 'Abdeckung wird neu berechnet … ${state.done}/${state.total}'
          : 'Abdeckung wird neu berechnet …';
    }

    return Semantics(
      liveRegion: true,
      label: title,
      child: GlassPill(
        overMap: true,
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: value,
                minHeight: 4,
                backgroundColor: lineColor.withValues(alpha: 0.2),
                valueColor: AlwaysStoppedAnimation<Color>(lineColor),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// '#RRGGBB' → opaque [Color] (mirrors focus_area_pill._hexToColor).
Color _hexToColor(String hex) {
  final clean = hex.replaceFirst('#', '');
  return Color(int.parse('FF$clean', radix: 16));
}
