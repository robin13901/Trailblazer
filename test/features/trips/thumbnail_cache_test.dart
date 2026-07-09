import 'dart:io';
import 'dart:typed_data';

import 'package:auto_explore/features/trips/data/thumbnail_cache.dart';
import 'package:auto_explore/features/trips/data/thumbnail_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Minimal valid PNG magic-number prefix — used only to distinguish thumbnail
/// bytes from other test payloads. Not a real PNG.
final Uint8List _fakePng = Uint8List.fromList(<int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
]);

Uint8List _fakePngBytesFor(int tripId) => Uint8List.fromList(<int>[
      ..._fakePng,
      tripId & 0xFF,
    ]);

/// Tests for [ThumbnailCache].
///
/// Uses a factory seam (`thumbnailDirectoryFactoryProvider`) pointed at a
/// throwaway temp dir so tests run without any `path_provider` platform
/// channel setup.
void main() {
  late Directory tempRoot;
  late ProviderContainer container;

  ProviderContainer buildContainer(Directory dir) => ProviderContainer(
        overrides: [
          thumbnailDirectoryFactoryProvider.overrideWithValue(
            () async => dir,
          ),
        ],
      );

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('thumb_cache_test_');
    container = buildContainer(tempRoot);
  });

  tearDown(() async {
    container.dispose();
    if (tempRoot.existsSync()) {
      tempRoot.deleteSync(recursive: true);
    }
  });

  group('ThumbnailCache', () {
    test('store persists PNG for tripId and pathFor returns the path',
        () async {
      final cache = container.read(thumbnailCacheProvider.notifier);
      final storedPath = await cache.store(1, _fakePngBytesFor(1));

      expect(storedPath, endsWith('${p.separator}1.png'));
      expect(cache.pathFor(1), storedPath);
      expect(File(storedPath).existsSync(), isTrue);
      expect(File(storedPath).lengthSync(), _fakePngBytesFor(1).length);
    });

    test('delete removes the on-disk file and drops the index entry',
        () async {
      final cache = container.read(thumbnailCacheProvider.notifier);
      final storedPath = await cache.store(2, _fakePngBytesFor(2));

      expect(File(storedPath).existsSync(), isTrue);

      await cache.delete(2);

      expect(cache.pathFor(2), isNull);
      expect(File(storedPath).existsSync(), isFalse);
    });

    test('delete for an unknown tripId is idempotent', () async {
      final cache = container.read(thumbnailCacheProvider.notifier);
      await cache.ensureLoaded();

      // Should not throw and should leave state empty.
      await cache.delete(9999);

      expect(cache.pathFor(9999), isNull);
      expect(container.read(thumbnailCacheProvider).paths, isEmpty);
    });

    test('clear removes every cached thumbnail file and clears the index',
        () async {
      final cache = container.read(thumbnailCacheProvider.notifier);
      await cache.store(10, _fakePngBytesFor(10));
      await cache.store(11, _fakePngBytesFor(11));

      expect(cache.pathFor(10), isNotNull);
      expect(cache.pathFor(11), isNotNull);

      await cache.clear();

      expect(container.read(thumbnailCacheProvider).paths, isEmpty);
      expect(cache.pathFor(10), isNull);
      expect(cache.pathFor(11), isNull);

      // Files gone from disk too.
      final remaining = tempRoot
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.png'))
          .toList();
      expect(remaining, isEmpty);
    });

    test(
      'reinstantiating the cache with existing files repopulates the index',
      () async {
        // Seed the temp dir directly (as if a prior process had rendered
        // thumbnails).
        File(p.join(tempRoot.path, '42.png'))
            .writeAsBytesSync(_fakePngBytesFor(42));
        File(p.join(tempRoot.path, '43.png'))
            .writeAsBytesSync(_fakePngBytesFor(43));
        // A non-numeric filename must be ignored.
        File(p.join(tempRoot.path, 'notrip.png'))
            .writeAsBytesSync(_fakePng);
        // A non-PNG file must be ignored.
        File(p.join(tempRoot.path, '99.txt')).writeAsStringSync('nope');

        final freshContainer = buildContainer(tempRoot);
        addTearDown(freshContainer.dispose);

        final fresh = freshContainer.read(thumbnailCacheProvider.notifier);
        await fresh.ensureLoaded();

        expect(fresh.pathFor(42), endsWith('${p.separator}42.png'));
        expect(fresh.pathFor(43), endsWith('${p.separator}43.png'));
        expect(fresh.pathFor(99), isNull);
        // Only the two real trip ids were indexed.
        expect(
          freshContainer.read(thumbnailCacheProvider).paths.keys,
          {42, 43},
        );
      },
    );
  });
}
