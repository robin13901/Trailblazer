import 'dart:convert';
import 'dart:io';

import 'package:auto_explore/features/admin/data/admin_region.dart';
import 'package:auto_explore/features/admin/data/admin_region_lookup.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// TestAssetBundle that serves a caller-supplied byte payload for the
/// admin bundle path.
class _FixtureAssetBundle extends CachingAssetBundle {
  _FixtureAssetBundle(this.bytesByKey);

  final Map<String, Uint8List> bytesByKey;

  @override
  Future<ByteData> load(String key) async {
    final bytes = bytesByKey[key];
    if (bytes == null) {
      throw StateError('Missing test asset: $key');
    }
    return ByteData.view(bytes.buffer);
  }

  @override
  Future<String> loadString(String key, {bool cache = true}) async {
    final bytes = bytesByKey[key];
    if (bytes == null) {
      throw StateError('Missing test asset: $key');
    }
    return utf8.decode(bytes);
  }
}

/// Docs-dir loader that points at a temp Directory with no override file —
/// keeps the runtime-override branch inert during unit tests.
Future<Directory> _emptyDocsDir() async {
  final dir = await Directory.systemTemp.createTemp('admin_lookup_test_');
  addTearDown(() async {
    if (dir.existsSync()) await dir.delete(recursive: true);
  });
  return dir;
}

/// Builds a synthetic FeatureCollection with the 5 known fixture regions,
/// gzips it, and returns the raw bytes.
Uint8List _buildFixtureBundle() {
  // Berlin (approximated as a small box around 52.52N, 13.4E).
  final berlin = _feature(
    osmId: 62422,
    adminLevel: 4,
    name: 'Berlin',
    nameDe: 'Berlin',
    outer: [
      [13.3, 52.4],
      [13.3, 52.7],
      [13.6, 52.7],
      [13.6, 52.4],
      [13.3, 52.4],
    ],
  );

  // Kreuzberg (small L10 box inside Berlin around 52.4993N, 13.4025E).
  final kreuzberg = _feature(
    osmId: 55764,
    adminLevel: 10,
    name: 'Kreuzberg',
    outer: [
      [13.38, 52.49],
      [13.38, 52.51],
      [13.42, 52.51],
      [13.42, 52.49],
      [13.38, 52.49],
    ],
  );

  // Bayern (Bavaria, box around 49.5-50N, 9-10E — includes Kleinheubach).
  final bayern = _feature(
    osmId: 2145268,
    adminLevel: 4,
    name: 'Bayern',
    nameDe: 'Bayern',
    outer: [
      [9.0, 49.5],
      [9.0, 50.0],
      [10.0, 50.0],
      [10.0, 49.5],
      [9.0, 49.5],
    ],
  );

  // Landkreis Miltenberg (L6 box inside Bayern; contains Kleinheubach).
  final miltenberg = _feature(
    osmId: 2145283,
    adminLevel: 6,
    name: 'Miltenberg',
    outer: [
      [9.10, 49.70],
      [9.10, 49.85],
      [9.30, 49.85],
      [9.30, 49.70],
      [9.10, 49.70],
    ],
  );

  // Kleinheubach (L8 box inside Miltenberg; contains 49.796N, 9.185E).
  final kleinheubach = _feature(
    osmId: 122437,
    adminLevel: 8,
    name: 'Kleinheubach',
    outer: [
      [9.15, 49.78],
      [9.15, 49.81],
      [9.22, 49.81],
      [9.22, 49.78],
      [9.15, 49.78],
    ],
  );

  final fc = {
    'type': 'FeatureCollection',
    'features': [berlin, kreuzberg, bayern, miltenberg, kleinheubach],
  };
  final jsonBytes = utf8.encode(jsonEncode(fc));
  return Uint8List.fromList(gzip.encode(jsonBytes));
}

