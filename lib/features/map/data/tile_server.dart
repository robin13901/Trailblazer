import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:pmtiles/pmtiles.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_router/shelf_router.dart';

/// Loopback HTTP server that reads tiles from the bundled PMTiles archive
/// and serves them at http://127.0.0.1:[port]/{z}/{x}/{y}.pbf.
///
/// Why: maplibre_gl 0.26.2 does not natively resolve `pmtiles://` URLs on
/// Android (issue observed during Phase 2 real-device smoke test). Serving
/// via loopback keeps the tile source URL a standard XYZ template and works
/// on both platforms with a unified code path.
class TileServer {
  TileServer({
    this.port = 7070,
    this.assetPath = 'assets/tiles/dev_germany.pmtiles',
  });

  final int port;
  final String assetPath;

  HttpServer? _httpServer;
  PmTilesArchive? _archive;

  bool get isRunning => _httpServer != null;

  /// XYZ tile URL template for use in the style JSON `sources` block.
  String get tileUrlTemplate => 'http://127.0.0.1:$port/{z}/{x}/{y}.pbf';

  /// Start the server.
  ///
  /// Reads the bundled asset into a temp file (PmTilesArchive.from() requires
  /// a filesystem path or HTTP URL; asset bundles are not directly seekable).
  Future<void> start() async {
    if (isRunning) return;

    // Copy asset to a temp file if it doesn't already exist or has changed.
    final byteData = await rootBundle.load(assetPath);
    final bytes = byteData.buffer.asUint8List();
    final tmpFile = File(
      '${Directory.systemTemp.path}/${assetPath.split('/').last}',
    );
    if (!tmpFile.existsSync() || tmpFile.lengthSync() != bytes.length) {
      await tmpFile.writeAsBytes(bytes, flush: true);
    }

    _archive = await PmTilesArchive.from(tmpFile.path);

    final router =
        Router()..get('/<z>/<x>/<y>', _handleTile);
    final pipeline = const Pipeline().addHandler(router.call);

    _httpServer = await io.serve(
      pipeline,
      InternetAddress.loopbackIPv4,
      port,
      shared: true,
    );
  }

  Future<Response> _handleTile(
    Request request,
    String z,
    String x,
    String y,
  ) async {
    final archive = _archive;
    if (archive == null) {
      return Response.internalServerError(body: 'archive not initialized');
    }
    try {
      final zi = int.parse(z);
      final xi = int.parse(x);
      // MapLibre appends .pbf to the y segment when the template ends with
      // {z}/{x}/{y} — strip the extension before parsing.
      final yi = int.parse(y.replaceAll('.pbf', ''));
      final tileId = ZXY(zi, xi, yi).toTileId();
      final tile = await archive.tile(tileId);

      // Serve raw (still-compressed) bytes and declare the encoding so that
      // MapLibre can decompress them. If the archive stores tiles uncompressed,
      // omit the Content-Encoding header.
      final compressed = Uint8List.fromList(tile.compressedBytes());
      final headers = <String, String>{
        'Content-Type': 'application/x-protobuf',
        'Access-Control-Allow-Origin': '*',
      };
      if (tile.compression == Compression.gzip) {
        headers['Content-Encoding'] = 'gzip';
      }
      return Response.ok(compressed, headers: headers);
    } on FormatException catch (e) {
      return Response.badRequest(body: 'bad tile coord: $e');
    } on TileNotFoundException {
      // Missing tile is normal outside the extract's bbox — 204 No Content.
      return Response(204);
    } on Object catch (e) {
      return Response.notFound('tile not found: $e');
    }
  }

  Future<void> stop() async {
    await _httpServer?.close(force: true);
    _httpServer = null;
    await _archive?.close();
    _archive = null;
  }
}
