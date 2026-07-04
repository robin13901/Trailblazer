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
/// XFin reference: the pill and FAB share the same height/diameter, and
/// the spacing (screen-edge ↔ FAB), (FAB ↔ pill), and (FAB ↔ recenter,
/// vertical) all equal `_chromeGap`.
const double _fabSize = 64;
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

          // Bottom pill — centered across the entire bottom of the screen.
          // Uses its own Positioned so it is TRULY centered (screen-width
          // aware), regardless of what other chrome is on the left or right.
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.only(bottom: _navRowBottomInset),
                child: Center(
                  child: navigationShell != null
                      ? BottomNavShell(
                          currentIndex: currentIndex,
                          onTap: navigationShell!.goBranch,
                        )
                      : const _LocalBottomNav(),
                ),
              ),
            ),
          ),

          // FAB — pinned bottom-right, aligned to pill vertically.
          if (isMapTab)
            const Positioned(
              right: _chromeGap,
              bottom: 0,
              child: SafeArea(
                child: Padding(
                  padding: EdgeInsets.only(bottom: _navRowBottomInset),
                  child: SizedBox(
                    width: _fabSize,
                    height: _fabSize,
                    child: TripFab(),
                  ),
                ),
              ),
            ),

          // Recenter — pinned above the FAB, same right margin.
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

/// Recenter button — pinned above the FAB with the same right margin,
/// same gap as the pill's bottom inset. Renders nothing when location
/// permission is missing or the user is already in follow mode.
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
    // Bottom: safe area + row inset + FAB height + chrome gap.
    final recenterBottom =
        bottomInset + _navRowBottomInset + _fabSize + _chromeGap;

    return Positioned(
      right: _chromeGap,
      bottom: recenterBottom,
      child: const RecenterButton(),
    );
  }
}
