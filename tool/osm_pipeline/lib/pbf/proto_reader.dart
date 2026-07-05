/// Minimal protobuf wire-format decoder — only the pieces the OSM PBF reader
/// needs. Not a general-purpose replacement for `package:protobuf`.
///
/// Supported wire types:
///   * 0 (VARINT) — variable-length integers (int32, int64, uint32, uint64,
///     sint32, sint64, bool, enum)
///   * 2 (LENGTH_DELIMITED) — bytes / string / embedded messages / packed
///     repeated fields
///
/// Not supported: wire types 1 (64-bit fixed), 5 (32-bit fixed), 3/4
/// (deprecated groups). The PBF spec never uses these.
///
/// See: https://protobuf.dev/programming-guides/encoding/
library;

import 'dart:typed_data';

/// Protobuf wire type enum.
class ProtoWireType {
  ProtoWireType._();

  /// Variable-length integer (int32/int64/uint32/uint64/sint32/sint64/bool).
  static const int varint = 0;

  /// Length-delimited (bytes, string, embedded message, packed repeated).
  static const int lengthDelimited = 2;
}

/// Cursor-style reader over a `Uint8List` of protobuf-encoded bytes.
///
/// Callers pull one field at a time via [readTag] and then decode the value
/// according to that field's declared type. On unknown fields, [skipField]
/// advances past the value.
class ProtoReader {
  /// Wrap [bytes]; reads start at offset 0.
  ProtoReader(this.bytes) : _byteData = ByteData.sublistView(bytes);

  /// The underlying byte buffer. Kept as `Uint8List` so slice operations
  /// (via [readLengthDelimited]) return zero-copy `sublistView`s.
  final Uint8List bytes;
  final ByteData _byteData;

  /// Current cursor offset (0-based, in bytes).
  int get offset => _offset;
  int _offset = 0;

  /// True when the cursor has reached the end of [bytes].
  bool get isAtEnd => _offset >= bytes.length;

  /// Reads the next varint (up to 10 bytes) as an `int`.
  ///
  /// Throws [FormatException] on truncated input or on a varint that would
  /// require more than 10 bytes (protobuf spec upper bound).
  int readVarint() {
    var result = 0;
    var shift = 0;
    while (shift < 64) {
      if (_offset >= bytes.length) {
        throw FormatException(
          'Truncated varint at offset $_offset (buffer length ${bytes.length})',
        );
      }
      final b = bytes[_offset++];
      result |= (b & 0x7F) << shift;
      if ((b & 0x80) == 0) return result;
      shift += 7;
    }
    throw FormatException('Varint exceeds 10 bytes at offset $_offset');
  }

  /// Reads a signed varint using protobuf's `sint32`/`sint64` zig-zag scheme.
  int readSignedVarint() {
    final raw = readVarint();
    // ZigZag decode: (n >>> 1) ^ -(n & 1)
    return (raw >> 1) ^ -(raw & 1);
  }

  /// Reads a `(tag, wire_type)` pair from the varint stream. Returns null
  /// when the cursor has reached the end of the buffer (clean EOF).
  ProtoTag? readTag() {
    if (isAtEnd) return null;
    final combined = readVarint();
    return ProtoTag(fieldNumber: combined >> 3, wireType: combined & 0x7);
  }

  /// Reads a length-delimited value and returns a zero-copy view of its
  /// bytes. The returned `Uint8List` shares the underlying buffer.
  Uint8List readLengthDelimited() {
    final length = readVarint();
    if (_offset + length > bytes.length) {
      throw FormatException(
        'Length-delimited field length $length exceeds buffer '
        '(offset $_offset, buffer length ${bytes.length})',
      );
    }
    final view = Uint8List.sublistView(bytes, _offset, _offset + length);
    _offset += length;
    return view;
  }

  /// Reads a UTF-8-encoded length-delimited string.
  String readString() {
    final bytes = readLengthDelimited();
    return String.fromCharCodes(bytes);
  }

  /// Skips a field with the given [wireType] — used to ignore unknown or
  /// unwanted fields without decoding them.
  void skipField(int wireType) {
    switch (wireType) {
      case ProtoWireType.varint:
        readVarint();
      case ProtoWireType.lengthDelimited:
        final len = readVarint();
        _offset += len;
      default:
        throw FormatException(
          'Unsupported wire type $wireType at offset $_offset',
        );
    }
  }

  /// Big-endian uint32 read (used for the PBF blob-header length prefix
  /// which sits *outside* the protobuf-encoded stream).
  int readBigEndianUint32() {
    if (_offset + 4 > bytes.length) {
      throw const FormatException('Truncated 4-byte big-endian prefix');
    }
    final v = _byteData.getUint32(_offset);
    _offset += 4;
    return v;
  }

  /// Reads a packed repeated varint field's payload (a length-delimited
  /// field whose interior is a stream of varints) into a plain `List<int>`.
  List<int> readPackedVarints() {
    final payload = readLengthDelimited();
    final inner = ProtoReader(payload);
    final out = <int>[];
    while (!inner.isAtEnd) {
      out.add(inner.readVarint());
    }
    return out;
  }

  /// Reads a packed repeated signed-varint field (zig-zag) into a plain
  /// `List<int>`.
  List<int> readPackedSignedVarints() {
    final payload = readLengthDelimited();
    final inner = ProtoReader(payload);
    final out = <int>[];
    while (!inner.isAtEnd) {
      out.add(inner.readSignedVarint());
    }
    return out;
  }
}

/// A decoded `(fieldNumber, wireType)` protobuf tag header.
class ProtoTag {
  /// Create a tag header.
  const ProtoTag({required this.fieldNumber, required this.wireType});

  /// The protobuf field number (1-based).
  final int fieldNumber;

  /// The protobuf wire type (0 = varint, 2 = length-delimited).
  final int wireType;
}
