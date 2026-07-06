/// PMTiles v3 metadata patcher — rewrites the JSON metadata block inside a
/// `.pmtiles` file after tippecanoe emission.
///
/// Why: tippecanoe writes only a minimal metadata block (name + bounds +
/// vector_layers). 04-08 needs to stamp our own version keys (pbf_date,
/// pipeline_schema_version, pipeline_git_sha, generated_at, ...) so runtime
/// code (Phase 5, Phase 10) can verify pmtiles and osm.sqlite were built
/// from the same source PBF.
///
/// Strategy: full-file rewrite (safe + simple).
///
///   1. Parse the 127-byte v3 header (magic + section offsets/sizes +
///      compression flag).
///   2. Read the four sections verbatim: root_dir, metadata, leaf_dirs,
///      tile_data.
///   3. Decompress + JSON-decode the metadata section, merge caller's patch
///      on top, JSON-encode + recompress with the same internal codec.
///   4. Recompute section offsets under the canonical PMTiles v3 layout
///      (header @ 0, root_dir @ 127, metadata after root_dir, leaf_dirs
///      after metadata, tile_data after leaf_dirs).
///   5. Write header + all four sections to a sibling `.tmp` file then
///      atomically rename over the original.
///
/// This design lets the metadata block grow OR shrink without corrupting
/// the offsets — the price is one extra file write pass. For our 14.58 MB
/// Berlin pmtiles that's <100 ms; irrelevant next to tippecanoe's runtime.
///
/// PMTiles v3 spec reference:
/// https://github.com/protomaps/PMTiles/blob/main/spec/v3/spec.md
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Rewrites the JSON metadata block inside a PMTiles v3 archive.
///
/// See file-level doc comment for the strategy.
abstract final class PmtilesMetadataPatcher {
  /// Fixed size of a PMTiles v3 header.
  static const int headerBytes = 127;

  /// The 8-byte magic prefix (`PMTiles\x03`). Byte 7 = spec version.
  static const List<int> _magic = <int>[
    0x50, 0x4d, 0x54, 0x69, 0x6c, 0x65, 0x73, 0x03, //
  ];

  /// Compression enum values per PMTiles v3 spec §3.1.
  static const int _compressionUnknown = 0;
  static const int _compressionNone = 1;
  static const int _compressionGzip = 2;

  /// Reads and returns the JSON metadata block from [pmtiles].
  ///
  /// Throws [FormatException] if the file is not a PMTiles v3 archive or
  /// if the metadata block is not a JSON object.
  static Future<Map<String, dynamic>> readMetadata(File pmtiles) async {
    final bytes = await pmtiles.readAsBytes();
    final header = _parseHeader(bytes);
    return _readMetadataFromBytes(bytes, header);
  }

  /// Rewrites the JSON metadata block inside [pmtiles], merging [patch] on
  /// top of the existing metadata.
  ///
  /// Top-level keys in [patch] override same-named keys in the existing
  /// metadata; other keys are preserved. Nested maps are NOT deep-merged —
  /// e.g. supplying `'vector_layers': [...]` replaces the whole array.
  ///
  /// The file is rewritten atomically via a sibling `.tmp` file.
  static Future<void> patch(File pmtiles, Map<String, dynamic> patch) async {
    final bytes = await pmtiles.readAsBytes();
    final header = _parseHeader(bytes);

    // Read the four data sections verbatim (root_dir, leaf_dirs, tile_data
    // are copied byte-for-byte; only metadata is rewritten).
    final rootDir = _slice(bytes, header.rootDirOffset, header.rootDirBytes);
    final leafDirs = _slice(
      bytes,
      header.leafDirsOffset,
      header.leafDirsBytes,
    );
    final tileData = _slice(
      bytes,
      header.tileDataOffset,
      header.tileDataBytes,
    );

    // Decode existing metadata, merge patch, re-encode, recompress.
    final existing = _readMetadataFromBytes(bytes, header);
    final merged = <String, dynamic>{...existing, ...patch};
    final newMetadataBytes = _encodeMetadata(
      merged,
      header.internalCompression,
    );

    // Compute new offsets. Canonical PMTiles v3 layout tippecanoe emits:
    // header @ 0, root_dir @ 127, metadata after root_dir, leaf_dirs after
    // metadata, tile_data after leaf_dirs.
    const newRootDirOffset = headerBytes;
    final newRootDirBytes = rootDir.length;
    final newMetadataOffset = newRootDirOffset + newRootDirBytes;
    final newLeafDirsOffset = newMetadataOffset + newMetadataBytes.length;
    final newLeafDirsBytes = leafDirs.length;
    final newTileDataOffset = newLeafDirsOffset + newLeafDirsBytes;
    final newTileDataBytes = tileData.length;

    final newHeader = _writeHeader(
      header,
      rootDirOffset: newRootDirOffset,
      rootDirBytes: newRootDirBytes,
      metadataOffset: newMetadataOffset,
      metadataBytes: newMetadataBytes.length,
      leafDirsOffset: newLeafDirsOffset,
      leafDirsBytes: newLeafDirsBytes,
      tileDataOffset: newTileDataOffset,
      tileDataBytes: newTileDataBytes,
    );

    // Write atomically via a sibling temp file.
    final tmp = File('${pmtiles.path}.tmp');
    final sink = tmp.openWrite();
    try {
      sink
        ..add(newHeader)
        ..add(rootDir)
        ..add(newMetadataBytes);
      if (leafDirs.isNotEmpty) sink.add(leafDirs);
      if (tileData.isNotEmpty) sink.add(tileData);
    } finally {
      await sink.flush();
      await sink.close();
    }
    if (pmtiles.existsSync()) pmtiles.deleteSync();
    tmp.renameSync(pmtiles.path);
  }

