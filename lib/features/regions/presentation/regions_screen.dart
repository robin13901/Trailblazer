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
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            _SearchField(),
            const Divider(height: 1),
            const Expanded(child: _BrowserBody()),
          ],
        ),
      ),
    );
  }
}

class _SearchField extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: TextField(
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
          fillColor: theme.colorScheme.surfaceContainerHighest
              .withValues(alpha: 0.5),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        ),
        onChanged: (value) {
          ref.read(regionSearchQueryProvider.notifier).query = value;
        },
      ),
    );
  }
}

class _BrowserBody extends ConsumerWidget {
  const _BrowserBody();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ref.watch(regionBrowserProvider).when(
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

class _RegionList extends StatelessWidget {
  const _RegionList({required this.list, required this.searchQuery});

  final List<RegionCoverage> list;
  final String searchQuery;

  @override
  Widget build(BuildContext context) {
    if (list.isEmpty) {
      return _EmptyState(queryIsEmpty: searchQuery.trim().isEmpty);
    }
    return ListView.builder(
      itemCount: list.length,
      itemBuilder: (context, i) {
        final region = list[i];
        return RegionCard(
          region: region,
          onTap: () => showRegionDetailSheet(context, region),
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
