// Trailblazer Phase 6, Plan 06-05 Task 1:
// DiscardConfirmationDialog — the confirm-before-discard modal.
//
// Shown only on Discard (Keep is silent, no modal — CONTEXT "confirm-before
// -discard"). The copy calls out that raw GPS is deleted and the action is
// permanent, because Discard is a hard delete with no undo.

import 'package:flutter/material.dart';

/// Confirmation modal for the Discard action.
///
/// Returns `true` when the user confirms the discard, `false` (or `null`,
/// coalesced to `false` by callers) when they cancel or dismiss.
///
/// Usage:
/// ```dart
/// final confirmed = await DiscardConfirmationDialog.show(context);
/// if (confirmed) { ... }
/// ```
class DiscardConfirmationDialog extends StatelessWidget {
  const DiscardConfirmationDialog({super.key});

  /// Present the dialog and resolve to the user's decision.
  ///
  /// Coalesces a barrier-dismiss (`null`) to `false` so callers always get a
  /// concrete bool.
  static Future<bool> show(BuildContext context) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (_) => const DiscardConfirmationDialog(),
    );
    return result ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('Diese Fahrt verwerfen?'),
      content: const Text(
        'Roh-GPS-Daten werden gelöscht und die Abdeckung neu berechnet. '
        'Dies kann nicht rückgängig gemacht werden.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Abbrechen'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(true),
          style: TextButton.styleFrom(
            foregroundColor: theme.colorScheme.error,
          ),
          child: const Text('Verwerfen'),
        ),
      ],
    );
  }
}
