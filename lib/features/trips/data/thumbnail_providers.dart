import 'dart:io';

import 'package:auto_explore/features/trips/data/thumbnail_cache.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Factory that returns the on-disk base directory for cached trip thumbnails.
///
/// Production default: `<AppDocsDir>/thumbs/`. Tests inject an alternative
/// factory (typically pointing at a `Directory.systemTemp.createTempSync(...)`
/// path) via `ProviderScope.overrides` / `ProviderContainer(overrides:)`.
///
/// Plain [Provider] — no `@Riverpod` codegen (STATE.md Plan 01-01 decision).
final thumbnailDirectoryFactoryProvider =
    Provider<Future<Directory> Function()>((ref) {
  return () async {
    final docs = await getApplicationDocumentsDirectory();
    return Directory(p.join(docs.path, 'thumbs'));
  };
});

/// Provider for the singleton [ThumbnailCache] notifier.
///
/// Plain [NotifierProvider] — no `@Riverpod` codegen (STATE.md Plan 01-01
/// decision).
final thumbnailCacheProvider =
    NotifierProvider<ThumbnailCache, ThumbnailCacheState>(ThumbnailCache.new);
