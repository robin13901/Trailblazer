// Trailblazer Phase 6, Plan 06-02 Task 1 tests:
// TripPlaceLookup — level-8 preferred, level-10 fallback, null-null null.

import 'package:auto_explore/features/admin/data/admin_region.dart';
import 'package:auto_explore/features/admin/data/admin_region_lookup.dart';
import 'package:auto_explore/features/trips/domain/trip_place_lookup.dart';
import 'package:flutter_test/flutter_test.dart';

/// Fake lookup keyed by `(lat, lon, level)` — returns the pre-canned
/// region or null. Real-world coords are unused: the fake matches on
/// the tuple in [byPoint]. If no key is registered for a `(lat, lon)`
/// pair, the fake falls back to a level-only default in [byLevel].
class _FakeAdminRegionLookup implements AdminRegionLookup {
  _FakeAdminRegionLookup({
    this.byPoint = const {},
    this.byLevel = const {},
  });

  /// (lat, lon, level) → region (or null explicitly to force miss).
  final Map<(double, double, int), AdminRegion?> byPoint;

  /// Fallback per level when no `byPoint` entry matches.
  final Map<int, AdminRegion?> byLevel;

  int calls = 0;

  @override
  Future<AdminRegion?> regionAt(double lat, double lon, int adminLevel) async {
    calls++;
    final key = (lat, lon, adminLevel);
    if (byPoint.containsKey(key)) return byPoint[key];
    return byLevel[adminLevel];
  }

  @override
  Future<void> ensureLoaded() async {}

  @override
  void invalidate() {}

  @override
  int get regionCount => 0;

  @override
  int get bundleLoadCount => 0;
}

AdminRegion _region(int osmId, int level, String name) => AdminRegion(
      osmId: osmId,
      adminLevel: level,
      name: name,
      bboxMinLat: 0,
      bboxMinLon: 0,
      bboxMaxLat: 0,
      bboxMaxLon: 0,
      polygons: const [],
    );

void main() {
  group('TripPlaceLookup.lookup', () {
    test(
      'level-8 hit on both endpoints — same region → isLoop == true',
      () async {
        final lookup = TripPlaceLookup(
          _FakeAdminRegionLookup(
            byLevel: {
              8: _region(62422, 8, 'Miltenberg'),
            },
          ),
        );

        final places = await lookup.lookup(
          startLat: 49.79,
          startLon: 9.18,
          endLat: 49.80,
          endLon: 9.20,
        );

        expect(places.startName, 'Miltenberg');
        expect(places.endName, 'Miltenberg');
        expect(places.isLoop, isTrue);
      },
    );

    test(
      'level-8 hit on both endpoints — distinct regions → distinct names',
      () async {
        final start = _region(1, 8, 'Miltenberg');
        final end = _region(2, 8, 'Aschaffenburg');
        final lookup = TripPlaceLookup(
          _FakeAdminRegionLookup(
            byPoint: {
              (49.79, 9.18, 8): start,
              (50.0, 9.15, 8): end,
            },
          ),
        );

        final places = await lookup.lookup(
          startLat: 49.79,
          startLon: 9.18,
          endLat: 50,
          endLon: 9.15,
        );

        expect(places.startName, 'Miltenberg');
        expect(places.endName, 'Aschaffenburg');
        expect(places.isLoop, isFalse);
      },
    );

    test(
      'level-8 miss, level-10 hit → fallback name used',
      () async {
        final lookup = TripPlaceLookup(
          _FakeAdminRegionLookup(
            byLevel: {
              8: null,
              10: _region(999, 10, 'Kleinheubach'),
            },
          ),
        );

        final places = await lookup.lookup(
          startLat: 49.79,
          startLon: 9.18,
          endLat: 49.79,
          endLon: 9.18,
        );

        expect(places.startName, 'Kleinheubach');
        expect(places.endName, 'Kleinheubach');
        expect(places.isLoop, isTrue);
      },
    );

    test(
      'both levels null (over water / outside DE) → both names null, isLoop false',
      () async {
        final lookup = TripPlaceLookup(
          _FakeAdminRegionLookup(
            byLevel: {8: null, 10: null},
          ),
        );

        final places = await lookup.lookup(
          startLat: 54.5,
          startLon: 6,
          endLat: 54.5,
          endLon: 6,
        );

        expect(places.startName, isNull);
        expect(places.endName, isNull);
        expect(places.isLoop, isFalse);
      },
    );

    test(
      'mixed: start has level-8, end only level-10 → each best available',
      () async {
        final startL8 = _region(11, 8, 'Miltenberg');
        final endL10 = _region(12, 10, 'Kleinheubach');
        final lookup = TripPlaceLookup(
          _FakeAdminRegionLookup(
            byPoint: {
              // start: level-8 hit
              (49.79, 9.18, 8): startL8,
              // end: level-8 miss, level-10 hit
              (49.72, 9.21, 8): null,
              (49.72, 9.21, 10): endL10,
            },
          ),
        );

        final places = await lookup.lookup(
          startLat: 49.79,
          startLon: 9.18,
          endLat: 49.72,
          endLon: 9.21,
        );

        expect(places.startName, 'Miltenberg');
        expect(places.endName, 'Kleinheubach');
        expect(places.isLoop, isFalse);
      },
    );
  });
}
