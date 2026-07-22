import 'package:auto_explore/features/coverage/presentation/coverage_overlay_bridge.dart';
import 'package:auto_explore/features/map/domain/follow_mode.dart';
import 'package:auto_explore/features/map/presentation/providers/camera_state_provider.dart';
import 'package:auto_explore/features/map/presentation/providers/location_permission_provider.dart';
import 'package:auto_explore/features/map/presentation/providers/region_outline_provider.dart';
import 'package:auto_explore/features/map/presentation/widgets/align_north_button.dart';
import 'package:auto_explore/features/map/presentation/widgets/bottom_nav_shell.dart';
import 'package:auto_explore/features/map/presentation/widgets/focus_area_pill.dart';
import 'package:auto_explore/features/map/presentation/widgets/live_trail_bridge.dart';
import 'package:auto_explore/features/map/presentation/widgets/map_widget.dart';
import 'package:auto_explore/features/map/presentation/widgets/permission_denial_banner.dart';
import 'package:auto_explore/features/map/presentation/widgets/recenter_button.dart';
import 'package:auto_explore/features/map/presentation/widgets/region_outline_bridge.dart';
import 'package:auto_explore/features/map/presentation/widgets/region_outline_dismiss_chip.dart';
import 'package:auto_explore/features/map/presentation/widgets/settings_glass_button.dart';
import 'package:auto_explore/features/map/presentation/widgets/tracking_camera_sync.dart';
import 'package:auto_explore/features/map/presentation/widgets/trip_fab.dart';
import 'package:auto_explore/features/map/presentation/widgets/trip_path_bridge.dart';
import 'package:auto_explore/features/map/presentation/widgets/trip_path_dismiss_chip.dart';
import 'package:auto_explore/features/regions/presentation/providers/region_sheet_open_provider.dart';
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
// Lowered from 12 → 4 (on-device feedback 2026-07-18): sits the nav pill + FAB
// row a little closer to the bottom safe-area edge. SafeArea still clears the
// home indicator, so 4 dp keeps a small breathing gap without floating high.
const double _navRowBottomInset = 4;

