import 'package:auto_explore/features/map/presentation/widgets/bottom_nav_shell.dart';
import 'package:auto_explore/features/map/presentation/widgets/focus_area_pill.dart';
import 'package:auto_explore/features/map/presentation/widgets/map_widget.dart';
import 'package:auto_explore/features/map/presentation/widgets/settings_glass_button.dart';
import 'package:auto_explore/features/map/presentation/widgets/trip_fab.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Phase-2 Map screen — chrome overlays on top of the base [MapWidget].
///
/// This widget accepts an optional [bottomNav] override so that Plan 02-06 can
/// inject a `StatefulNavigationShell`-driven pill. When `null` (Phase 2
/// pre-06), a self-managed [_LocalBottomNav] is used so the screen is
/// testable standalone.
///
/// Layout (Stack, top → bottom):
///   1. [MapWidget] fills the entire screen (includes location dot + RecenterButton).
///   2. Top-left [SettingsGlassButton] (gear icon, glass circle).
///   3. Top-center [FocusAreaPill] (placeholder stub).
///   4. Bottom-right [TripFab] (Phase 3 stub).
///   5. Bottom glass pill nav ([BottomNavShell] or injected [bottomNav]).
///
/// UI-06: deliberately has NO [AppBar].
class MapScreen extends ConsumerWidget {
  const MapScreen({this.bottomNav, super.key});

  /// Optional pre-wired bottom nav (from `StatefulNavigationShell` in 02-06).
  final Widget? bottomNav;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      // UI-06: no AppBar.
      body: Stack(
        children: [
          // Full-screen map (includes RecenterButton overlay inside MapWidget).
          const Positioned.fill(child: MapWidget()),

          // Top-left settings button — floats 44pt below top (clears status bar).
          const Positioned(
            top: 44,
            left: 16,
            child: SafeArea(child: SettingsGlassButton()),
          ),

          // Top-center focus-area pill stub.
          const Positioned(
            top: 44,
            left: 0,
            right: 0,
            child: SafeArea(child: Center(child: FocusAreaPill())),
          ),

          // Bottom-right FAB stub.
          const Positioned(
            right: 16,
            bottom: 100,
            child: TripFab(),
          ),

          // Bottom nav pill — injectable for 02-06.
          Positioned(
            left: 16,
            right: 16,
            bottom: 0,
            child: bottomNav ?? const _LocalBottomNav(),
          ),
        ],
      ),
    );
  }
}

/// Phase-2 self-managed 3-tab pill.
///
/// In Plan 02-06 this is replaced by a pill wired to
/// `StatefulNavigationShell.currentIndex + goBranch()`.
class _LocalBottomNav extends StatefulWidget {
  const _LocalBottomNav();

  @override
  State<_LocalBottomNav> createState() => _LocalBottomNavState();
}

class _LocalBottomNavState extends State<_LocalBottomNav> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    return BottomNavShell(
      currentIndex: _index,
      onTap: (i) => setState(() {
        _index = i;
      }),
    );
  }
}
