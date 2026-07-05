/// Minimal protobuf wire-format WRITER — mirror of `proto_reader.dart`.
///
/// Only used by the fixture generator (`test/fixtures/build_tiny_pbf.dart`),
/// so it lives under `test/fixtures/`, not under `lib/pbf/`. Production
/// code never writes PBF — it only reads.
///
/// Supports the same subset the reader does: wire type 0 (varint) and wire
/// type 2 (length-delimited). Just enough to author a valid `.osm.pbf`
/// blob-header + primitive-block payload.
library;

import 'dart:convert';
import 'dart:typed_data';

/// Grows an internal byte buffer as callers `writeXxx` protobuf fields into it.
class ProtoWriter {
  final BytesBuilder _b = BytesBuilder(copy: false);

  /// The bytes written so far, as a fresh `Uint8List`.
  Uint8List takeBytes() => _b.toBytes();

  /// Write a (fieldNumber, wireType) tag header as a varint.
  void writeTag(int fieldNumber, int wireType) {
    _writeVarint((fieldNumber << 3) | wireType);
  }

  /// Write an unsigned varint value.
  void writeVarint(int fieldNumber, int value) {
    writeTag(fieldNumber, 0);
    _writeVarint(value);
  }

  /// Write a zig-zag-encoded signed varint value.
  void writeSignedVarint(int fieldNumber, int value) {
    writeTag(fieldNumber, 0);
    _writeVarint((value << 1) ^ (value >> 63));
  }

  /// Write a length-delimited byte payload (bytes, string, embedded message).
  void writeBytes(int fieldNumber, List<int> bytes) {
    writeTag(fieldNumber, 2);
    _writeVarint(bytes.length);
    _b.add(bytes);
  }

  /// Write a length-delimited UTF-8 string.
  void writeString(int fieldNumber, String value) {
    writeBytes(fieldNumber, utf8.encode(value));
  }

  /// Write a packed repeated unsigned varint field.
  void writePackedVarints(int fieldNumber, List<int> values) {
    final inner = ProtoWriter();
    for (final v in values) {
      inner._writeVarint(v);
    }
    writeBytes(fieldNumber, inner.takeBytes());
  }

  /// Write a packed repeated signed varint field (zig-zag).
  void writePackedSignedVarints(int fieldNumber, List<int> values) {
    final inner = ProtoWriter();
    for (final v in values) {
      inner._writeVarint((v << 1) ^ (v >> 63));
    }
    writeBytes(fieldNumber, inner.takeBytes());
  }

  /// Write raw bytes verbatim (no field header). Escape hatch for the
  /// outer 4-byte big-endian length prefix at the PBF blob boundary.
  void writeRaw(List<int> bytes) {
    _b.add(bytes);
  }

  void _writeVarint(int value) {
    var v = value;
    // Handle negative values via two's-complement 64-bit representation.
    // Protobuf specifies that a raw varint for a negative int is always
    // 10 bytes long. We rely on Dart-int arithmetic being 64-bit on the VM.
    while ((v & ~0x7F) != 0) {
      _b.addByte((v & 0x7F) | 0x80);
      v = _unsignedShiftRight(v, 7);
    }
    _b.addByte(v & 0x7F);
  }

  int _unsignedShiftRight(int value, int shift) {
    // Dart's `>>` sign-extends; simulate `>>>` for 64-bit ints.
    if (value >= 0) return value >> shift;
    return (value >> shift) & ((1 << (64 - shift)) - 1);
  }
}
