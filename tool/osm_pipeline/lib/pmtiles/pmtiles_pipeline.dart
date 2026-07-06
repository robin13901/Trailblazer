/// pmtiles pipeline — Stage D of the OSM pipeline (04-07).
///
/// Emits the four vector layers as GeoJSONSeq files and invokes tippecanoe
/// to author the final `germany-base.pmtiles`. Intermediate `.geojsonl`
/// files are deleted after tippecanoe completes.
///
/// tippecanoe flag choices:
///   * `--maximum-zoom=11` — matches 04-CONTEXT + Phase 2's Protomaps demo
///     baseline (371 MB Germany at maxzoom 11).
///   * `--drop-densest-as-needed` + `--extend-zooms-if-still-dropping` —
///     Protomaps-style adaptive drop to fit within the per-tile budget.
///   * `--no-tile-compression` — Phase 2's MapLibre setup expects raw MVT.
///     If the app rejects them, drop this flag (and re-check 04-08's style
///     JSON).
///   * `--force` — clobber a stale pmtiles from a previous run.
library;

import 'dart:convert';
import 'dart:io';

import 'package:osm_pipeline/cli/logger.dart';
import 'package:osm_pipeline/pmtiles/geojson_writer.dart';
import 'package:osm_pipeline/pmtiles/layer_schema.dart';
import 'package:osm_pipeline/pmtiles/tippecanoe_runner.dart';
import 'package:osm_pipeline/scratch/scratch_db.dart';
import 'package:path/path.dart' as p;

/// Output name of the pmtiles artifact.
const String kPmtilesFileName = 'germany-base.pmtiles';

/// Summary emitted by [runPmtilesStage].
class PmtilesStageResult {
  /// Create a stage result.
  const PmtilesStageResult({
    required this.pmtilesFile,
    required this.pmtilesBytes,
    required this.roadsCount,
    required this.adminBoundariesCount,
    required this.waterCount,
    required this.labelsCount,
    required this.tippecanoeVersion,
  });

  /// Final pmtiles artifact.
  final File pmtilesFile;

  /// On-disk byte size of [pmtilesFile].
  final int pmtilesBytes;

  /// Features written to the roads GeoJSONSeq input.
  final int roadsCount;

  /// Features written to the admin_boundaries GeoJSONSeq input.
  final int adminBoundariesCount;

  /// Features written to the water GeoJSONSeq input.
  final int waterCount;

  /// Features written to the labels GeoJSONSeq input.
  final int labelsCount;

  /// tippecanoe `--version` banner captured at preflight.
  final String tippecanoeVersion;
}

/// Runs Stage D of the pipeline: emit GeoJSONSeq + invoke tippecanoe.
///
/// Reads Kfz/Feldweg ways + admin regions from [scratch] and re-scans [pbf]
/// once each for water and labels. Writes into [outDir]/`germany-base.pmtiles`.
Future<PmtilesStageResult> runPmtilesStage({
  required ScratchDb scratch,
  required File pbf,
  required Directory outDir,
}) async {
  final version = await TippecanoeRunner.preflightCheck();
  Logger.info('  tippecanoe: $version');

  outDir.createSync(recursive: true);

  final roads = File(p.join(outDir.path, 'roads.geojsonl'));
  final admins = File(p.join(outDir.path, 'admin_boundaries.geojsonl'));
  final water = File(p.join(outDir.path, 'water.geojsonl'));
  final labels = File(p.join(outDir.path, 'labels.geojsonl'));

  Logger.info('Stage D.1: emit GeoJSONSeq per layer...');
  final roadsSink = roads.openWrite();
  final roadsCount = await GeoJsonSeqWriter.writeRoads(scratch, roadsSink);
  await roadsSink.close();
  Logger.info('  roads: $roadsCount features → ${roads.path}');

  final adminSink = admins.openWrite();
  final adminCount =
      await GeoJsonSeqWriter.writeAdminBoundaries(scratch, adminSink);
  await adminSink.close();
  Logger.info('  admin_boundaries: $adminCount features → ${admins.path}');

  final waterSink = water.openWrite();
  final waterCount =
      await GeoJsonSeqWriter.writeWater(pbf, scratch, waterSink);
  await waterSink.close();
  Logger.info('  water: $waterCount features → ${water.path}');

  final labelsSink = labels.openWrite();
  final labelsCount =
      await GeoJsonSeqWriter.writeLabels(pbf, scratch, labelsSink);
  await labelsSink.close();
  Logger.info('  labels: $labelsCount features → ${labels.path}');

  Logger.info('Stage D.2: run tippecanoe...');
  final pmtiles = File(p.join(outDir.path, kPmtilesFileName));
  if (pmtiles.existsSync()) pmtiles.deleteSync();

  await TippecanoeRunner.run([
    '-o',
    _p(pmtiles),
    '--maximum-zoom=11',
    '--minimum-zoom=0',
    '--drop-densest-as-needed',
    '--extend-zooms-if-still-dropping',
    '--no-tile-compression',
    '--force',
    '-L',
    jsonEncode({'file': _p(roads), 'layer': Layers.roads}),
    '-L',
    jsonEncode({'file': _p(admins), 'layer': Layers.adminBoundaries}),
    '-L',
    jsonEncode({'file': _p(water), 'layer': Layers.water}),
    '-L',
    jsonEncode({'file': _p(labels), 'layer': Layers.labels}),
  ]);

  // Clean up intermediate .geojsonl files — they're bulk and only useful
  // for debugging during a failing run.
  for (final f in [roads, admins, water, labels]) {
    if (f.existsSync()) f.deleteSync();
  }

  final bytes = pmtiles.lengthSync();
  Logger.info('  → ${pmtiles.path}  ($bytes bytes)');
  return PmtilesStageResult(
    pmtilesFile: pmtiles,
    pmtilesBytes: bytes,
    roadsCount: roadsCount,
    adminBoundariesCount: adminCount,
    waterCount: waterCount,
    labelsCount: labelsCount,
    tippecanoeVersion: version,
  );
}

/// Path helper — converts to WSL mount notation when tippecanoe runs under
/// WSL2 on Windows.
String _p(File f) =>
    Platform.isWindows ? wslifyPath(f.absolute.path) : f.absolute.path;
