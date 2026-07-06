/// Tests for [PmtilesMetadataPatcher].
///
/// Uses hand-built synthetic PMTiles v3 files — no tippecanoe dependency.
/// The 127-byte header is emitted per spec, followed by minimal (or empty)
/// section blobs. The metadata JSON is gzip-encoded to match tippecanoe's
/// default `internal_compression=Gzip(2)`.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:osm_pipeline/pmtiles/pmtiles_metadata_patcher.dart';
import 'package:test/test.dart';

/// Fixture builder — writes a minimal, valid PMTiles v3 archive with the
/// given metadata JSON and a caller-controlled dummy tile-data payload.
File _makeFixture({
  required Directory dir,
  required Map<String, dynamic> metadata,
  Uint8List? rootDir,
  Uint8List? leafDirs,
  Uint8List? tileData,
  int internalCompression = 2, // gzip
}) {
  final rootBytes = rootDir ?? Uint8List(0);
  final leafBytes = leafDirs ?? Uint8List(0);
  final tileBytes = tileData ?? Uint8List(0);

  // Encode metadata per requested compression.
  final metaUtf8 = utf8.encode(jsonEncode(metadata));
  final Uint8List metaBytes;
  switch (internalCompression) {
    case 1: // None
      metaBytes = Uint8List.fromList(metaUtf8);
    case 2: // Gzip
      metaBytes = Uint8List.fromList(gzip.encode(metaUtf8));
    default:
      throw ArgumentError('unsupported test compression $internalCompression');
  }

  const headerBytes = PmtilesMetadataPatcher.headerBytes;
  const rootDirOffset = headerBytes;
  final rootDirBytes = rootBytes.length;
  final metaOffset = rootDirOffset + rootDirBytes;
  final metaSize = metaBytes.length;
  final leafOffset = metaOffset + metaSize;
  final leafSize = leafBytes.length;
  final tileOffset = leafOffset + leafSize;
  final tileSize = tileBytes.length;

  // magic
  const magic = <int>[0x50, 0x4d, 0x54, 0x69, 0x6c, 0x65, 0x73, 0x03];
  final header = Uint8List(headerBytes)..setRange(0, magic.length, magic);
  ByteData.sublistView(header)
    ..setUint64(8, rootDirOffset, Endian.little)
    ..setUint64(16, rootDirBytes, Endian.little)
    ..setUint64(24, metaOffset, Endian.little)
    ..setUint64(32, metaSize, Endian.little)
    ..setUint64(40, leafOffset, Endian.little)
    ..setUint64(48, leafSize, Endian.little)
    ..setUint64(56, tileOffset, Endian.little)
    ..setUint64(64, tileSize, Endian.little);
  // number_of_addressed_tiles / number_of_tile_entries /
  // number_of_tile_contents — leave as 0.
  header[96] = 1; // clustered = true (arbitrary — not validated).
  header[97] = internalCompression;
  header[98] = 1; // tile_compression = None (irrelevant for these tests)
  header[99] = 1; // tile_type = MVT
  header[100] = 0; // min_zoom
  header[101] = 5; // max_zoom (arbitrary)
  // remaining bounds/centre bytes stay 0 — irrelevant for patcher round-trip.

  final f = File('${dir.path}${Platform.pathSeparator}fixture.pmtiles');
  // Write synchronously to guarantee bytes on disk before test uses file.
  final all = <int>[
    ...header,
    ...rootBytes,
    ...metaBytes,
    ...leafBytes,
    ...tileBytes,
  ];
  f.writeAsBytesSync(all, flush: true);
  return f;
}

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('pmtiles_patcher_test_');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('PmtilesMetadataPatcher.readMetadata', () {
    test('reads gzip-compressed metadata JSON', () async {
      final f = _makeFixture(
        dir: tmp,
        metadata: <String, dynamic>{
          'name': 'trailblazer-test',
          'vector_layers': <Map<String, dynamic>>[
            <String, dynamic>{'id': 'roads'},
          ],
        },
      );

      final meta = await PmtilesMetadataPatcher.readMetadata(f);

      expect(meta['name'], 'trailblazer-test');
      expect(meta['vector_layers'], isA<List<dynamic>>());
      expect(
        (meta['vector_layers'] as List).first,
        isA<Map<String, dynamic>>(),
      );
    });

    test('reads uncompressed metadata JSON', () async {
      final f = _makeFixture(
        dir: tmp,
        metadata: <String, dynamic>{'name': 'plain'},
        internalCompression: 1,
      );

      final meta = await PmtilesMetadataPatcher.readMetadata(f);

      expect(meta['name'], 'plain');
    });

    test('rejects non-PMTiles file with FormatException', () async {
      final f = File('${tmp.path}${Platform.pathSeparator}bogus.pmtiles')
        ..writeAsBytesSync(List<int>.filled(200, 0));

      expect(
        () => PmtilesMetadataPatcher.readMetadata(f),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('PmtilesMetadataPatcher.patch', () {
    test('merges patch keys with existing metadata', () async {
      final f = _makeFixture(
        dir: tmp,
        metadata: <String, dynamic>{
          'name': 'from-tippecanoe',
          'bounds': <double>[0, 0, 1, 1],
        },
      );

      await PmtilesMetadataPatcher.patch(f, <String, dynamic>{
        'name': 'trailblazer-germany-base',
        'pbf_date': '2026-07-06T00:00:00Z',
        'pipeline_schema_version': '1',
      });

      final meta = await PmtilesMetadataPatcher.readMetadata(f);
      expect(meta['name'], 'trailblazer-germany-base'); // overridden
      expect(meta['bounds'], isA<List<dynamic>>()); // preserved
      expect(meta['pbf_date'], '2026-07-06T00:00:00Z'); // added
      expect(meta['pipeline_schema_version'], '1'); // added
    });

    test('vector_layers array survives a patch as a JSON array (not string)',
        () async {
      final f = _makeFixture(
        dir: tmp,
        metadata: <String, dynamic>{'name': 'x'},
      );

      final layers = <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'roads',
          'fields': <String, dynamic>{'kind': 'String'},
          'minzoom': 5,
          'maxzoom': 11,
        },
        <String, dynamic>{
          'id': 'water',
          'fields': <String, dynamic>{'kind': 'String'},
          'minzoom': 0,
          'maxzoom': 11,
        },
      ];
      await PmtilesMetadataPatcher.patch(f, <String, dynamic>{
        'vector_layers': layers,
      });

      final meta = await PmtilesMetadataPatcher.readMetadata(f);
      final readLayers = meta['vector_layers'];
      expect(readLayers, isA<List<dynamic>>());
      expect((readLayers as List).length, 2);
      expect(readLayers.first, isA<Map<String, dynamic>>());
      expect((readLayers.first as Map)['id'], 'roads');
    });

    test('grows metadata larger than original — root/leaf/tile bytes preserved',
        () async {
      // Prime a small metadata + a distinctive tile-data payload; after
      // patching with a much larger metadata block the tile-data payload
      // must still be readable byte-for-byte at its new offset.
      final rootDir = Uint8List.fromList(<int>[0xAA, 0xBB, 0xCC, 0xDD]);
      final tileData = Uint8List.fromList(
        List<int>.generate(1024, (i) => i & 0xff),
      );
      final f = _makeFixture(
        dir: tmp,
        metadata: <String, dynamic>{'name': 'tiny'},
        rootDir: rootDir,
        tileData: tileData,
      );

      // Build a large patch (~ 10 KB of JSON) to force metadata-section
      // growth beyond the original.
      final bigPatch = <String, dynamic>{
        'blob': List<String>.generate(200, (i) => 'field_$i' * 4),
      };
      await PmtilesMetadataPatcher.patch(f, bigPatch);

      // Manually parse the resulting file to confirm the tile-data section
      // is still intact byte-for-byte at its new offset.
      final bytes = f.readAsBytesSync();
      final view = ByteData.sublistView(bytes, 0, 127);
      final newTileOffset = view.getUint64(56, Endian.little);
      final newTileBytes = view.getUint64(64, Endian.little);
      expect(newTileBytes, tileData.length);
      final readTiles = bytes.sublist(
        newTileOffset,
        newTileOffset + newTileBytes,
      );
      expect(readTiles, orderedEquals(tileData));

      // Root dir also preserved byte-for-byte.
      final newRootOffset = view.getUint64(8, Endian.little);
      final newRootBytes = view.getUint64(16, Endian.little);
      expect(newRootBytes, rootDir.length);
      final readRoot = bytes.sublist(
        newRootOffset,
        newRootOffset + newRootBytes,
      );
      expect(readRoot, orderedEquals(rootDir));
    });

    test('idempotent — patch(X) then patch(X) produces the same metadata',
        () async {
      final f = _makeFixture(
        dir: tmp,
        metadata: <String, dynamic>{'name': 'base'},
      );

      final p = <String, dynamic>{
        'name': 'trailblazer',
        'pipeline_schema_version': '1',
      };
      await PmtilesMetadataPatcher.patch(f, p);
      final meta1 = await PmtilesMetadataPatcher.readMetadata(f);
      await PmtilesMetadataPatcher.patch(f, p);
      final meta2 = await PmtilesMetadataPatcher.readMetadata(f);

      expect(meta1, equals(meta2));
    });
  });
}
