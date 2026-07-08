// Trailblazer Phase 4 rescope, Plan 04-16 (Wave 3):
// Riverpod providers for the admin-region lookup + runtime refresher.

import 'package:admin_geometry/admin_geometry.dart';
import 'package:auto_explore/core/prefs/app_prefs.dart';
import 'package:auto_explore/features/admin/data/admin_bundle_refresher.dart';
import 'package:auto_explore/features/admin/data/admin_region_lookup.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Singleton [AdminRegionLookup] — plain `Provider<T>` per STATE 01-01.
final adminRegionLookupProvider = Provider<AdminRegionLookup>(
  (ref) => AdminRegionLookup(),
);

/// Singleton [AdminBundleRefresher] used by
/// `Settings > Data > Refresh admin regions`.
final adminBundleRefresherProvider = Provider<AdminBundleRefresher>((ref) {
  final downloader = AdminPolygonDownloader();
  ref.onDispose(downloader.close);
  return AdminBundleRefresher(
    downloader: downloader,
    simplifier: const AdminPolygonSimplifier(),
    appPrefs: ref.watch(appPrefsProvider),
    lookup: ref.watch(adminRegionLookupProvider),
  );
});
