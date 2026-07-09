// Trailblazer Phase 6, Plan 06-02 Task 1:
// TripPlaceLookup — reverse-geocodes a trip's start/end coordinates to
// human-readable place names using the bundled admin-region polygons
// (Phase 4 Plan 04-16).
//
// Level-8 (Landkreis / kreisfreie Stadt) is preferred; falls back to
// level-10 (Ortsteil / Gemeinde) if level-8 is null; finally null when
// both levels are null (over water or outside DE).
//
// Consumed by the inbox / history cards in later 06-plans via
// `tripPlacesProvider` (see `trip_place_lookup_providers.dart`).

import 'package:auto_explore/features/admin/data/admin_region_lookup.dart';
import 'package:meta/meta.dart';

/// Resolved place names for a trip's two endpoints.
@immutable
class TripPlaces {
  const TripPlaces({required this.startName, required this.endName});

  /// e.g. "Miltenberg" (level 8) or "Kleinheubach" (level 10 fallback).
  final String? startName;
  final String? endName;

  /// True when start and end resolve to the same named region — the card
  /// UI renders this as "Round trip in {name}" instead of "{start} → {end}".
  bool get isLoop => startName != null && startName == endName;
}

/// Two-endpoint reverse geocoder over [AdminRegionLookup].
class TripPlaceLookup {
  TripPlaceLookup(this._regionLookup);

  final AdminRegionLookup _regionLookup;

  /// Primary admin level (Landkreis / kreisfreie Stadt).
  static const int _primaryLevel = 8;

  /// Fallback admin level (Ortsteil / Gemeinde).
  static const int _fallbackLevel = 10;

  /// Returns the level-8 region name if present, falls back to level-10
  /// otherwise. Both endpoints are resolved independently — a start with
  /// level-8 coverage and an end with only level-10 coverage yields
  /// each's best-available name.
  Future<TripPlaces> lookup({
    required double startLat,
    required double startLon,
    required double endLat,
    required double endLon,
  }) async {
    final startName = await _nameAt(startLat, startLon);
    final endName = await _nameAt(endLat, endLon);
    return TripPlaces(startName: startName, endName: endName);
  }

  Future<String?> _nameAt(double lat, double lon) async {
    final primary = await _regionLookup.regionAt(lat, lon, _primaryLevel);
    if (primary != null) return primary.name;
    final fallback = await _regionLookup.regionAt(lat, lon, _fallbackLevel);
    return fallback?.name;
  }
}
