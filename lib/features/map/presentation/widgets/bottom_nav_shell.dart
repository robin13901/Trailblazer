import 'package:auto_explore/features/map/presentation/widgets/glass_pill.dart';
import 'package:flutter/material.dart';

/// Glass bottom pill with 3 tabs: Map / Trips / Regions.
///
/// This is a **pure presentation widget** — it accepts [currentIndex] and
/// [onTap] from the caller. Plan 02-06 wires it to a `StatefulNavigationShell`
/// by injecting the shell-driven index + `goBranch()` via the
/// `MapScreen.bottomNav` parameter. Until then, `MapScreen` uses
/// `_LocalBottomNav` for standalone operation.
///
/// Settings is NOT in the pill — it is a separate `SettingsGlassButton`
/// (top-left per 02-CONTEXT.md).
class BottomNavShell extends StatelessWidget {
  const BottomNavShell({
    required this.currentIndex,
    required this.onTap,
    super.key,
  });

  /// The 0-based index of the active tab.
  final int currentIndex;

  /// Called when the user taps a tab item.
  final ValueChanged<int> onTap;

  static const _tabs = [
    _TabItem(icon: Icons.map_outlined, label: 'Map'),
    _TabItem(icon: Icons.route, label: 'Trips'),
    _TabItem(icon: Icons.flag_outlined, label: 'Regions'),
  ];

  @override
  Widget build(BuildContext context) {
    // Fixed height 64 so the pill visually matches the 64 dp FAB / recenter
    // circles. XFin reference: pill and FAB same diameter/height.
    return SizedBox(
      height: 64,
      child: GlassPill(
        // Stadium shape: radius ≥ height/2 → 999 renders as full stadium.
        borderRadius: 999,
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < _tabs.length; i++)
              _NavTabItem(
                icon: _tabs[i].icon,
                label: _tabs[i].label,
                isSelected: currentIndex == i,
                onTap: () => onTap(i),
              ),
          ],
        ),
      ),
    );
  }
}

/// Data holder for a single tab definition.
class _TabItem {
  const _TabItem({required this.icon, required this.label});
  final IconData icon;
  final String label;
}

/// A single tappable tab inside [BottomNavShell].
class _NavTabItem extends StatelessWidget {
  const _NavTabItem({
    required this.icon,
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final activeColor = colorScheme.primary;
    final inactiveColor = colorScheme.onSurface.withValues(alpha: 0.5);
    final color = isSelected ? activeColor : inactiveColor;

    return Semantics(
      selected: isSelected,
      label: label,
      button: true,
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Padding(
          // The pill's outer GlassPill provides vertical breathing room —
          // this padding is horizontal-only so the label + icon fit inside
          // the 64 dp pill height. Widens each tab's tap target.
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 22, color: color),
              const SizedBox(height: 2),
              Text(
                label,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: color,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
