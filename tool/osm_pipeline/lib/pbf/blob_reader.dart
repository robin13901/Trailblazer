import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:osm_pipeline/cli/errors.dart';
import 'package:osm_pipeline/pbf/proto_reader.dart';

/// A single decompressed PBF block, tagged by its declared type.
///
/// The PBF file format is a sequence of blob pairs:
///   4-byte big-endian length prefix → BlobHeader (protobuf) → Blob (protobuf)
///
/// The BlobHeader carries the [type] string (`OSMHeader` or `OSMData`) plus
/// the byte length of the following Blob. The Blob wraps either raw bytes or
/// a zlib-compressed payload. `BlobReader.readNext` returns the decompressed
/// bytes alongside the declared type — the caller decides how to decode them.
class RawBlock {
  /// Create a raw block.
  const RawBlock({required this.type, required this.bytes});

  /// Blob type declared in the BlobHeader — canonically `OSMHeader` or
  /// `OSMData`. Unknown types are surfaced verbatim so the reader can skip
  /// them.
  final String type;

  /// Decompressed protobuf payload of the block.
  final Uint8List bytes;
}

/// Streaming PBF blob reader.
///
/// Reads one blob at a time from a [RandomAccessFile]. Windows-compatible;
/// isolate-portable (no `dart:io` globals, no static mutable state).
abstract final class BlobReader {
  static const int _blobHeaderMaxLength = 64 * 1024;
  static const int _blobPayloadMaxLength = 64 * 1024 * 1024;

  /// Reads the next blob from [raf] and returns its decompressed payload.
  ///
  /// Returns `null` at clean EOF. Throws [PipelineError] with the source
  /// byte offset on any malformed header, truncated payload, or zlib decode
  /// failure — never silently swallows.
  static Future<RawBlock?> readNext(RandomAccessFile raf) async {
    final startOffset = await raf.position();

    // 1. Four-byte big-endian BlobHeader length prefix. Clean EOF is fine
    //    right here — a truncated read *inside* the prefix is not.
    final prefix = await raf.read(4);
    if (prefix.isEmpty) return null;
    if (prefix.length < 4) {
      throw PipelineParseError(
        'Truncated BlobHeader length prefix: read ${prefix.length} bytes, '
        'expected 4',
        sourceOffset: startOffset,
      );
    }
    final headerLength =
        ByteData.sublistView(Uint8List.fromList(prefix)).getUint32(0);
    if (headerLength == 0 || headerLength > _blobHeaderMaxLength) {
      throw PipelineParseError(
        'Implausible BlobHeader length: $headerLength bytes '
        '(max $_blobHeaderMaxLength)',
        sourceOffset: startOffset,
      );
    }

    // 2. BlobHeader protobuf.
    final headerBytes = await raf.read(headerLength);
    if (headerBytes.length != headerLength) {
      throw PipelineParseError(
        'Truncated BlobHeader: read ${headerBytes.length} bytes, '
        'expected $headerLength',
        sourceOffset: startOffset,
      );
    }
    final _BlobHeaderFields header;
    try {
      header = _decodeBlobHeader(Uint8List.fromList(headerBytes));
    } on FormatException catch (e, st) {
      throw PipelineParseError(
        'Malformed BlobHeader: ${e.message}',
        sourceOffset: startOffset,
        cause: e,
        stackTrace: st,
      );
    }

    if (header.datasize <= 0 || header.datasize > _blobPayloadMaxLength) {
      throw PipelineParseError(
        'Implausible Blob datasize: ${header.datasize} bytes '
        '(max $_blobPayloadMaxLength)',
        sourceOffset: startOffset,
      );
    }

    // 3. Blob protobuf (datasize bytes).
    final blobBytes = await raf.read(header.datasize);
    if (blobBytes.length != header.datasize) {
      throw PipelineParseError(
        'Truncated Blob: read ${blobBytes.length} bytes, '
        'expected ${header.datasize}',
        sourceOffset: startOffset,
      );
    }
    final _BlobFields blob;
    try {
      blob = _decodeBlob(Uint8List.fromList(blobBytes));
    } on FormatException catch (e, st) {
      throw PipelineParseError(
        'Malformed Blob: ${e.message}',
        sourceOffset: startOffset,
        cause: e,
        stackTrace: st,
      );
    }

    // 4. Extract the payload — either raw or zlib-decompressed.
    final Uint8List payload;
    if (blob.rawData != null) {
      payload = blob.rawData!;
    } else if (blob.zlibData != null) {
      try {
        final decoded = ZLibCodec().decode(blob.zlibData!);
        payload = decoded is Uint8List ? decoded : Uint8List.fromList(decoded);
      } on FormatException catch (e, st) {
        throw PipelineParseError(
          'Zlib decode failed for Blob: ${e.message}',
          sourceOffset: startOffset,
          cause: e,
          stackTrace: st,
        );
      }
      if (blob.rawSize != null && payload.length != blob.rawSize) {
        throw PipelineParseError(
          'Zlib decode produced ${payload.length} bytes; '
          'Blob.raw_size declares ${blob.rawSize}',
          sourceOffset: startOffset,
        );
      }
    } else {
      throw PipelineParseError(
        'Blob has neither raw nor zlib_data payload',
        sourceOffset: startOffset,
      );
    }

    return RawBlock(type: header.type, bytes: payload);
  }

  static _BlobHeaderFields _decodeBlobHeader(Uint8List bytes) {
    final r = ProtoReader(bytes);
    String? type;
    int? datasize;
    while (true) {
      final tag = r.readTag();
      if (tag == null) break;
      switch (tag.fieldNumber) {
        case 1: // required string type
          type = utf8.decode(r.readLengthDelimited());
        case 2: // optional bytes indexdata — skip
          r.skipField(tag.wireType);
        case 3: // required int32 datasize
          datasize = r.readVarint();
        default:
          r.skipField(tag.wireType);
      }
    }
    if (type == null) {
      throw const FormatException('BlobHeader missing required field: type');
    }
    if (datasize == null) {
      throw const FormatException(
        'BlobHeader missing required field: datasize',
      );
    }
    return _BlobHeaderFields(type: type, datasize: datasize);
  }

  static _BlobFields _decodeBlob(Uint8List bytes) {
    final r = ProtoReader(bytes);
    Uint8List? rawData;
    Uint8List? zlibData;
    int? rawSize;
    while (true) {
      final tag = r.readTag();
      if (tag == null) break;
      switch (tag.fieldNumber) {
        case 1: // optional bytes raw
          rawData = r.readLengthDelimited();
        case 2: // optional int32 raw_size
          rawSize = r.readVarint();
        case 3: // optional bytes zlib_data
          zlibData = r.readLengthDelimited();
        default:
          // Other codecs (lzma, bzip2, lz4, zstd) — not currently emitted by
          // Geofabrik or the OSM planet dumps. Skip; downstream fails later
          // if payload is missing.
          r.skipField(tag.wireType);
      }
    }
    return _BlobFields(rawData: rawData, zlibData: zlibData, rawSize: rawSize);
  }
}

class _BlobHeaderFields {
  const _BlobHeaderFields({required this.type, required this.datasize});
  final String type;
  final int datasize;
}

class _BlobFields {
  const _BlobFields({this.rawData, this.zlibData, this.rawSize});
  final Uint8List? rawData;
  final Uint8List? zlibData;
  final int? rawSize;
}
