// Trailblazer undriven-ways overlay: fetch-progress provider.
//
// Mirrors globalRecalcProgressProvider but scoped to the on-demand undriven
// overlay so its banner carries its own German label and never collides with
// the one-shot startup migration banner. Null when idle.
//
// Plain Notifier — no @Riverpod codegen (STATE 01-01).

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Immutable N/M tile-fetch snapshot for the undriven overlay.
@immutable
class UndrivenFetchProgress {
  const UndrivenFetchProgress({required this.done, required this.total});

  final int done;
  final int total;

  @override
  bool operator ==(Object other) =>
      other is UndrivenFetchProgress &&
      other.done == done &&
      other.total == total;

  @override
  int get hashCode => Object.hash(done, total);
}

/// Holds the current undriven-overlay fetch progress, or null when idle.
class UndrivenFetchProgressNotifier extends Notifier<UndrivenFetchProgress?> {
  @override
  UndrivenFetchProgress? build() => null;

  /// Update the N/M tile count. Fed by the `onTileProgress` callback of the
  /// read-only `fetchWaysInBbox` call.
  void update(int done, int total) {
    state = UndrivenFetchProgress(done: done, total: total);
  }

  /// Clear the banner — the fetch finished (or had nothing to fetch).
  void clear() => state = null;
}

/// Progress of the on-demand undriven-ways tile fetch. Null when idle.
final undrivenFetchProgressProvider =
    NotifierProvider<UndrivenFetchProgressNotifier, UndrivenFetchProgress?>(
      UndrivenFetchProgressNotifier.new,
    );
