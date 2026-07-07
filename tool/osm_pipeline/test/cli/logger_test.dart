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

  group('Logger.openLogFile (synchronous durable path)', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('trailblazer_logsync_');
    });

    tearDown(() {
      Logger.closeLogFile();
      try {
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      } on FileSystemException {
        // ignore
      }
    });

    test('writes info/warn/error lines synchronously with flushSync', () {
      final logPath =
          '${tempDir.path}${Platform.pathSeparator}durable.log';
      Logger.openLogFile(logPath);
      expect(Logger.hasDurableLogFile, isTrue);

      Logger.info('sync-hello');
      Logger.warn('sync-careful');
      Logger.error('sync-boom');

      // The critical guarantee — bytes are on disk BEFORE closeLogFile
      // runs. Reading right now must see all three lines.
      final captured = File(logPath).readAsStringSync();
      expect(captured, contains('[info] sync-hello'));
      expect(captured, contains('[warn] sync-careful'));
      expect(captured, contains('[error] sync-boom'));

      Logger.closeLogFile();
      expect(Logger.hasDurableLogFile, isFalse);
    });

    test('closeLogFile is idempotent', () {
      Logger.closeLogFile(); // safe with no file open
      Logger.openLogFile(
        '${tempDir.path}${Platform.pathSeparator}idem.log',
      );
      Logger.closeLogFile();
      Logger.closeLogFile(); // safe to call again
      expect(Logger.hasDurableLogFile, isFalse);
    });

    test('openLogFile replaces a previously-opened durable file', () {
      final firstPath =
          '${tempDir.path}${Platform.pathSeparator}first.log';
      final secondPath =
          '${tempDir.path}${Platform.pathSeparator}second.log';

      Logger.openLogFile(firstPath);
      Logger.info('first-line');

      Logger.openLogFile(secondPath); // implicit close of first
      Logger.info('second-line');
      Logger.closeLogFile();

      final firstCaptured = File(firstPath).readAsStringSync();
      final secondCaptured = File(secondPath).readAsStringSync();
      expect(firstCaptured, contains('[info] first-line'));
      expect(firstCaptured, isNot(contains('[info] second-line')));
      expect(secondCaptured, contains('[info] second-line'));
      expect(secondCaptured, isNot(contains('[info] first-line')));
    });
  });
}
