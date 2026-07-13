// Trailblazer Phase 6, Plan 06-06 Task 2:
// DebugExportButton — a kDebugMode-only FAB that exports the current trip as a
// golden-corpus fixture.
//
// **Release-build discipline (kDebugMode):** the widget short-circuits to
// `SizedBox.shrink()` in release/profile builds, and the exporter provider is
// only ever read from the debug branch. `kDebugMode` is a compile-time const,
// so the tree-shaker drops the exporter graph from release binaries — no
// golden-export surface ships to end users. In `flutter test`, `kDebugMode` is
// true, so the widget renders and is testable.
//
// Wired into TripDetailScreen as its `floatingActionButton`.

import 'package:auto_explore/core/db/app_database_providers.dart';
import 'package:auto_explore/core/db/daos/driven_way_intervals_dao.dart';
import 'package:auto_explore/core/errors/domain_error.dart';
import 'package:auto_explore/features/matching/data/matching_providers.dart';
import 'package:auto_explore/features/trips/data/golden_fixture_exporter.dart';
import 'package:auto_explore/features/trips/data/trips_repository_providers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Debug-only golden-fixture exporter provider.
///
/// Co-located with the button so the tree-shaker's reachability analysis keeps
/// the exporter out of release builds (the only reader is the kDebugMode
/// branch of [DebugExportButton]). Uses the runtime `WayCandidateSource`
/// (`wayCandidateSourceProvider`) so the exported `ways.json.gz` captures the
/// RAW bbox ways — the same input the matcher's corridor filter starts from.
final goldenFixtureExporterProvider = Provider<GoldenFixtureExporter>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return GoldenFixtureExporter(
    tripsDao: ref.watch(tripsDaoProvider),
    waySource: ref.watch(wayCandidateSourceProvider),
    intervalsDao: DrivenWayIntervalsDao(db),
  );
});

/// A debug-only FAB attached to `TripDetailScreen`. Prompts for a slug, runs
/// [GoldenFixtureExporter.export], and surfaces the output path (or error) in
/// a SnackBar.
class DebugExportButton extends ConsumerWidget {
  const DebugExportButton({required this.tripId, super.key});

  final int tripId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!kDebugMode) return const SizedBox.shrink();
    return FloatingActionButton.extended(
      heroTag: 'export_fixture_$tripId',
      onPressed: () => _prompt(context, ref),
      icon: const Icon(Icons.save_alt_outlined),
      label: const Text('Fixture exportieren'),
    );
  }

  Future<void> _prompt(BuildContext context, WidgetRef ref) async {
    final slug = await showDialog<String>(
      context: context,
      builder: (_) => const _SlugPromptDialog(),
    );
    if (slug == null || slug.isEmpty) return;
    if (!context.mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    try {
      final path = await ref
          .read(goldenFixtureExporterProvider)
          .export(tripId: tripId, slug: slug);
      messenger.showSnackBar(
        SnackBar(content: Text('Exportiert nach $path')),
      );
    } on DomainError catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Export fehlgeschlagen: ${e.message}')),
      );
    }
  }
}

/// Simple slug-entry dialog. Returns the trimmed slug, or null on cancel.
class _SlugPromptDialog extends StatefulWidget {
  const _SlugPromptDialog();

  @override
  State<_SlugPromptDialog> createState() => _SlugPromptDialogState();
}

class _SlugPromptDialogState extends State<_SlugPromptDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Golden-Fixture exportieren'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: const InputDecoration(
          labelText: 'Fixture-Slug',
          hintText: 'z. B. 002_kleinheubach_roundabout',
        ),
        onSubmitted: (value) => Navigator.of(context).pop(value.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Abbrechen'),
        ),
        TextButton(
          onPressed: () =>
              Navigator.of(context).pop(_controller.text.trim()),
          child: const Text('Speichern'),
        ),
      ],
    );
  }
}
