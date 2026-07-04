import 'package:auto_explore/features/map/data/tile_server.dart';

/// A [TileServer] subclass that reports [isRunning] = true without binding
/// a real socket. Used in widget tests where real HTTP is not needed.
class FakeTileServer extends TileServer {
  FakeTileServer() : super();

  bool _running = false;

  @override
  bool get isRunning => _running;

  @override
  Future<void> start() async {
    _running = true;
  }

  @override
  Future<void> stop() async {
    _running = false;
  }
}
