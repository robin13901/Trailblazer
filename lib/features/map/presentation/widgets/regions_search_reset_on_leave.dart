import 'package:auto_explore/features/regions/presentation/providers/region_browser_provider.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Branch index of the Regions tab in the `StatefulShellRoute.indexedStack`.
const int _kRegionsBranchIndex = 2;

/// Headless widget: no visible UI. Watches the active shell branch index and
/// clears [regionSearchQueryProvider] whenever the user LEAVES the Regions
/// tab (branch 2 → anything else).
///
/// The Regions search query lives in a session-global provider and the search
/// TextField is uncontrolled inside a `StatefulShellRoute.indexedStack`, so
/// both otherwise survive tab switches. Resetting the provider on leave — and
/// the paired `ref.listen` in `_SearchField` that mirrors the reset onto its
/// `TextEditingController` — gives the user a clean, empty search + full region
/// list on the next visit.
///
/// The previous index is remembered across rebuilds in [State] and compared in
/// `didUpdateWidget`, which fires when `MapScreen` rebuilds with a new
/// [currentIndex] after `goBranch`. This is the same zero-size-`Positioned`
/// headless-sync pattern used by `TrackingCameraSync`.
class RegionsSearchResetOnLeave extends ConsumerStatefulWidget {
  const RegionsSearchResetOnLeave({required this.currentIndex, super.key});

  /// The active shell branch index (from `StatefulNavigationShell`).
  final int currentIndex;

  @override
  ConsumerState<RegionsSearchResetOnLeave> createState() =>
      _RegionsSearchResetOnLeaveState();
}

class _RegionsSearchResetOnLeaveState
    extends ConsumerState<RegionsSearchResetOnLeave> {
  @override
  void didUpdateWidget(RegionsSearchResetOnLeave oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Leaving the Regions tab: previous branch was Regions, next is not.
    final left = oldWidget.currentIndex == _kRegionsBranchIndex &&
        widget.currentIndex != _kRegionsBranchIndex;
    if (!left) return;
    // Defer the provider write out of the build/lifecycle phase — Riverpod
    // forbids modifying a provider inside `didUpdateWidget` (it could desync
    // two listeners mid-frame). A post-frame callback runs it safely once the
    // tree has finished building; guard `mounted` since we hop a frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(regionSearchQueryProvider.notifier).clear();
    });
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
