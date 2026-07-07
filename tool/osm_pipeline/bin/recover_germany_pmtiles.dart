/// Standalone recovery driver for the 2026-07-07 tippecanoe crash.
///
/// The 2026-07-06 full-Germany pipeline run reached 90.5% through
/// tippecanoe tiling before a Thunderbolt-dock disconnect killed the WSL
/// subprocess. All four `.geojsonl` inputs and `osm.sqlite` survived on
/// disk. This driver:
///
///   1. Deletes stale `germany-base.pmtiles` + `-journal` files.
///   2. Invokes tippecanoe with the SAME args the crashed run used
///      (via `TippecanoeRunner`, so Windows→WSL path translation is
///      identical to the production path).
///   3. Reads the seven canonical metadata keys from the surviving
///      `osm.sqlite` and stamps them onto the new pmtiles via
///      `PmtilesMetadataPatcher`.
///   4. Deletes the four `.geojsonl` inputs on success (matches the
///      production pipeline's cleanup contract).
///
/// This is a one-shot recovery tool — do not build ongoing infrastructure
/// on it. Delete after Phase 4 close-out.
library;

import 'dart:io';

import 'package:osm_pipeline/cli/logger.dart';
import 'package:osm_pipeline/pmtiles/pmtiles_metadata_patcher.dart';
import 'package:osm_pipeline/pmtiles/pmtiles_pipeline.dart';
import 'package:osm_pipeline/pmtiles/tippecanoe_runner.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

const _outDir = r'C:\SAPDevelop\Privat\Trailblazer\tool\osm_pipeline\out';
const _pmtilesName = 'germany-base.pmtiles';
const _osmSqliteName = 'osm.sqlite';
const _layers = <(String, String)>[
  ('roads.geojsonl', 'roads'),
  ('admin_boundaries.geojsonl', 'admin_boundaries'),
  ('water.geojsonl', 'water'),
  ('labels.geojsonl', 'labels'),
];

Future<void> main() async {
  Logger.info('=== Germany pmtiles recovery (2026-07-07) ===');

  // 1. Verify all four geojsonl inputs are present.
  final missing = <String>[];
  for (final (fname, _) in _layers) {
    final f = File(p.join(_outDir, fname));
    if (!f.existsSync()) missing.add(fname);
  }
  if (missing.isNotEmpty) {
    Logger.error('Missing input files: ${missing.join(", ")}');
    exit(1);
  }
  Logger.info('  inputs: all four .geojsonl files present');

  // 2. Wipe stale pmtiles + journal.
  final pmtiles = File(p.join(_outDir, _pmtilesName));
  final journal = File(p.join(_outDir, '$_pmtilesName-journal'));
  if (pmtiles.existsSync()) {
    Logger.info('  removing stale pmtiles (${pmtiles.lengthSync()} bytes)');
    pmtiles.deleteSync();
  }
  if (journal.existsSync()) {
    Logger.info('  removing stale journal (${journal.lengthSync()} bytes)');
    journal.deleteSync();
  }

  // 3. Preflight tippecanoe.
  final version = await TippecanoeRunner.preflightCheck();
  Logger.info('  tippecanoe: $version');

  // 4. Invoke tippecanoe with identical args to production pipeline.
  //    (Mirrors tool/osm_pipeline/lib/pmtiles/pmtiles_pipeline.dart:121-138.)
  final start = DateTime.now();
  Logger.info('Running tippecanoe (this took ~1h in the crashed run)...');
  await TippecanoeRunner.run([
    '-o',
    _wsl(pmtiles.path),
    '--maximum-zoom=11',
    '--minimum-zoom=0',
    '--drop-densest-as-needed',
    '--extend-zooms-if-still-dropping',
    '--no-tile-compression',
    '--force',
    for (final (fname, layer) in _layers) ...[
      '-L',
      '{"file":"${_wsl(p.join(_outDir, fname))}","layer":"$layer"}',
    ],
  ]);
  final tippecanoeDuration = DateTime.now().difference(start);
  Logger.info('  tippecanoe done in ${tippecanoeDuration.inSeconds}s');

  // 5. Stamp metadata by reading osm.sqlite's own metadata table (guarantees
  //    identical values to the crashed run — the sha, source, date, git-sha,
  //    and generated_at were all written to osm.sqlite BEFORE the crash).
  final osmSqlite = File(p.join(_outDir, _osmSqliteName));
  if (!osmSqlite.existsSync()) {
    Logger.error('osm.sqlite missing — cannot recover metadata');
    exit(1);
  }
  final meta = _readOsmSqliteMetadata(osmSqlite);
  Logger.info('  metadata sourced from osm.sqlite:');
  for (final e in meta.entries) {
    Logger.info('    ${e.key} = ${e.value}');
  }

  Logger.info('Patching pmtiles metadata...');
  await PmtilesMetadataPatcher.patch(pmtiles, <String, dynamic>{
    'name': 'trailblazer-germany-base',
    'version': meta['pipeline_schema_version'] ?? '1',
    'pbf_date': meta['pbf_date'] ?? '',
    'pbf_source': meta['pbf_source'] ?? '',
    'pbf_sha256': meta['pbf_sha256'] ?? '',
    'bbox': meta['bbox'] ?? '*',
    'pipeline_schema_version': meta['pipeline_schema_version'] ?? '1',
    'pipeline_git_sha': meta['pipeline_git_sha'] ?? 'unknown',
    'generated_at': meta['generated_at'] ?? '',
    'vector_layers': kTrailblazerVectorLayers,
  });
  Logger.info('  metadata patched');

  // 6. Report final size.
  final pmtilesBytes = pmtiles.lengthSync();
  final pmtilesMB = (pmtilesBytes / (1024 * 1024)).toStringAsFixed(1);
  Logger.info('  final pmtiles: $pmtilesBytes bytes ($pmtilesMB MB)');

  // 7. Delete geojsonl inputs (matches production cleanup contract).
  Logger.info('Deleting geojsonl inputs...');
  for (final (fname, _) in _layers) {
    final f = File(p.join(_outDir, fname));
    if (f.existsSync()) {
      final size = f.lengthSync();
      f.deleteSync();
      Logger.info('  deleted $fname ($size bytes)');
    }
  }

  Logger.info('=== Recovery complete ===');
  Logger.info('  osm.sqlite: ${osmSqlite.lengthSync()} bytes');
  Logger.info('  germany-base.pmtiles: $pmtilesBytes bytes ($pmtilesMB MB)');
}

/// Reads all `key,value` rows from `osm.sqlite`'s metadata table.
Map<String, String> _readOsmSqliteMetadata(File osmSqlite) {
  final db = sqlite3.open(osmSqlite.path, mode: OpenMode.readOnly);
  try {
    final rs = db.select('SELECT key, value FROM metadata');
    return <String, String>{
      for (final row in rs) (row['key'] as String): row['value'] as String,
    };
  } finally {
    db.dispose();
  }
}

/// Converts a Windows absolute path to WSL2 mount notation on Windows,
/// passes it through unchanged elsewhere. Delegates to the pipeline's own
/// helper for identical behaviour.
String _wsl(String path) =>
    Platform.isWindows ? wslifyPath(path) : path;
