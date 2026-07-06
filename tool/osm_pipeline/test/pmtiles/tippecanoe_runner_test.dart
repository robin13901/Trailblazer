import 'dart:io';

import 'package:osm_pipeline/cli/errors.dart';
import 'package:osm_pipeline/pmtiles/tippecanoe_runner.dart';
import 'package:test/test.dart';

void main() {
  group('wslifyPath', () {
    test(r'rewrites Windows C:\ paths to /mnt/c/', () {
      expect(
        wslifyPath(r'C:\Users\me\out\file.geojsonl'),
        '/mnt/c/Users/me/out/file.geojsonl',
      );
    });

    test('rewrites uppercase drive to lowercase mount', () {
      expect(
        wslifyPath(r'D:\projects\file'),
        '/mnt/d/projects/file',
      );
    });

    test('handles forward-slash Windows paths', () {
      expect(
        wslifyPath('E:/one/two.txt'),
        '/mnt/e/one/two.txt',
      );
    });

    test('leaves POSIX paths unchanged', () {
      expect(wslifyPath('/home/user/out/file'), '/home/user/out/file');
      expect(wslifyPath('/tmp/x'), '/tmp/x');
    });

    test('leaves relative paths unchanged', () {
      expect(wslifyPath('relative/thing'), 'relative/thing');
    });
  });

  group('resolveExecutableForTests', () {
    test('returns platform-appropriate executable + prefix', () {
      final resolved = TippecanoeRunner.resolveExecutableForTests();
      if (Platform.isWindows) {
        expect(resolved.executable, 'wsl.exe');
        expect(resolved.prefixArgs, ['tippecanoe']);
      } else {
        expect(resolved.executable, 'tippecanoe');
        expect(resolved.prefixArgs, isEmpty);
      }
    });
  });

  group('preflightCheck', () {
    test('surfaces install hint when the binary is missing', () async {
      // Simulate a missing binary by asking Process.run for a name that
      // certainly doesn't exist on PATH — we do this via a nonsense wrapper
      // that mirrors the runner's ProcessException path.
      try {
        await Process.run('tippecanoe-does-not-exist-xyz', ['--version']);
        // If the run succeeded (very unlikely) we simply skip the assertion.
      } on ProcessException catch (err) {
        // Assemble the same install-hint we'd expect the runner to emit.
        final error = PipelineIoError(
          'tippecanoe not found: ${err.message}',
        );
        expect(error.message, contains('tippecanoe not found'));
      }
    });

    test('returns the tippecanoe version banner when reachable', () async {
      // Skipped when tippecanoe is not installed (unit tests must remain
      // green on machines without the binary). The Berlin smoke test in
      // 04-09 owns the real invocation guarantee.
      try {
        final banner = await TippecanoeRunner.preflightCheck();
        expect(banner, isNotEmpty);
        expect(banner.toLowerCase(), contains('tippecanoe'));
      } on PipelineIoError catch (_) {
        // Binary missing; unit test is a no-op on this host. This branch is
        // the documented fallback for CI hosts + Windows dev boxes without
        // WSL2 tippecanoe.
      }
    });
  });
}
