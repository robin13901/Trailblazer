// Trailblazer Phase 8, Plan 08-05 (Wave 2):
// RegionsScreen — replaces the Phase-8 placeholder with the live region
// browser: a search field + lazy ListView of RegionCards sorted % descending.
//
// Spec (CONTEXT.md + Plan 08-05):
//   - No AppBar — renders inside the map shell Stack (opaque Scaffold masks map).
//   - Search TextField at top, bound to regionSearchQueryProvider.
//   - Body: regionBrowserProvider.when(loading, error, data)
//     → regionBrowserFilteredProvider → ListView.builder of RegionCard.
//   - Empty states: no coverage → "Noch keine befahrenen Regionen";
//     no search hits → "Keine Treffer".
//   - withValues(alpha:) only; package imports only.

import 'package:auto_explore/features/map/presentation/widgets/bottom_nav_shell.dart';
import 'package:auto_explore/features/regions/domain/region_coverage.dart';
import 'package:auto_explore/features/regions/presentation/providers/region_browser_provider.dart';
import 'package:auto_explore/features/regions/presentation/widgets/region_card.dart';
import 'package:auto_explore/features/regions/presentation/widgets/region_detail_sheet.dart';
import 'package:auto_explore/features/regions/presentation/widgets/sort_menu.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The Regions browser tab.
///
/// No AppBar — this screen renders inside the map shell stack when the Regions
/// tab is active. The opaque Scaffold background masks the base map. Chrome
/// (focus pill, settings button, FAB) is hidden on this tab.
class RegionsScreen extends ConsumerWidget {
  const RegionsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // `bottom: false` lets the list scroll all the way to the physical bottom
    // edge (under the floating nav pill, iOS-style) instead of stopping at the
    // home-indicator inset — the list's own bottom padding keeps the last card
    // clear of the pill (see _RegionList). This removes the dead strip the user
    // reported below the last row (2026-10-18).
    return const Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _SearchBar(),
            Divider(height: 1),
            Expanded(child: _BrowserBody()),
          ],
        ),
      ),
    );
  }
}

/// Top bar: the search field plus the ascending/descending toggle and the
/// glass sort-attribute menu (user request 2026-10-18).
class _SearchBar extends StatelessWidget {
  const _SearchBar();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Expanded(child: _SearchField()),
          SizedBox(width: 4),
          _SortDirectionButton(),
          SortMenuButton(),
        ],
      ),
    );
  }
}

/// Toggle button whose arrow flips the sort direction: down = descending
/// (highest first), up = ascending (lowest first).
class _SortDirectionButton extends ConsumerWidget {
  const _SortDirectionButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final descending = ref.watch(
      regionSortProvider.select((sort) => sort.descending),
    );
    return IconButton(
      icon: Icon(descending ? Icons.arrow_downward : Icons.arrow_upward),
      tooltip: descending ? 'Absteigend' : 'Aufsteigend',
      onPressed: () => ref.read(regionSortProvider.notifier).toggleDirection(),
    );
  }
}

class _SearchField extends ConsumerStatefulWidget {
  const _SearchField();

  @override
  ConsumerState<_SearchField> createState() => _SearchFieldState();
}

class _SearchFieldState extends ConsumerState<_SearchField> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Keep the visible text in sync when the provider is reset externally
    // (e.g. the search is cleared on leaving the Regions tab). Only write to
    // the controller when the value actually differs to avoid feedback loops
    // and cursor jumps caused by our own onChanged writes.
    ref.listen<String>(regionSearchQueryProvider, (previous, next) {
      if (_controller.text != next) {
        _controller.text = next;
      }
    });
    return TextField(
      controller: _controller,
      textCapitalization: TextCapitalization.words,
      decoration: InputDecoration(
        hintText: 'Region suchen …',
        prefixIcon: const Icon(Icons.search),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(
            color: theme.colorScheme.outline.withValues(alpha: 0.5),
          ),
        ),
        filled: true,
        fillColor: theme.colorScheme.surfaceContainerHighest.withValues(
          alpha: 0.5,
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 10,
        ),
      ),
      onChanged: (value) {
        ref.read(regionSearchQueryProvider.notifier).query = value;
      },
    );
  }
}

class _BrowserBody extends ConsumerWidget {
  const _BrowserBody();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ref
        .watch(regionBrowserProvider)
        .when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => _ErrorBody(message: '$e'),
          data: (_) {
            // Use the filtered provider; it reads regionBrowserProvider
            // from cache, so no extra async hop.
            final list = ref.watch(regionBrowserFilteredProvider);
            final query = ref.watch(regionSearchQueryProvider);
            return _RegionList(list: list, searchQuery: query);
          },
        );
  }
}

class _RegionList extends ConsumerWidget {
  const _RegionList({required this.list, required this.searchQuery});

  final List<RegionCoverage> list;
  final String searchQuery;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (list.isEmpty) {
      return _EmptyState(queryIsEmpty: searchQuery.trim().isEmpty);
    }
    final criterion = ref.watch(
      regionSortProvider.select((sort) => sort.criterion),
    );
    // With the Scaffold's `SafeArea(bottom: false)` the list extends to the
    // physical bottom edge, so the pill clearance must also cover the
    // home-indicator inset (previously handled by SafeArea). The last card
    // still parks just above the floating pill.
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    return ListView.builder(
      padding: EdgeInsets.only(bottom: kBottomNavClearance + bottomInset),
      itemCount: list.length,
      itemBuilder: (context, i) {
        final region = list[i];
        return RegionCard(
          region: region,
          // Show the score (one decimal) when sorting by score, else the %.
          trailingText: criterion == RegionSortCriterion.score
              ? region.scoreLabel
              : null,
          onTap: () => showRegionDetailSheet(context, ref, region),
        );
      },
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.queryIsEmpty});

  final bool queryIsEmpty;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final message = queryIsEmpty
        ? 'Noch keine befahrenen Regionen.\nFahre eine Strecke, um Regionen zu sehen.'
        : 'Keine Treffer für diese Suche.';
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          message,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
          ),
        ),
      ),
    );
  }
}

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
          'Regionen konnten nicht geladen werden.\n$message',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.error,
          ),
        ),
      ),
    );
  }
}
