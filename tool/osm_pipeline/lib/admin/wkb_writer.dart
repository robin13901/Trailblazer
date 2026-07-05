/// OGC Well-Known Binary (WKB) encoder for [MultiPolygon].
///
/// Implements only the flat WKB variant (no SRID / EWKB prefix) — we live in
/// EPSG:4326 exclusively. Little-endian byte order for consistency with
/// SpatiaLite and PostGIS defaults.
///
/// See OGC 06-103r4 §8.2.7 for the multipolygon wire shape. This encoder is
/// deterministic: identical input → byte-identical output.
library;

import 'dart:typed_data';

import 'package:osm_pipeline/admin/geometry.dart';

const int _wkbNdr = 1; // little-endian byte order flag
const int _wkbPolygon = 3;
const int _wkbMultiPolygon = 6;

/// Encodes [mp] as WKB.
///
/// Layout:
///   byte 1     : byte order = 1 (little-endian)
///   uint32 6   : type = MultiPolygon
///   uint32 N   : polygon count
///   for each polygon:
///     byte 1   : byte order = 1
///     uint32 3 : type = Polygon
///     uint32 R : ring count (outer + inners)
///     for each ring:
///       uint32 M : point count
///       for each point:
///         float64 lng
///         float64 lat
Uint8List encodeMultiPolygon(MultiPolygon mp) {
  // Pre-compute the exact byte length so we can allocate once.
  var bytes = 1 + 4 + 4; // header: byte order + type + polygon count
  for (final poly in mp.polygons) {
    bytes += 1 + 4 + 4; // polygon header: byte order + type + ring count
    bytes += 4 + poly.outer.length * 16; // outer ring: point count + points
    for (final hole in poly.holes) {
      bytes += 4 + hole.length * 16;
    }
  }

  final buf = ByteData(bytes);
  var offset = 0;

  buf.setUint8(offset, _wkbNdr);
  offset += 1;
  buf.setUint32(offset, _wkbMultiPolygon, Endian.little);
  offset += 4;
  buf.setUint32(offset, mp.polygons.length, Endian.little);
  offset += 4;

  for (final poly in mp.polygons) {
    buf.setUint8(offset, _wkbNdr);
    offset += 1;
    buf.setUint32(offset, _wkbPolygon, Endian.little);
    offset += 4;
    buf.setUint32(offset, 1 + poly.holes.length, Endian.little);
    offset += 4;

    // Outer ring.
    offset = _writeRing(buf, offset, poly.outer);
    for (final hole in poly.holes) {
      offset = _writeRing(buf, offset, hole);
    }
  }

  assert(offset == bytes, 'WKB length mismatch');
  return buf.buffer.asUint8List();
}

int _writeRing(ByteData buf, int offset, List<Point> ring) {
  var o = offset;
  buf.setUint32(o, ring.length, Endian.little);
  o += 4;
  for (final p in ring) {
    buf.setFloat64(o, p.lng, Endian.little);
    o += 8;
    buf.setFloat64(o, p.lat, Endian.little);
    o += 8;
  }
  return o;
}
