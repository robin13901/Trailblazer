// Trailblazer region-outline overlay:
// regionOutlineProvider — holds the AdminRegion whose boundary is currently
// drawn on the map (or null when no outline is shown).
//
// Set by RegionDetailSheet's "Auf Karte anzeigen" handler (show) and cleared by
// the on-map dismiss chip (clear). Watched by RegionOutlineBridge, which drives
// the MapLibre fill + dashed-line layers via RegionOutlineApplier.
//
// The AdminRegion is held directly (it is already immutable and carries the
// full MultiPolygon geometry) so the bridge does not re-look-up the region.
//
// Plain NotifierProvider — no @Riverpod codegen (STATE 01-01).

import 'package:auto_explore/features/admin/data/admin_region.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Holds the region currently outlined on the map, or `null` when none.
class RegionOutlineNotifier extends Notifier<AdminRegion?> {
  @override
  AdminRegion? build() => null;

  /// Show [region]'s boundary on the map. Replaces any currently-shown outline.
  // ignore: use_setters_to_change_properties — semantic "show" verb, not a setter
  void show(AdminRegion region) => state = region;

  /// Clear the outline (dismiss chip tap). Idempotent.
  void clear() => state = null;
}

/// The [AdminRegion] whose boundary is drawn on the map, or `null`.
final regionOutlineProvider =
    NotifierProvider<RegionOutlineNotifier, AdminRegion?>(
  RegionOutlineNotifier.new,
);