Map<String, dynamic> _feature({
  required int osmId,
  required int adminLevel,
  required String name,
  required List<List<double>> outer,
  String? nameDe,
}) {
  return {
    'type': 'Feature',
    'properties': {
      'osm_id': osmId,
      'admin_level': adminLevel,
      'name': name,
      // Optional; inline `if` keeps compatibility with the Dart SDK used
      // by this project (map-entry null-aware syntax landed in 3.9+).
      // ignore: use_null_aware_elements
      if (nameDe != null) 'name:de': nameDe,
    },
    'geometry': {
      'type': 'MultiPolygon',
      'coordinates': [
        [outer], // one polygon with one outer ring
      ],
    },
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FixtureAssetBundle bundle;

  setUp(() {
    bundle = _FixtureAssetBundle({
      kAdminBundleAssetPath: _buildFixtureBundle(),
    });
  });

  AdminRegionLookup makeLookup() => AdminRegionLookup(
        bundle: bundle,
        docsDirLoader: _emptyDocsDir,
      );

  test('regionAt(52.52, 13.405, 4) returns Berlin', () async {
    final lookup = makeLookup();
    final region = await lookup.regionAt(52.52, 13.405, 4);
    expect(region, isNotNull);
    expect(region!.name, 'Berlin');
    expect(region.adminLevel, 4);
  });

  test('regionAt(52.4993, 13.4025, 10) returns Kreuzberg', () async {
    final lookup = makeLookup();
    final region = await lookup.regionAt(52.4993, 13.4025, 10);
    expect(region, isNotNull);
    expect(region!.name, 'Kreuzberg');
  });

  test('regionAt(49.796, 9.185, 8) returns Kleinheubach', () async {
    final lookup = makeLookup();
    final region = await lookup.regionAt(49.796, 9.185, 8);
    expect(region, isNotNull);
    expect(region!.name, 'Kleinheubach');
  });

  test('regionAt(49.796, 9.185, 6) returns Miltenberg', () async {
    final lookup = makeLookup();
    final region = await lookup.regionAt(49.796, 9.185, 6);
    expect(region, isNotNull);
    expect(region!.name, 'Miltenberg');
  });

  test('regionAt(49.796, 9.185, 4) returns Bayern', () async {
    final lookup = makeLookup();
    final region = await lookup.regionAt(49.796, 9.185, 4);
    expect(region, isNotNull);
    expect(region!.name, 'Bayern');
  });

  test('regionAt over ocean returns null', () async {
    final lookup = makeLookup();
    // Middle of the North Sea.
    final region = await lookup.regionAt(56, 3, 4);
    expect(region, isNull);
  });

  test('regionAt latency: 1000 calls averages under 5 ms', () async {
    final lookup = makeLookup();
    // Warm the cache.
    await lookup.regionAt(52.52, 13.405, 4);
    final sw = Stopwatch()..start();
    for (var i = 0; i < 1000; i++) {
      await lookup.regionAt(49.796, 9.185, 8);
    }
    sw.stop();
    final avgUs = sw.elapsedMicroseconds / 1000;
    // < 5 ms == < 5000 µs
    expect(
      avgUs,
      lessThan(5000),
      reason: 'avg per-call = ${avgUs.toStringAsFixed(1)}µs',
    );
  });

  test('ensureLoaded is idempotent — bundle parsed only once', () async {
    final lookup = makeLookup();
    await lookup.ensureLoaded();
    await lookup.ensureLoaded();
    await lookup.ensureLoaded();
    expect(lookup.bundleLoadCount, 1);
    expect(lookup.regionCount, 5);
  });

  test('invalidate forces a fresh parse on next call', () async {
    final lookup = makeLookup();
    await lookup.ensureLoaded();
    expect(lookup.bundleLoadCount, 1);
    lookup.invalidate();
    await lookup.ensureLoaded();
    expect(lookup.bundleLoadCount, 2);
  });
}

// Silence: keep AdminRegion referenced so exported types don't get
// tree-shaken by future refactors.
// ignore: unused_element
AdminRegion? _unused(AdminRegion r) => r;
