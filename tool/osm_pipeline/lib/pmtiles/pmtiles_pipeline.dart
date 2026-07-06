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
import 'package:osm_pipeline/output/version_stamp.dart';
import 'package:osm_pipeline/pmtiles/geojson_writer.dart';
import 'package:osm_pipeline/pmtiles/layer_schema.dart';
import 'package:osm_pipeline/pmtiles/pmtiles_metadata_patcher.dart';
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
///
/// When [versionStamp] is supplied, the produced pmtiles has its metadata
/// JSON block patched (04-08) with the trailblazer version keys so
/// runtime code (Phase 5, Phase 10) can verify that pmtiles and
/// osm.sqlite were built from the same source PBF.
Future<PmtilesStageResult> runPmtilesStage({
  required ScratchDb scratch,
  required File pbf,
  required Directory outDir,
  VersionStamp? versionStamp,
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

  // Stage F.3 — patch pmtiles metadata with trailblazer version keys.
  // This mirrors the seven-row osm.sqlite metadata table (04-RESEARCH §9)
  // plus the vector_layers array MapLibre needs for style rendering. Phase
  // 5 + Phase 10 runtime code compares `pbf_sha256` here against the value
  // in osm.sqlite to confirm both artifacts came from the same PBF.
  if (versionStamp != null) {
    Logger.info('Stage F.3: patch pmtiles metadata...');
    await PmtilesMetadataPatcher.patch(
      pmtiles,
      _buildMetadataPatch(versionStamp),
    );
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

/// Builds the pmtiles metadata patch object mirroring the osm.sqlite
/// metadata table (04-RESEARCH §9) + the vector_layers array required by
/// the PMTiles v3 spec / MapLibre style renderer.
///
/// Reflected in [PmtilesMetadataPatcher.patch] on the produced archive
/// so runtime code (Phase 5, Phase 10) can cross-verify pmtiles and
/// osm.sqlite were built from the same source PBF via `pbf_sha256`.
Map<String, dynamic> _buildMetadataPatch(VersionStamp stamp) {
  return <String, dynamic>{
    'name': 'trailblazer-germany-base',
    'version': '${stamp.schemaVersion}',
    'pbf_date': stamp.pbfDate.toUtc().toIso8601String(),
    'pbf_source': stamp.pbfSource,
    'pbf_sha256': stamp.pbfSha256,
    'bbox': stamp.bbox ?? '*',
    'pipeline_schema_version': '${stamp.schemaVersion}',
    'pipeline_git_sha': stamp.gitSha,
    'generated_at': stamp.generatedAt.toUtc().toIso8601String(),
    'vector_layers': kTrailblazerVectorLayers,
  };
}

/// Static description of the 4 vector layers written by tippecanoe. Mirrors
/// the tippecanoe `-L` invocations in [runPmtilesStage] and the runtime
/// filters in `assets/map_style_{light,dark}.json`.
///
/// Field-type enums per PMTiles v3 spec: `'String' | 'Number' | 'Boolean'`.
const List<Map<String, dynamic>> kTrailblazerVectorLayers =
    <Map<String, dynamic>>[
  <String, dynamic>{
    'id': Layers.roads,
    'description': 'Kfz + Feldweg drivable ways',
    'fields': <String, String>{
      'kind': 'String',
      'name': 'String',
      'ref': 'String',
      'oneway': 'Boolean',
    },
    'minzoom': 5,
    'maxzoom': 11,
  },
  <String, dynamic>{
    'id': Layers.adminBoundaries,
    'description': 'Admin regions (L2..L10) — both fill polygons + outlines',
    'fields': <String, String>{
      'admin_level': 'Number',
      'kind': 'String',
      'name': 'String',
      'shape': 'String',
    },
    'minzoom': 0,
    'maxzoom': 11,
  },
  <String, dynamic>{
    'id': Layers.water,
    'description': 'Inland water bodies + waterways',
    'fields': <String, String>{
      'kind': 'String',
      'name': 'String',
    },
    'minzoom': 0,
    'maxzoom': 11,
  },
  <String, dynamic>{
    'id': Layers.labels,
    'description': 'Place-name labels + road-shield midpoints',
    'fields': <String, String>{
      'kind': 'String',
      'name': 'String',
      'ref': 'String',
      'population': 'Number',
    },
    'minzoom': 0,
    'maxzoom': 11,
  },
];
