// Trailblazer Phase 6, Plan 06-05 Task 2:
// TripsScreen — the Trips tab, sub-tabbed into Inbox (pending/matched) and
// History (confirmed + in-flight). Replaces the Phase-3 placeholder.
//
// Above the tabs: MatchingQueuePill (visible only when in-flight count > 0).
// Landing tab: Inbox when pending trips exist on first snapshot, else History
// (guarded by `_initialTabResolved` so later list updates never force-jump).
//
// Thumbnail overlay entry (06-03 hand-off): an offstage MapLibreMap is hosted
// here so its controller can drive `ThumbnailRenderer`'s snapshot path. The
// overlay widget is injected via `tripsThumbnailOverlayProvider` so tests can
// override it with a no-op and skip MapLibre platform instantiation.

import 'package:auto_explore/features/map/presentation/providers/map_style_provider.dart';
import 'package:auto_explore/features/trips/domain/trip_list_item.dart';
import 'package:auto_explore/features/trips/presentation/providers/inbox_providers.dart';
import 'package:auto_explore/features/trips/presentation/widgets/history_empty_state.dart';
import 'package:auto_explore/features/trips/presentation/widgets/history_row.dart';
import 'package:auto_explore/features/trips/presentation/widgets/inbox_empty_state.dart';
import 'package:auto_explore/features/trips/presentation/widgets/matching_queue_pill.dart';
import 'package:auto_explore/features/trips/presentation/widgets/trip_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

/// Holds the offstage thumbnail-map controller once MapLibre creates it.
///
/// Populated by [_ThumbnailOverlayMap] in production. Consumed by a future
/// snapshot-path wiring (06-03 hand-off); the fallback renderer works without
/// it, so a null controller is a safe no-op.
///
/// Plain [Notifier] — no `@Riverpod` codegen (STATE.md Plan 01-01 decision);
/// `StateProvider` is not part of the flutter_riverpod 3.x public surface.
class TripsThumbnailController extends Notifier<MapLibreMapController?> {
  @override
  MapLibreMapController? build() => null;

  // Single-line state setter — the getter/setter lint pair prefers a plain
  // method here since the field is write-only from the map callback.
  // ignore: use_setters_to_change_properties
  void set(MapLibreMapController controller) => state = controller;
}

final tripsThumbnailControllerProvider =
    NotifierProvider<TripsThumbnailController, MapLibreMapController?>(
  TripsThumbnailController.new,
);

/// Builds the offstage MapLibreMap overlay used for thumbnail snapshots.
///
/// Tests override this with `const SizedBox.shrink()` to skip MapLibre
/// platform instantiation (which would throw MissingPluginException in a
/// unit-test environment).
final tripsThumbnailOverlayProvider = Provider<Widget>((ref) {
  return const _ThumbnailOverlayMap();
});

/// The Trips tab: Inbox / History sub-tabs + matcher-queue pill.
class TripsScreen extends ConsumerStatefulWidget {
  const TripsScreen({super.key});

  @override
  ConsumerState<TripsScreen> createState() => _TripsScreenState();
}

class _TripsScreenState extends ConsumerState<TripsScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tab;
  bool _initialTabResolved = false;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  /// Resolve the landing tab from the first inbox snapshot: Inbox when pending
  /// trips exist, else History. Runs at most once (guarded).
  void _resolveInitialTab(List<TripListItem> inbox) {
    if (_initialTabResolved) return;
    _initialTabResolved = true;
    final targetIndex = inbox.isNotEmpty ? 0 : 1;
    if (_tab.index != targetIndex) {
      // Defer to after the current build to avoid mutating during build.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _tab.index = targetIndex;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // Resolve landing tab on first inbox data.
    ref.watch(inboxTripsProvider).whenData(_resolveInitialTab);

    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            Column(
              children: [
                const MatchingQueuePill(),
                TabBar(
                  controller: _tab,
                  tabs: const [
                    Tab(text: 'Inbox'),
                    Tab(text: 'History'),
                  ],
                ),
                Expanded(
                  child: TabBarView(
                    controller: _tab,
                    children: const [
                      _InboxTab(),
                      _HistoryTab(),
                    ],
                  ),
                ),
              ],
            ),
            // Offstage thumbnail-render map (0x0 visual footprint).
            ref.watch(tripsThumbnailOverlayProvider),
          ],
        ),
      ),
    );
  }
}

/// Inbox tab body — matched trips awaiting Keep/Discard.
class _InboxTab extends ConsumerWidget {
  const _InboxTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final inbox = ref.watch(inboxTripsProvider);
    return inbox.when(
      data: (items) {
        if (items.isEmpty) return const InboxEmptyState();
        return ListView.builder(
          itemCount: items.length,
          itemBuilder: (context, i) => TripCard(item: items[i]),
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => _ErrorBody(message: '$e'),
    );
  }
}

/// History tab body — confirmed + in-flight trips (never rejected — CONTEXT).
class _HistoryTab extends ConsumerWidget {
  const _HistoryTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(historyTripsProvider);
    return history.when(
      data: (items) {
        if (items.isEmpty) return const HistoryEmptyState();
        return ListView.builder(
          itemCount: items.length,
          itemBuilder: (context, i) => HistoryRow(item: items[i]),
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => _ErrorBody(message: '$e'),
    );
  }
}

/// DomainError-aware error body for the tab views.
class _ErrorBody extends StatelessWidget {
  const _ErrorBody({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          'Could not load trips.\n$message',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.error,
          ),
        ),
      ),
    );
  }
}

/// Offstage 320x120 MapLibreMap whose controller feeds the thumbnail renderer.
///
/// `Offstage(offstage: true, …)` keeps it out of the visible layout while
/// still instantiating the platform view so `takeSnapshot` has a live map.
class _ThumbnailOverlayMap extends ConsumerWidget {
  const _ThumbnailOverlayMap();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final styleUrl = ref.watch(mapStyleUrlProvider);
    return Offstage(
      child: SizedBox(
        width: 320,
        height: 120,
        child: MapLibreMap(
          styleString: styleUrl,
          initialCameraPosition: const CameraPosition(
            target: LatLng(51.16, 10.45), // Germany centroid
            zoom: 5,
          ),
          onMapCreated: (c) =>
              ref.read(tripsThumbnailControllerProvider.notifier).set(c),
        ),
      ),
    );
  }
}
