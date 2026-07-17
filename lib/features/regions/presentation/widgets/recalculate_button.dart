// Trailblazer Phase 10, Plan 10-05:
// RecalculateButton — "Regionen neu berechnen" button for the Regions tab.
//
// UX (German throughout):
//  1. Tap → AlertDialog (confirmation, reuse DataManagementSection pattern).
//  2. Confirm → RecalculateCoverageAction.run() fires; button shows progress.
//  3. Done → snackbar "N Regionen aktualisiert"; progress resets to idle.
//  4. Error → snackbar "Fehler: …"; progress resets.
//  5. Button is disabled while running.
//
// Liquid-Glass-consistent: uses theme-standard FilledButton / OutlinedButton /
// CircularProgressIndicator. No custom glass layer needed at this control size.
//
// Rules observed:
//  - withValues(alpha:) only; never withOpacity().
//  - Package imports only.
//  - Plain Consumer (no ConsumerStatefulWidget needed — no local state to track;
//    progress is tracked via ValueListenableBuilder on the action's notifier).

import 'dart:async';

import 'package:auto_explore/features/regions/data/recalculate_coverage_action.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// "Regionen neu berechnen" button mounted at the top of the Regions screen.
///
/// Confirmation-gated: shows an [AlertDialog] before firing the heavy
/// rematch + recompute pipeline.
class RecalculateButton extends ConsumerWidget {
  const RecalculateButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final action = ref.watch(recalculateCoverageActionProvider);
    return ValueListenableBuilder<RecalculateProgress>(
      valueListenable: action.progressNotifier,
      builder: (context, progress, _) {
        return _RecalculateButtonContent(
          progress: progress,
          onTap: () => _onTap(context, ref, action),
        );
      },
    );
  }

  Future<void> _onTap(
    BuildContext context,
    WidgetRef ref,
    RecalculateCoverageAction action,
  ) async {
    if (action.isRunning) return;

    // Dismiss error/done state so the dialog can re-appear.
    action.reset();

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Regionen neu berechnen?'),
        content: const Text(
          'Alle gespeicherten Fahrten werden neu abgeglichen und die '
          'Regionen anschließend neu berechnet.\n\n'
          'Dies kann je nach Anzahl der Fahrten einige Minuten dauern. '
          'Fahrten werden dabei nicht gelöscht.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Neu berechnen'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;
    if (!context.mounted) return;

    final messenger = ScaffoldMessenger.of(context);

    final result = await action.run();

    if (!context.mounted) return;

    result.when(
      ok: (rowsWritten) {
        messenger.showSnackBar(
          SnackBar(
            content: Text('$rowsWritten Regionen aktualisiert'),
          ),
        );
        action.reset();
      },
      err: (error) {
        messenger.showSnackBar(
          SnackBar(
            content: Text('Fehler: $error'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
        action.reset();
      },
    );
  }
}

/// Stateless inner widget so [ValueListenableBuilder] can cheaply rebuild
/// only the button contents when progress changes.
class _RecalculateButtonContent extends StatelessWidget {
  const _RecalculateButtonContent({
    required this.progress,
    required this.onTap,
  });

  final RecalculateProgress progress;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final running = switch (progress) {
      RecalculateIdle() => false,
      RecalculateDone() => false,
      RecalculateError() => false,
      RecalculateRematching() => true,
      RecalculateRecomputing() => true,
    };

    final label = switch (progress) {
      RecalculateIdle() => 'Regionen neu berechnen',
      RecalculateDone() => 'Regionen neu berechnen',
      RecalculateError() => 'Regionen neu berechnen',
      RecalculateRematching(done: final d, total: final t) when t > 0 =>
        'Abgleich: $d/$t Fahrten …',
      RecalculateRematching() => 'Fahrten werden abgeglichen …',
      RecalculateRecomputing() => 'Regionen werden berechnet …',
    };

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: SizedBox(
        width: double.infinity,
        child: OutlinedButton.icon(
          onPressed: running ? null : onTap,
          icon: running
              ? SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: theme.colorScheme.primary.withValues(alpha: 0.8),
                  ),
                )
              : const Icon(Icons.refresh, size: 18),
          label: Text(label),
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            side: BorderSide(
              color: theme.colorScheme.outline.withValues(alpha: 0.5),
            ),
            foregroundColor: theme.colorScheme.onSurface.withValues(
              alpha: running ? 0.5 : 1.0,
            ),
          ),
        ),
      ),
    );
  }
}