/// Top-chrome vertical inset from the safe-area top.
///
/// Plan 04-16-1 (2026-07-08 UX polish): mirrors [_navRowBottomInset] so the
/// settings button + focus pill sit the same distance below the status bar
/// as the bottom-nav pill sits above the system nav bar (was `top: 44`).
/// SafeArea already handles status-bar clearance; the extra 32 dp was
/// cosmetic and visually asymmetric.
const double _chromeRowTopInset = 12;

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
    // Hide the bottom nav pill while a region detail sheet is open so the
    // glass pill does not overlap the sheet card (on-device feedback
    // 2026-07-13).
    final regionSheetOpen = ref.watch(regionSheetOpenProvider);
    // Whether a region outline is currently drawn. The trip-path dismiss chip
    // normally sits at the SAME spot as the region-outline chip; only when an
    // outline is ALSO showing does it drop to the second row so the two don't
    // overlap (both can be visible at once). On-device feedback 2026-07-22.
    final outlineActive = ref.watch(regionOutlineProvider) != null;

    return Scaffold(
      // UI-06: no AppBar.
      body: Stack(
        children: [
          // Full-screen map — mounted ONLY while the Map tab is active. On
          // Trips/Regions the MapWidget is replaced by a cheap themed
          // placeholder so MapLibre's ~500 MB GL surface is released while the
          // map isn't visible (memory fix, 2026-07-10). The live camera is
          // persisted to cameraStateProvider on every idle, and MapWidget
          // seeds its initial position from it, so returning to the Map tab
          // restores the exact view (brief tile refetch aside).
          if (isMapTab)
            const Positioned.fill(child: MapWidget())
          else
            Positioned.fill(
              child: ColoredBox(color: Theme.of(context).colorScheme.surface),
            ),

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

          // Headless coverage overlay bridge: watches the style-load tick,
          // coverage data, and preset — drives the MapLibre GeoJSON source +
          // line layer via CoverageOverlayApplier. Placed OUTSIDE the
          // isMapTab block so it persists across tab switches and keeps
          // listening while the user browses Trips / Regions. Zero-size
          // Positioned mirrors the TrackingCameraSync placement so it
          // does not size the Stack or intercept hit-tests.
          const Positioned(
            top: 0,
            left: 0,
            width: 0,
            height: 0,
            child: CoverageOverlayBridge(),
          ),

          // Headless live dashed-trail bridge: paints the raw driven GPS path
          // as a dashed line while recording (provisional feedback), removed on
          // stop so the solid post-trip matched coverage takes over. Zero-size
          // Positioned OUTSIDE the isMapTab block so it keeps accumulating the
          // trail even if the user browses another tab mid-drive.
          //
          // The line is drawn ONE FIX BEHIND the true position so its tip
          // coincides with the native MapLibre puck (which follows closely but
          // slightly behind its own cadence) — a single visible dot at the tip.
          const Positioned(
            top: 0,
            left: 0,
            width: 0,
            height: 0,
            child: LiveTrailBridge(),
          ),

          // Headless region-outline bridge: draws the actual boundary of a
          // region the user picked via "Auf Karte anzeigen" (dashed neutral
          // border + faint fill), dismissed by the on-map X chip. Zero-size
          // Positioned OUTSIDE the isMapTab block so it re-adds correctly after
          // the map remounts on the return to the Map tab.
          const Positioned(
            top: 0,
            left: 0,
            width: 0,
            height: 0,
            child: RegionOutlineBridge(),
          ),

          // Headless trip-path bridge: draws the on-road line of a trip the
          // user picked via "Auf Karte anzeigen" in the trip detail sheet,
          // in a distinct turquoise (NOT a coverage preset color), dismissed
          // by the trip X chip. Zero-size Positioned OUTSIDE the isMapTab
          // block so it re-adds correctly after the map remounts on return
          // to the Map tab (same pattern as RegionOutlineBridge).
          const Positioned(
            top: 0,
            left: 0,
            width: 0,
            height: 0,
            child: TripPathBridge(),
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

            // Top-left settings button — sits _chromeRowTopInset below the
            // safe-area top, mirroring the bottom-nav pill's inset from the
            // safe-area bottom (Plan 04-16-1).
            Positioned(
              top: _chromeRowTopInset,
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

            // Top-center focus-area pill stub — same top inset as the
            // settings button for symmetry (Plan 04-16-1).
            const Positioned(
              top: _chromeRowTopInset,
              left: 0,
              right: 0,
              child: SafeArea(child: Center(child: FocusAreaPill())),
            ),

            // Region-outline dismiss chip — centered just below the focus pill.
            // Only visible while a region boundary is drawn on the map (the
            // chip renders nothing otherwise). Tapping it clears the outline.
            //
            // 56 dp clears the pill's height; the extra +12 (matching the
            // chrome gap used elsewhere) keeps a small breathing gap so the
            // chip doesn't sit flush against the pill (on-device feedback
            // 2026-07-21).
            const Positioned(
              top: _chromeRowTopInset + 56 + _chromeGap,
              left: 0,
              right: 0,
              child: SafeArea(child: Center(child: RegionOutlineDismissChip())),
            ),

            // Trip-path dismiss chip — sits at the SAME position as the region
            // chip (on-device feedback 2026-07-22). Only when a region outline
            // is ALSO shown does it drop one chip-row (~40 dp + a gap) so the
            // two chips don't overlap; both can be visible at once (a trip line
            // and a region outline can be drawn together).
            Positioned(
              top: outlineActive
                  ? _chromeRowTopInset + 56 + _chromeGap + 40 + _chromeGap
                  : _chromeRowTopInset + 56 + _chromeGap,
              left: 0,
              right: 0,
              child: const SafeArea(child: Center(child: TripPathDismissChip())),
            ),

            // Top-right glass align-north button — mirrors the top-left
            // settings button (Plan 04-19). The built-in MapLibre compass
            // was disabled in MapWidget; this custom glass button owns the
            // top-right corner now. Icon rotates counter to the map
            // bearing so it always points to true north.
            const Positioned(
              top: _chromeRowTopInset,
              right: 16,
              child: SafeArea(child: AlignNorthButton()),
            ),
          ],

          // Bottom chrome — nav pill + FAB + (optional) recenter, all in
          // a single Column so their positions are structurally guaranteed
          // to line up (identical Row structure on each line).
          //
          // Hidden entirely while a region detail sheet is open so the glass
          // nav pill does not overlap the sheet card (2026-07-13).
          if (!regionSheetOpen)
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
                            overMap: isMapTab,
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
