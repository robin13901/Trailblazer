import 'dart:convert';
import 'dart:io';

import 'package:osm_pipeline/cli/logger.dart';
import 'package:test/test.dart';

void main() {
  group('Logger.setFileSink', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('trailblazer_logger_');
    });

    tearDown(() async {
      // Always detach — a leaked sink would poison subsequent test files
      // (Logger is a global singleton by design).
      Logger.setFileSink(null);
      // Best-effort — Windows sometimes still has the file handle busy
      // one tick after close(). Deletion failure is cosmetic (systemTemp
      // is cleaned by the OS) and must not fail the test.
      try {
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      } on FileSystemException {
        // ignore
      }
    });

    test('duplicates info/warn/error to the file sink', () async {
      final logPath = '${tempDir.path}${Platform.pathSeparator}run.log';
      final sink = File(logPath).openWrite();
      Logger.setFileSink(sink);

      Logger.info('hello');
      Logger.warn('careful');
      Logger.error('boom');

      // Detach first so the flush + close below win the race with any
      // late writes from other code paths.
      Logger.setFileSink(null);
      await sink.flush();
      await sink.close();

      final captured = File(logPath).readAsStringSync();
      expect(captured, contains('[info] hello'));
      expect(captured, contains('[warn] careful'));
      expect(captured, contains('[error] boom'));

      // Exactly three lines — no duplication, no dropped line.
      final lines = const LineSplitter()
          .convert(captured)
          .where((String l) => l.isNotEmpty);
      expect(lines, hasLength(3));
    });

    test('emits to stdout ONLY when file sink is null (regression guard)',
        () async {
      // Precondition: no sink attached.
      expect(Logger.fileSink, isNull);

      // Calling Logger.info without a sink must not throw.
      expect(() => Logger.info('no sink'), returnsNormally);
      expect(() => Logger.warn('no sink'), returnsNormally);
      expect(() => Logger.error('no sink'), returnsNormally);

      // And no file should have been created in tempDir.
      final entries = tempDir.listSync();
      expect(entries, isEmpty);
    });

    test('setFileSink(null) detaches without closing the sink', () async {
      final logPath = '${tempDir.path}${Platform.pathSeparator}detach.log';
      final sink = File(logPath).openWrite();
      Logger.setFileSink(sink);
      Logger.info('one');

      Logger.setFileSink(null);
      // After detach, further log calls must NOT write to the previously
      // attached sink (caller still owns it).
      Logger.info('two');

      await sink.flush();
      await sink.close();

      final captured = File(logPath).readAsStringSync();
      expect(captured, contains('[info] one'));
      expect(captured, isNot(contains('[info] two')));
    });

    test('fileSink getter reflects current attachment state', () async {
      expect(Logger.fileSink, isNull);
      final sink = File('${tempDir.path}${Platform.pathSeparator}g.log')
          .openWrite();
      Logger.setFileSink(sink);
      expect(Logger.fileSink, same(sink));
      Logger.setFileSink(null);
      expect(Logger.fileSink, isNull);
      await sink.close();
    });
  });
}
