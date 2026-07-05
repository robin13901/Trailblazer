import 'dart:io';

import 'package:args/args.dart';
import 'package:osm_pipeline/cli/errors.dart';

/// Parsed CLI arguments for `dart run tool/osm_pipeline`.
class ParsedArgs {
  /// Create a parsed args value.
  const ParsedArgs({required this.pbfPath, required this.bbox});

  /// Parse [argv] and validate. Throws [PipelineError] on invalid input.
  ///
  /// A static method (not a factory constructor) because construction is
  /// non-trivial — it reads the filesystem to verify [pbfPath] exists and
  /// parses [bbox]. Both operations may throw [PipelineArgsError] or
  /// [PipelineIoError].
  // ignore: prefer_constructors_over_static_methods
  static ParsedArgs parse(List<String> argv) {
    final parser = ArgParser()
      ..addOption(
        'pbf',
        help: 'Path to the input .osm.pbf file (required).',
      )
      ..addOption(
        'bbox',
        help: 'Optional bbox: minLng,minLat,maxLng,maxLat',
      );

    final ArgResults parsed;
    try {
      parsed = parser.parse(argv);
    } on FormatException catch (e, st) {
      throw PipelineArgsError(
        'Invalid CLI arguments: ${e.message}',
        cause: e,
        stackTrace: st,
      );
    }

    final pbfPath = parsed['pbf'] as String?;
    if (pbfPath == null || pbfPath.isEmpty) {
      throw const PipelineArgsError('--pbf required (path to .osm.pbf file)');
    }
    if (!File(pbfPath).existsSync()) {
      throw PipelineIoError('PBF file not found: $pbfPath');
    }

    final bboxRaw = parsed['bbox'] as String?;
    final bbox = bboxRaw == null || bboxRaw.isEmpty
        ? null
        : BoundingBox.parse(bboxRaw);

    return ParsedArgs(pbfPath: pbfPath, bbox: bbox);
  }

  /// Path to the input `*.osm.pbf` file. Verified to exist at parse time.
  final String pbfPath;

  /// Optional bounding box (minLng, minLat, maxLng, maxLat). Null means the
  /// pipeline runs over the full extract.
  final BoundingBox? bbox;
}

/// Geographic bounding box, in decimal degrees.
class BoundingBox {
  /// Create a bounding box.
  const BoundingBox({
    required this.minLng,
    required this.minLat,
    required this.maxLng,
    required this.maxLat,
  });

  /// Parses a "minLng,minLat,maxLng,maxLat" string.
  ///
  /// Rejects any input that is not four comma-separated doubles or that lies
  /// outside standard lat/lng ranges.
  // ignore: prefer_constructors_over_static_methods
  static BoundingBox parse(String raw) {
    final parts = raw.split(',');
    if (parts.length != 4) {
      throw PipelineArgsError(
        'Invalid --bbox: expected four comma-separated doubles '
        '(minLng,minLat,maxLng,maxLat), got "$raw"',
      );
    }
    final doubles = <double>[];
    for (final part in parts) {
      final v = double.tryParse(part.trim());
      if (v == null) {
        throw PipelineArgsError(
          'Invalid --bbox component "$part": not a number',
        );
      }
      doubles.add(v);
    }
    final minLng = doubles[0];
    final minLat = doubles[1];
    final maxLng = doubles[2];
    final maxLat = doubles[3];

    if (minLng < -180 || minLng > 180 || maxLng < -180 || maxLng > 180) {
      throw PipelineArgsError(
        'Invalid --bbox: longitude out of range [-180, 180] in "$raw"',
      );
    }
    if (minLat < -90 || minLat > 90 || maxLat < -90 || maxLat > 90) {
      throw PipelineArgsError(
        'Invalid --bbox: latitude out of range [-90, 90] in "$raw"',
      );
    }
    if (minLng >= maxLng) {
      throw PipelineArgsError(
        'Invalid --bbox: minLng ($minLng) >= maxLng ($maxLng)',
      );
    }
    if (minLat >= maxLat) {
      throw PipelineArgsError(
        'Invalid --bbox: minLat ($minLat) >= maxLat ($maxLat)',
      );
    }

    return BoundingBox(
      minLng: minLng,
      minLat: minLat,
      maxLng: maxLng,
      maxLat: maxLat,
    );
  }

  /// Western longitude bound.
  final double minLng;

  /// Southern latitude bound.
  final double minLat;

  /// Eastern longitude bound.
  final double maxLng;

  /// Northern latitude bound.
  final double maxLat;

  @override
  String toString() => '$minLng,$minLat,$maxLng,$maxLat';
}
