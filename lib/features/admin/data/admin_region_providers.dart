// Trailblazer Phase 4 rescope, Plan 04-16 (Wave 3):
// Riverpod providers for the admin-region lookup + runtime refresher.

import 'package:auto_explore/features/admin/data/admin_region_lookup.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Singleton [AdminRegionLookup] — plain `Provider<T>` per STATE 01-01.
final adminRegionLookupProvider = Provider<AdminRegionLookup>(
  (ref) => AdminRegionLookup(),
);
