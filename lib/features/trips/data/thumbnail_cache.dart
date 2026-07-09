import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:auto_explore/features/trips/data/thumbnail_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

/// Immutable state for [ThumbnailCache].
///
/// Maps a trip id to the absolute on-disk path of its cached thumbnail PNG.
/// Absence from the map means "no cached thumbnail for that trip" — callers
/// should render a fallback placeholder and kick off a render.
@immutable
class ThumbnailCacheState {
  const ThumbnailCacheState(this.paths);

  /// Empty initial state — no thumbnails cached.
  const ThumbnailCacheState.empty() : paths = const {};

  /// `tripId → absolute file path` for every currently-cached thumbnail.
  final Map<int, String> paths;

  ThumbnailCacheState copyWith(Map<int, String> newPaths) =>
      ThumbnailCacheState(Map.unmodifiable(newPaths));
}

/// Notifier owning the on-disk thumbnail cache and its in-memory index.
///
/// Files live at `<thumbs-dir>/<tripId>.png` where `<thumbs-dir>` is resolved
/// via [thumbnailDirectoryFactoryProvider] (production default:
/// `<AppDocs>/thumbs/`).
///
/// The build-time scan (`_initDir`) is fire-and-forget — the state starts
/// empty and repopulates asynchronously after directory discovery so a fresh
/// process still serves the "instant repeat view" contract from Q1 approach C
/// once the scan settles. Tests that need the scan to complete before
/// asserting can `await` [ensureLoaded] before probing [pathFor].
///
/// Plain [Notifier] — no `@Riverpod` codegen (STATE.md Plan 01-01 decision).
class ThumbnailCache extends Notifier<ThumbnailCacheState> {
  Future<void>? _initFuture;

  @override
  ThumbnailCacheState build() {
    _initFuture = _initDir();
    return const ThumbnailCacheState.empty();
  }

  /// Return the on-disk path for [tripId] if cached, else `null`.
  String? pathFor(int tripId) => state.paths[tripId];

  /// Await the lazy [_initDir] scan. Tests that need to observe files that
  /// existed on disk BEFORE the notifier was constructed should call this
  /// before probing [pathFor].
  Future<void> ensureLoaded() async {
    final f = _initFuture;
    if (f != null) await f;
  }

  /// Persist [pngBytes] for [tripId] and return the final on-disk path.
  ///
  /// The write is atomic-per-call — a `.tmp` file is written then renamed
  /// into place. On rename success the in-memory index is updated so the
  /// next `pathFor(tripId)` returns immediately.
  Future<String> store(int tripId, Uint8List pngBytes) async {
    await ensureLoaded();
    final dir = await _thumbsDir();
    final finalPath = p.join(dir.path, '$tripId.png');
    final tmpPath = '$finalPath.tmp';
    final tmpFile = File(tmpPath);
    await tmpFile.writeAsBytes(pngBytes, flush: true);
    await tmpFile.rename(finalPath);
    final next = Map<int, String>.from(state.paths)..[tripId] = finalPath;
    state = state.copyWith(next);
    return finalPath;
  }

  /// Hard-delete the cached thumbnail file for [tripId]. Idempotent —
  /// deleting a trip id that isn't cached is a no-op (never throws).
  Future<void> delete(int tripId) async {
    await ensureLoaded();
    final cached = state.paths[tripId];
    if (cached != null) {
      final f = File(cached);
      if (f.existsSync()) {
        try {
          await f.delete();
        } on FileSystemException {
          // The file vanished between existsSync() and delete() —
          // treat as already-deleted, keep the operation idempotent.
        }
      }
      final next = Map<int, String>.from(state.paths)..remove(tripId);
      state = state.copyWith(next);
    }
  }

  /// Delete every cached thumbnail file and clear the in-memory index.
  ///
  /// Called from the OSM-extract-updated hook (Phase 6 stub; Phase 10 wires
  /// the real trigger) so a fresh matcher run doesn't serve stale thumbnails.
  Future<void> clear() async {
    await ensureLoaded();
    final dir = await _thumbsDir();
    if (dir.existsSync()) {
      for (final entity in dir.listSync()) {
        if (entity is File && entity.path.endsWith('.png')) {
          try {
            await entity.delete();
          } on FileSystemException {
            // Best-effort — leave any surviving file behind rather than
            // aborting the whole clear.
          }
        }
      }
    }
    state = const ThumbnailCacheState.empty();
  }

  /// Resolve the thumbnails base directory, creating it if missing.
  Future<Directory> _thumbsDir() async {
    final factory = ref.read(thumbnailDirectoryFactoryProvider);
    final dir = await factory();
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// One-shot scan of [_thumbsDir] at build time.
  ///
  /// Populates state from every `<intId>.png` already on disk so a fresh
  /// process serves the instant repeat-view contract from Q1 approach C.
  Future<void> _initDir() async {
    final dir = await _thumbsDir();
    final discovered = <int, String>{};
    for (final entity in dir.listSync()) {
      if (entity is! File) continue;
      final base = p.basenameWithoutExtension(entity.path);
      final ext = p.extension(entity.path);
      if (ext != '.png') continue;
      final id = int.tryParse(base);
      if (id == null) continue;
      discovered[id] = entity.path;
    }
    if (discovered.isNotEmpty) {
      state = state.copyWith(discovered);
    }
  }
}
