// Trailblazer Phase 9, Plan 09-03:
// Settings > GPS section — raw-GPS retention window picker (SET-05).

import 'dart:async';

import 'package:auto_explore/core/prefs/app_prefs.dart';
import 'package:auto_explore/features/trips/data/trips_repository_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// A settings section that lets the user choose how long raw GPS points are
/// kept after a trip has been matched to roads (SET-05).
///
/// Options:
///   - 0     → "Delete after matching"
///   - 30    → "30 days" (default)
///   - 365   → "1 year"
///   - null  → "Forever" (no automatic deletion)
///
/// Shortening the window triggers a confirmation dialog before persisting and
/// immediately purging now-expired points via sweepRawGpsRetention.
/// Lengthening or choosing "Forever" persists silently with no purge.
class RawGpsRetentionSection extends ConsumerStatefulWidget {
  const RawGpsRetentionSection({super.key});

  @override
  ConsumerState<RawGpsRetentionSection> createState() =>
      _RawGpsRetentionSectionState();
}

class _RawGpsRetentionSectionState
    extends ConsumerState<RawGpsRetentionSection> {
  /// Current selection. Null until loaded; null value (once loaded) means
  /// "Forever".
  int? _selected;

  /// Whether the initial async load has completed.
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadInitial());
  }

  Future<void> _loadInitial() async {
    final days = await ref.read(appPrefsProvider).getRawGpsRetentionDays();
    if (!mounted) return;
    setState(() {
      _selected = days;
      _loaded = true;
    });
  }

  // ── Ordering helpers ──────────────────────────────────────────────────────

  /// Rank of a retention value in ascending "how much data is deleted" order.
  ///
  /// Higher rank = more data retained = "longer" window.
  ///   null (forever)  → 3 (most data retained)
  ///   365             → 2
  ///   30              → 1
  ///   0               → 0 (least data retained)
  static int _rank(int? days) {
    if (days == null) return 3;
    if (days >= 365) return 2;
    if (days >= 30) return 1;
    return 0; // 0-day
  }

  /// Returns true when [newDays] keeps less data than [oldDays].
  static bool _isShorter(int? newDays, int? oldDays) =>
      _rank(newDays) < _rank(oldDays);

  // ── Selection handling ────────────────────────────────────────────────────

  Future<void> _onSelect(int? choice) async {
    if (!_loaded) return;
    final previous = _selected;
    if (choice == previous) return;

    // Optimistically update the radio to give instant UI feedback.
    setState(() => _selected = choice);

    if (_isShorter(choice, previous)) {
      // Shortening: ask the user to confirm and purge.
      final confirmed = await _showPurgeConfirm(choice);
      if (!confirmed) {
        // Reverted — restore previous selection without persisting.
        if (mounted) setState(() => _selected = previous);
        return;
      }
      if (!mounted) return;
    }

    // Persist the new window.
    await ref.read(appPrefsProvider).setRawGpsRetentionDays(choice);

    if (!mounted) return;

    if (_isShorter(choice, previous)) {
      // Purge immediately after confirmation.
      final messenger = ScaffoldMessenger.of(context);
      final result =
          await ref.read(tripsRepositoryProvider).sweepRawGpsRetention(
                retention: Duration(days: choice ?? 0),
              );
      if (!mounted) return;
      result.when(
        ok: (n) => messenger.showSnackBar(
          SnackBar(
            content: Text(
              n == 0
                  ? 'No GPS points to purge.'
                  : 'Purged raw GPS points for $n older trip${n == 1 ? '' : 's'}.',
            ),
          ),
        ),
        err: (e) => messenger.showSnackBar(
          SnackBar(content: Text('Purge failed: $e')),
        ),
      );
    }
  }

  /// Shows a confirmation dialog before shortening the retention window.
  ///
  /// Returns `true` when the user confirms; `false` when they cancel.
  Future<bool> _showPurgeConfirm(int? newDays) async {
    final windowLabel = _labelFor(newDays);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Purge older GPS points now?'),
        content: Text(
          newDays == 0
              ? 'All raw location points from matched trips will be deleted. '
                  'Matched roads are unaffected.'
              : 'Raw location points for trips older than $windowLabel will be '
                  'deleted. Matched roads are unaffected.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Purge'),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  // ── Display helpers ───────────────────────────────────────────────────────

  String _labelFor(int? days) {
    if (days == null) return 'Forever';
    if (days == 0) return 'After matching';
    if (days == 365) return '1 year';
    return '$days days';
  }

  String _subtitleFor(int? days) {
    if (days == null) return 'Points are never deleted automatically.';
    if (days == 0) return 'Points deleted once the trip is matched to roads.';
    if (days == 365) return 'Points older than 1 year are deleted on resume.';
    return 'Points older than $days days are deleted on resume.';
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    // The four user-facing options in rank order (ascending data retention).
    const options = <int?>[0, 30, 365, null];

    if (!_loaded) {
      return const ListTile(
        title: Text('Raw GPS retention'),
        subtitle: Text('Loading…'),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const ListTile(
          title: Text('Raw GPS retention'),
          subtitle: Text(
            'How long raw location points are kept after a trip is matched '
            'to roads. Matched roads are unaffected by this setting.',
          ),
        ),
        RadioGroup<int?>(
          groupValue: _selected,
          onChanged: _onSelect,
          child: Column(
            children: options
                .map(
                  (days) => RadioListTile<int?>(
                    title: Text(_labelFor(days)),
                    subtitle: Text(_subtitleFor(days)),
                    value: days,
                  ),
                )
                .toList(),
          ),
        ),
      ],
    );
  }
}
