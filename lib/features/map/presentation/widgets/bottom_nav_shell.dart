import 'package:auto_explore/features/map/presentation/widgets/glass_pill.dart';
import 'package:flutter/material.dart';

/// Vertical space the bottom nav pill + its row inset occupy above the
/// safe-area bottom edge: pill height (64) + `_navRowBottomInset` (4) + a small
/// breathing gap (12) ≈ 80 dp.
///
/// The nav pill is a Stack sibling layered ON TOP of the Trips/Regions tab
/// content, so scrollable tab lists must reserve this as bottom padding —
/// otherwise the last item scrolls under the pill and is obscured (on-device
/// feedback 2026-07-22). The lists' own SafeArea handles the home-indicator
/// inset; this clearance is measured from that same safe-area bottom, so it
/// lines up with the pill regardless of device.
const double kBottomNavClearance = 80;

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
    this.overMap = false,
    super.key,
  });

  /// The 0-based index of the active tab.
  final int currentIndex;

  /// Called when the user taps a tab item.
  final ValueChanged<int> onTap;

  /// `true` when the pill is layered over the map (Map tab). On Apple
  /// platforms this forces the tinted fallback since the shader backdrop
  /// cannot sample the map PlatformView. On Trips/Regions the pill sits over
  /// an opaque Flutter surface, so `false` keeps the full glass effect.
  final bool overMap;

  static const _tabs = [
    _TabItem(icon: Icons.map_outlined, label: 'Karte'),
    _TabItem(icon: Icons.route, label: 'Fahrten'),
    _TabItem(icon: Icons.flag_outlined, label: 'Regionen'),
  ];

  @override
  Widget build(BuildContext context) {
    // Fixed height 64 so the pill visually matches the 64 dp FAB / recenter
    // circles. XFin reference: pill and FAB same diameter/height.
    //
    // Plan 04-18 Task 7 (2026-07-08): bounded width + spaceEvenly + Expanded
    // per the XFin pattern (`lib/widgets/liquid_glass_widgets.dart:127-165`).
    // Previously the pill sized-to-content via `mainAxisSize: MainAxisSize.min`
    // which made the icons cluster left of the pill's centered position.
    // Width 240 dp = ~80 dp per tab for 3 tabs, comfortable for icon + label.
    return SizedBox(
      width: 240,
      height: 64,
      child: GlassPill(
        overMap: overMap,
        // Stadium shape: radius ≥ height/2 → 999 renders as full stadium.
        borderRadius: 999,
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: List.generate(_tabs.length, (i) {
            final tab = _tabs[i];
            return Expanded(
              child: _NavTabItem(
                icon: tab.icon,
                label: tab.label,
                isSelected: currentIndex == i,
                onTap: () => onTap(i),
              ),
            );
          }),
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
          // The pill's outer GlassPill provides vertical breathing room.
          // Plan 04-18 Task 7 (2026-07-08): reduced horizontal padding
          // from 14 to 4 — with the new spaceEvenly + Expanded layout,
          // each tab occupies ~72 dp of the 240-wide pill, and the outer
          // Row itself distributes the gutter. Higher padding here
          // caused "Regions" to wrap in the constrained width.
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 20, color: color),
              const SizedBox(height: 2),
              // FittedBox(scaleDown) guarantees the label never truncates:
              // at the default text scale "Regionen" fits at 9 pt in the
              // ~72 dp tab, so all three render identically; only at large
              // accessibility text scales does it shrink to fit — which is
              // strictly better than ellipsizing to "Regio…" (on-device
              // feedback 2026-07-22, superseding the 10 pt + ellipsis fix).
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  label,
                  maxLines: 1,
                  softWrap: false,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    fontSize: 9,
                    color: color,
                    fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
