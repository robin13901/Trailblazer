import 'package:auto_explore/features/map/domain/follow_mode.dart';
import 'package:auto_explore/features/map/presentation/providers/camera_state_provider.dart';
import 'package:auto_explore/features/map/presentation/providers/location_permission_provider.dart';
import 'package:auto_explore/features/map/presentation/widgets/bottom_nav_shell.dart';
import 'package:auto_explore/features/map/presentation/widgets/focus_area_pill.dart';
import 'package:auto_explore/features/map/presentation/widgets/map_widget.dart';
import 'package:auto_explore/features/map/presentation/widgets/recenter_button.dart';
import 'package:auto_explore/features/map/presentation/widgets/settings_glass_button.dart';
import 'package:auto_explore/features/map/presentation/widgets/trip_fab.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:permission_handler/permission_handler.dart';

/// Layout constants for the bottom chrome row.
///
/// XFin reference: the pill and FAB share the same 56 dp height, and the
/// spacing (screen-edge ↔ FAB) equals (FAB ↔ pill), and equals the vertical
/// gap between the recenter button and the FAB. Everything is 12 dp.
const double _fabSize = 56;
const double _chromeGap = 12;
const double _navRowBottomInset = 12;

/// Phase-2 Map screen — chrome overlays on top of the base [MapWidget].
///
/// When [navigationShell] is provided (production: wired via
/// StatefulShellRoute), this screen reads the active tab index and drives
/// [BottomNavShell] via the shell's `goBranch` method. Chrome overlays
/// (focus pill, settings button, FAB, recenter) are hidden on non-map tabs
/// so that the Trips and Regions screens can own the full viewport.
///
/// When [navigationShell] is null (isolated widget tests), a self-managed
/// [_LocalBottomNav] is used so the screen remains testable standalone.
///
/// Layout (Stack, back → front):
///   1. [MapWidget] fills the entire screen.
///   2. Non-map tab content (full-screen, opaque, masks the map).
///   3. Map-tab-only chrome: settings button, focus pill, FAB.
///   4. Bottom glass pill nav (always visible).
///
/// UI-06: deliberately has NO [AppBar].
class MapScreen extends ConsumerWidget {
  const MapScreen({this.navigationShell, super.key});

  /// Shell from [StatefulShellRoute.indexedStack].
  ///
  /// When non-null, [BottomNavShell] is driven by the shell's
  /// `currentIndex` and `goBranch` method.
  final StatefulNavigationShell? navigationShell;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentIndex = navigationShell?.currentIndex ?? 0;
    final isMapTab = currentIndex == 0;

    return Scaffold(
      // UI-06: no AppBar.
      body: Stack(
        children: [
          // Full-screen map — always in the tree so MapLibre keeps its state
          // across tab switches (indexedStack semantics preserve it).
          const Positioned.fill(child: MapWidget()),

          // Non-map tabs render their Scaffold (opaque background) over the
          // map when the shell index is > 0.
          if (navigationShell != null && !isMapTab)
            Positioned.fill(child: navigationShell!),

          // Map-tab-only chrome (hidden on Trips / Regions).
          if (isMapTab) ...[
            // Top-left settings button — floats 44pt below top (clears status bar).
            Positioned(
              top: 44,
              left: 16,
              child: SafeArea(
                child: SettingsGlassButton(
                  // Only wire navigation when the full shell is present.
                  // When navigationShell is null (isolated widget tests),
                  // onTap is left null so the button renders without crashing.
                  // Use push (not go) so the shell stays alive beneath the
                  // Settings screen and MapWidget is not disposed.
                  onTap: navigationShell != null
                      ? () => context.push('/settings')
                      : null,
                ),
              ),
            ),

            // Top-center focus-area pill stub.
            const Positioned(
              top: 44,
              left: 0,
              right: 0,
              child: SafeArea(child: Center(child: FocusAreaPill())),
            ),
          ],

          // Bottom chrome — fixed-slot layout so pill position never shifts
          // when the FAB is hidden on non-map tabs. See _BottomChrome.
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.only(bottom: _navRowBottomInset),
                child: _BottomChrome(
                  navShell: navigationShell != null
                      ? BottomNavShell(
                          currentIndex: currentIndex,
                          onTap: navigationShell!.goBranch,
                        )
                      : const _LocalBottomNav(),
                  showFab: isMapTab,
                ),
              ),
            ),
          ),

          // Recenter button — sits directly above the FAB slot with the same
          // right margin, forming a vertical stack of two 56 dp glass
          // circles. Only visible on the Map tab AND when the user has
          // panned away from their location.
          if (isMapTab) const _RecenterSlot(),
        ],
      ),
    );
  }
}

/// Phase-2 self-managed 3-tab pill.
///
/// Used when [MapScreen.navigationShell] is null — i.e., in isolated widget
/// tests that pump [MapScreen] directly without a [GoRouter] shell. In
/// production, the shell-driven path replaces this entirely.
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

/// Fixed-slot bottom chrome — nav pill centered, FAB anchored to the right.
///
/// The FAB slot is ALWAYS reserved (even when [showFab] is false) so that
/// the nav pill occupies the exact same on-screen position on every tab.
/// This matches the XFin reference where the pill does not shift.
///
/// Layout: [FAB gutter | FAB slot | gap | PILL | gap | FAB slot | FAB gutter]
///                                         ^ centered inside this slot
///
/// The pill is centered by placing an identical (empty) FAB slot on the
/// left, mirroring the real FAB slot on the right — so the visual center
/// of the pill matches the visual center of the screen minus the FAB row.
class _BottomChrome extends StatelessWidget {
  const _BottomChrome({required this.navShell, required this.showFab});

  final Widget navShell;
  final bool showFab;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: _chromeGap),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // Left "phantom" slot: mirrors the right FAB slot so the pill
          // is optically centered when the FAB is present, and remains
          // in the same position when the FAB is hidden.
          const SizedBox(width: _fabSize),
          const SizedBox(width: _chromeGap),
          Flexible(child: navShell),
          const SizedBox(width: _chromeGap),
          SizedBox(
            width: _fabSize,
            height: _fabSize,
            child: showFab ? const TripFab() : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}

/// Recenter button slot — pinned above the FAB slot with matching margins.
///
/// XFin-style perfect spacing: the distance from the screen edge to the
/// recenter button equals the distance from the FAB to the recenter button
/// equals [_chromeGap] (12 dp).
class _RecenterSlot extends ConsumerWidget {
  const _RecenterSlot();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final permissionAsync = ref.watch(locationPermissionProvider);
    final cameraState = ref.watch(cameraStateProvider);

    final isGranted = permissionAsync.maybeWhen(
      data: (s) => s.isGranted || s.isLimited,
      orElse: () => false,
    );
    final isFollowing =
        cameraState.followMode == FollowMode.location ||
        cameraState.followMode == FollowMode.locationAndHeading;

    if (!isGranted || isFollowing) return const SizedBox.shrink();

    final bottomInset = MediaQuery.of(context).padding.bottom;
    // Bottom position: safe area + row inset + FAB height + chrome gap.
    final recenterBottom =
        bottomInset + _navRowBottomInset + _fabSize + _chromeGap;

    return Positioned(
      right: _chromeGap,
      bottom: recenterBottom,
      child: const RecenterButton(),
    );
  }
}
