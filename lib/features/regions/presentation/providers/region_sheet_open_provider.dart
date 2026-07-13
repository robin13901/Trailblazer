// Trailblazer 2026-07-13:
// regionSheetOpenProvider — true while the region detail bottom sheet is
// presented. MapScreen watches this and hides the bottom nav pill so the
// glass pill does not overlap the sheet's card (on-device feedback).

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Whether the region detail bottom sheet is currently open.
class RegionSheetOpenNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  /// Whether the sheet is currently open.
  bool get isOpen => state;

  /// Open (`true`) or close (`false`) the region detail sheet flag.
  set isOpen(bool open) => state = open;
}

final regionSheetOpenProvider =
    NotifierProvider<RegionSheetOpenNotifier, bool>(
  RegionSheetOpenNotifier.new,
);
