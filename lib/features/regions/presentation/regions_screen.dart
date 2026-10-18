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
    return const Scaffold(
      body: SafeArea(
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

/// Top bar: the search field plus the sort-attribute menu and the
/// ascending/descending toggle (user request 2026-10-18).
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
          _SortMenuButton(),
        ],
      ),
    );
  }
}

/// Icon + popup menu to pick the sort attribute (Prozent / Gesamtkilometer /
/// Gefahrene Kilometer / Score). The active criterion is check-marked.
class _SortMenuButton extends ConsumerWidget {
  const _SortMenuButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(
      regionSortProvider.select((sort) => sort.criterion),
    );
    return PopupMenuButton<RegionSortCriterion>(
      icon: const Icon(Icons.sort),
      tooltip: 'Sortieren nach',
      initialValue: current,
      onSelected: (value) =>
          ref.read(regionSortProvider.notifier).criterion = value,
      itemBuilder: (context) => [
        for (final criterion in RegionSortCriterion.values)
          CheckedPopupMenuItem<RegionSortCriterion>(
            value: criterion,
            checked: criterion == current,
            child: Text(criterion.label),
          ),
      ],
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
    return ListView.builder(
      // Reserve space for the nav pill layered on top (Stack sibling), so the
      // last region card clears it instead of scrolling underneath.
      padding: const EdgeInsets.only(bottom: kBottomNavClearance),
      itemCount: list.length,
      itemBuilder: (context, i) {
        final region = list[i];
        return RegionCard(
          region: region,
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
