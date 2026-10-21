// Trailblazer undriven-ways overlay: the fetch banner.
//
// Watches [undrivenFetchProgressProvider] and renders a GlassPill "Ungefahrene
// Wege werden geladen … Kachel N/M" with a determinate bar while the on-demand
// tile fetch runs. Renders nothing when idle. Mirrors GlobalRecalcBanner but
// scoped to this feature so the label is accurate and never collides with the
// startup-migration banner.

import 'package:auto_explore/features/coverage/data/undriven_fetch_progress_provider.dart';
import 'package:auto_explore/features/coverage/domain/coverage_color_preset.dart';
import 'package:auto_explore/features/coverage/presentation/coverage_preset_provider.dart';
import 'package:auto_explore/features/map/presentation/widgets/glass_pill.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Banner shown while the undriven-ways overlay fetches missing Overpass tiles.
class UndrivenFetchBanner extends ConsumerWidget {
  const UndrivenFetchBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final progress = ref.watch(undrivenFetchProgressProvider);
    if (progress == null) return const SizedBox.shrink();

    final theme = Theme.of(context);
    // Tint the bar with the undriven preset so the banner matches the blue
    // roads it is loading.
    final preset = ref.watch(undrivenPresetValueProvider);
    final lineColor = _hexToColor(
      preset.forBrightness(theme.brightness).fullHex,
    );

    final hasCount = progress.total > 0;
    final value = hasCount ? progress.done / progress.total : null;
    const label = 'Ungefahrene Wege werden geladen …';
    final countLine = hasCount
        ? 'Kachel ${progress.done} / ${progress.total}'
        : null;

    return Semantics(
      liveRegion: true,
      label: countLine != null ? '$label $countLine' : label,
      child: GlassPill(
        overMap: true,
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            if (countLine != null) ...[
              const SizedBox(height: 2),
              Text(
                countLine,
                maxLines: 1,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                ),
              ),
            ],
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

/// '#RRGGBB' → opaque [Color] (mirrors global_recalc_banner._hexToColor).
Color _hexToColor(String hex) {
  final clean = hex.replaceFirst('#', '');
  return Color(int.parse('FF$clean', radix: 16));
}
