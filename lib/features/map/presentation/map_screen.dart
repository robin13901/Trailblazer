import 'package:auto_explore/features/map/domain/follow_mode.dart';
import 'package:auto_explore/features/map/presentation/providers/camera_state_provider.dart';
import 'package:auto_explore/features/map/presentation/providers/location_permission_provider.dart';
import 'package:auto_explore/features/map/presentation/widgets/bottom_nav_shell.dart';
import 'package:auto_explore/features/map/presentation/widgets/focus_area_pill.dart';
import 'package:auto_explore/features/map/presentation/widgets/map_widget.dart';
import 'package:auto_explore/features/map/presentation/widgets/permission_denial_banner.dart';
import 'package:auto_explore/features/map/presentation/widgets/recenter_button.dart';
import 'package:auto_explore/features/map/presentation/widgets/settings_glass_button.dart';
import 'package:auto_explore/features/map/presentation/widgets/tracking_camera_sync.dart';
import 'package:auto_explore/features/map/presentation/widgets/trip_fab.dart';
import 'package:auto_explore/features/trips/presentation/widgets/live_tracking_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:permission_handler/permission_handler.dart';

/// Layout constants for the bottom chrome row.
///
/// Pill, FAB, and recenter are all 64 dp. Spacing between elements
/// (screen-edge ↔ FAB, FAB ↔ pill, FAB ↔ recenter vertical) is 12 dp.
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

          // Headless listener: drives cameraStateProvider on tracking
          // transitions. No visible UI — renders a SizedBox.shrink. Wrapped
          // in a zero-size top-left Positioned so it does NOT (a) size the
          // Stack (a non-Positioned Stack child would collapse the Stack
          // to that child's size) and (b) intercept hit-testing on the
          // chrome layered on top (a bare Positioned defaults to filling
          // the parent).
          const Positioned(
            top: 0,
            left: 0,
            width: 0,
            height: 0,
            child: TrackingCameraSync(),
          ),

          // Non-map tabs render their Scaffold (opaque background) over the
          // map when the shell index is > 0.
          if (navigationShell != null && !isMapTab)
            Positioned.fill(child: navigationShell!),

          // Map-tab-only chrome (hidden on Trips / Regions).
          if (isMapTab) ...[
            // Denial banner — top of map, below status bar, above other chrome.
            // Visible when Always location (or Android 13+ notification) is
            // not granted. Invalidates on AppLifecycleState.resumed.
            const Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SafeArea(
                child: Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: PermissionDenialBanner(),
                ),
              ),
            ),

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

          // Bottom chrome — nav pill + FAB + (optional) recenter, all in
          // a single Column so their positions are structurally guaranteed
          // to line up (identical Row structure on each line).
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
                  showRecenter: isMapTab,
                  showPanel: isMapTab,
                ),
              ),
            ),
          ),
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

/// Fixed-slot bottom chrome — live-panel (conditional), nav pill centered,
/// FAB anchored to the right, recenter button directly above the FAB.
///
/// Three-row Column:
///
///   Row 0 (live panel row): [phantom L | gap | LIVE PANEL (centered) | gap | phantom R ]
///   Row 1 (recenter row):   [phantom L | gap | phantom center | gap | RECENTER slot ]
///   Row 2 (main row):       [phantom L | gap |     PILL      | gap |   FAB slot   ]
///
/// Both phantom-slot rows share IDENTICAL widths (`_fabSize`, flex, `_fabSize`)
/// so the recenter and FAB are structurally guaranteed to have the same X range.
///
/// `Flexible` is deliberately AVOIDED on the pill — it has intrinsic
/// size, and Flexible/Expanded caused transient 0-width layouts during
/// SnackBar / navigation transitions, which crashed
/// `liquid_glass_renderer` inside `Picture.toImageSync(0, h)`.
class _BottomChrome extends StatelessWidget {
  const _BottomChrome({
    required this.navShell,
    required this.showFab,
    required this.showRecenter,
    required this.showPanel,
  });

  final Widget navShell;
  final bool showFab;
  final bool showRecenter;
  final bool showPanel;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: _chromeGap),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Row 0: live tracking panel — centered above chrome, map tab only.
          if (showPanel) ...[
            const Center(child: LiveTrackingPanel()),
            const SizedBox(height: _chromeGap),
          ],
          // Row 1: recenter above the FAB slot.
          Row(
            children: [
              const SizedBox(width: _fabSize),
              const SizedBox(width: _chromeGap),
              const Expanded(child: SizedBox.shrink()),
              const SizedBox(width: _chromeGap),
              SizedBox(
                width: _fabSize,
                height: _fabSize,
                child: showRecenter
                    ? const _RecenterOrEmpty()
                    : const SizedBox.shrink(),
              ),
            ],
          ),
          const SizedBox(height: _chromeGap),
          // Row 2: pill (centered) + FAB (right).
          Row(
            children: [
              const SizedBox(width: _fabSize),
              const SizedBox(width: _chromeGap),
              Expanded(child: Center(child: navShell)),
              const SizedBox(width: _chromeGap),
              SizedBox(
                width: _fabSize,
                height: _fabSize,
                child: showFab ? const TripFab() : const SizedBox.shrink(),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Renders the recenter button, or an empty box when location isn't
/// granted / user is already in follow mode. Kept as a widget so we can
/// read providers without rebuilding `_BottomChrome` itself.
class _RecenterOrEmpty extends ConsumerWidget {
  const _RecenterOrEmpty();

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
    return const RecenterButton();
  }
}