  // ---------------------------------------------------------------------------
  // Private helpers.
  // ---------------------------------------------------------------------------

  static Uint8List _slice(Uint8List bytes, int offset, int length) {
    if (length == 0) return Uint8List(0);
    return Uint8List.fromList(bytes.sublist(offset, offset + length));
  }

  static _Header _parseHeader(Uint8List bytes) {
    if (bytes.length < headerBytes) {
      throw FormatException(
        'PMTiles file too short: ${bytes.length} bytes, need $headerBytes.',
      );
    }
    for (var i = 0; i < _magic.length; i++) {
      if (bytes[i] != _magic[i]) {
        throw FormatException(
          'Not a PMTiles v3 file: magic mismatch at byte $i '
          '(got 0x${bytes[i].toRadixString(16).padLeft(2, '0')}, '
          'expected 0x${_magic[i].toRadixString(16).padLeft(2, '0')}).',
        );
      }
    }
    final view = ByteData.sublistView(bytes, 0, headerBytes);
    return _Header(
      rootDirOffset: view.getUint64(8, Endian.little),
      rootDirBytes: view.getUint64(16, Endian.little),
      metadataOffset: view.getUint64(24, Endian.little),
      metadataBytes: view.getUint64(32, Endian.little),
      leafDirsOffset: view.getUint64(40, Endian.little),
      leafDirsBytes: view.getUint64(48, Endian.little),
      tileDataOffset: view.getUint64(56, Endian.little),
      tileDataBytes: view.getUint64(64, Endian.little),
      internalCompression: bytes[97],
      // Preserve bytes 72..127 verbatim (num_addressed_tiles + zoom +
      // bounds + centre — none of which we touch here).
      rawTail: Uint8List.fromList(bytes.sublist(72, headerBytes)),
    );
  }

  static Map<String, dynamic> _readMetadataFromBytes(
    Uint8List bytes,
    _Header header,
  ) {
    if (header.metadataBytes == 0) return <String, dynamic>{};
    final raw = _slice(bytes, header.metadataOffset, header.metadataBytes);
    final decompressed = _decompress(raw, header.internalCompression);
    final jsonStr = utf8.decode(decompressed);
    final parsed = jsonDecode(jsonStr);
    if (parsed is! Map<String, dynamic>) {
      throw FormatException(
        'PMTiles metadata is not a JSON object: ${parsed.runtimeType}',
      );
    }
    return parsed;
  }

  static List<int> _decompress(Uint8List raw, int compression) {
    switch (compression) {
      case _compressionNone:
        return raw;
      case _compressionGzip:
        return gzip.decode(raw);
      case _compressionUnknown:
        // Some tippecanoe builds emit 0 (Unknown) but the data is gzip.
        // Try gzip first; fall back to raw on failure.
        try {
          return gzip.decode(raw);
        } on Object {
          return raw;
        }
      default:
        throw UnsupportedError(
          'PMTiles internal_compression=$compression not supported '
          '(only None=1 and Gzip=2).',
        );
    }
  }

  static Uint8List _encodeMetadata(
    Map<String, dynamic> meta,
    int compression,
  ) {
    final jsonStr = jsonEncode(meta);
    final utf8Bytes = utf8.encode(jsonStr);
    switch (compression) {
      case _compressionNone:
        return Uint8List.fromList(utf8Bytes);
      case _compressionGzip:
      case _compressionUnknown:
        return Uint8List.fromList(gzip.encode(utf8Bytes));
      default:
        throw UnsupportedError(
          'PMTiles internal_compression=$compression not supported.',
        );
    }
  }

  static Uint8List _writeHeader(
    _Header prev, {
    required int rootDirOffset,
    required int rootDirBytes,
    required int metadataOffset,
    required int metadataBytes,
    required int leafDirsOffset,
    required int leafDirsBytes,
    required int tileDataOffset,
    required int tileDataBytes,
  }) {
    final out = Uint8List(headerBytes)
      ..setRange(0, _magic.length, _magic);
    ByteData.sublistView(out)
      ..setUint64(8, rootDirOffset, Endian.little)
      ..setUint64(16, rootDirBytes, Endian.little)
      ..setUint64(24, metadataOffset, Endian.little)
      ..setUint64(32, metadataBytes, Endian.little)
      ..setUint64(40, leafDirsOffset, Endian.little)
      ..setUint64(48, leafDirsBytes, Endian.little)
      ..setUint64(56, tileDataOffset, Endian.little)
      ..setUint64(64, tileDataBytes, Endian.little);
    // Copy bytes 72..127 verbatim from prev header
    // (num_addressed_tiles + zoom + bounds + centre — untouched).
    out.setRange(72, headerBytes, prev.rawTail);
    return out;
  }
}

/// Parsed subset of a PMTiles v3 header — the eight u64 offset/size fields
/// plus the internal compression byte. Everything after byte 72 is copied
/// verbatim via [rawTail].
class _Header {
  _Header({
    required this.rootDirOffset,
    required this.rootDirBytes,
    required this.metadataOffset,
    required this.metadataBytes,
    required this.leafDirsOffset,
    required this.leafDirsBytes,
    required this.tileDataOffset,
    required this.tileDataBytes,
    required this.internalCompression,
    required this.rawTail,
  });

  final int rootDirOffset;
  final int rootDirBytes;
  final int metadataOffset;
  final int metadataBytes;
  final int leafDirsOffset;
  final int leafDirsBytes;
  final int tileDataOffset;
  final int tileDataBytes;
  final int internalCompression;
  final Uint8List rawTail;
}
