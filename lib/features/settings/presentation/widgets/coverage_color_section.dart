// Trailblazer Phase 7, Plan 07-05:
// Settings > Coverage section — 5 preset swatches with pick-then-confirm (REN-06).

import 'package:auto_explore/features/coverage/domain/coverage_color_preset.dart';
import 'package:auto_explore/features/coverage/presentation/coverage_preset_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Settings section that lets the user choose one of the 5 curated coverage
/// color presets. Tapping a swatch immediately persists the selection
/// (pick-then-confirm) via [coveragePresetProvider].
class CoverageColorSection extends ConsumerWidget {
  const CoverageColorSection({super.key});

  /// Converts a 7-character '#RRGGBB' hex string to a Flutter [Color].
  static Color _hexToColor(String hex) {
    final clean = hex.replaceFirst('#', '');
    return Color(int.parse('FF$clean', radix: 16));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = ref.watch(coveragePresetValueProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const ListTile(
          title: Text('Coverage color'),
          subtitle: Text('Applies to your explored roads on the map.'),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Wrap(
            spacing: 12,
            children: CoverageColorPreset.values.map((preset) {
              final isSelected = preset == active;
              // Light-mode full hex is the representative swatch color.
              final hex = preset.forBrightness(Brightness.light).fullHex;
              final color = _hexToColor(hex);

              return Semantics(
                label: preset.label,
                selected: isSelected,
                button: true,
                child: GestureDetector(
                  onTap: () => ref
                      .read(coveragePresetProvider.notifier)
                      .select(preset),
                  child: SizedBox(
                    // 44dp minimum tap target (accessibility).
                    width: 44,
                    height: 44,
                    child: Center(
                      child: Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: color,
                          shape: BoxShape.circle,
                          border: isSelected
                              ? Border.all(
                                  color: Theme.of(context).colorScheme.onSurface,
                                  width: 2.5,
                                )
                              : Border.all(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurface
                                      .withValues(alpha: 0.2),
                                ),
                        ),
                        child: isSelected
                            ? Icon(
                                Icons.check,
                                size: 18,
                                color: ThemeData.estimateBrightnessForColor(color) ==
                                        Brightness.dark
                                    ? Colors.white
                                    : Colors.black,
                              )
                            : null,
                      ),
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ),
      ],
    );
  }
}
