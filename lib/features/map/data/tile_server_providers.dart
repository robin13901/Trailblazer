import 'package:auto_explore/features/map/data/tile_server.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Async-started [TileServer]. The map widget watches this provider and shows a
/// placeholder until the future resolves (i.e. the loopback socket is ready).
///
/// Using a plain [FutureProvider] — no @Riverpod codegen per Phase 1 decision.
final tileServerProvider = FutureProvider<TileServer>((ref) async {
  final server = TileServer();
  await server.start();
  ref.onDispose(() async {
    await server.stop();
  });
  return server;
});
