import 'package:osm_pipeline/cli/progress_logger.dart';
import 'package:test/test.dart';

/// Fake wall clock — advance manually via `advance`.
class _FakeClock {
  DateTime _now = DateTime.utc(2026);
  DateTime call() => _now;
  void advance(Duration d) => _now = _now.add(d);
}

/// Captured `Logger.info` sink — the ProgressLogger emits into `add`.
class _Sink {
  final List<String> lines = <String>[];
  void add(String line) => lines.add(line);
}

void main() {
  group('ProgressLogger cadence gate', () {
    test('emits after everyMs elapses', () {
      final clock = _FakeClock();
      final sink = _Sink();
      final pl = ProgressLogger(
        'Stage X',
        total: 1000,
        everyPct: 0,
        now: clock.call,
        emit: sink.add,
      )..tick(); // first tick — initial line
      expect(sink.lines, hasLength(1));

      // Within cadence window: no new line.
      clock.advance(const Duration(milliseconds: 4999));
      pl.tick();
      expect(sink.lines, hasLength(1));

      // Past cadence window: new line.
      clock.advance(const Duration(milliseconds: 2));
      pl.tick();
      expect(sink.lines, hasLength(2));
    });

    test('emits at 5% boundary before 5s elapsed', () {
      final clock = _FakeClock();
      final sink = _Sink();
      final pl = ProgressLogger(
        'Stage X',
        total: 100,
        now: clock.call,
        emit: sink.add,
      )..tick(); // first tick @ 1% — initial line
      expect(sink.lines, hasLength(1));

      // Advance 100 ms (well within cadence). Cross 6% boundary
      // (5 above the last-emit pct of 1).
      clock.advance(const Duration(milliseconds: 100));
      pl.tick(5); // done=6, pct=6
      expect(
        sink.lines,
        hasLength(2),
        reason: 'pct boundary should fire even inside cadence window',
      );
    });

    test('does NOT emit twice within cadence window (rate-only mode)', () {
      final clock = _FakeClock();
      final sink = _Sink();
      final pl = ProgressLogger(
        'Stage B',
        total: 0, // unknown total → pct gate disabled by design
        now: clock.call,
        emit: sink.add,
      );

      for (var i = 0; i < 100; i++) {
        pl.tick();
      }
      // Only the first tick's initial line should have fired; clock never
      // advanced.
      expect(sink.lines, hasLength(1));
    });
  });

  group('ProgressLogger math', () {
    test('throughput contains a rate token', () {
      final clock = _FakeClock();
      final sink = _Sink();
      final pl = ProgressLogger(
        'Stage X',
        total: 1000,
        everyPct: 0,
        now: clock.call,
        emit: sink.add,
      )..tick(); // primes the emitter, _lastEmitAt = t=0
      clock.advance(const Duration(milliseconds: 1000));
      pl.tick(499); // done=500 at t=1000ms
      // We need cadence to open — advance past 5 s.
      clock.advance(const Duration(milliseconds: 4001));
      pl.tick(); // done=501 at t=5001ms; rate=501*1000/5001 ≈ 100/s.
      // Verify the format contains a rate token.
      final lastLine = sink.lines.last;
      expect(lastLine, matches(RegExp(r'\d+/s')));
    });

    test('ETA math: done=500 total=1000 rate=100/s → "5s"', () {
      final clock = _FakeClock();
      final sink = _Sink();
      final pl = ProgressLogger(
        'Stage X',
        total: 1000,
        everyPct: 0,
        now: clock.call,
        emit: sink.add,
      )..tick(); // done=1 at t=0 — initial line
      // Simulate 5 s wall-clock elapsed with 500 items done → 100/s.
      clock.advance(const Duration(milliseconds: 5000));
      pl.tick(499); // done=500 at t=5000ms
      final lastLine = sink.lines.last;
      // rate = 500 * 1000 / 5000 = 100/s. remaining = 500. eta = 5s.
      expect(lastLine, contains('ETA 5s'));
    });

    test('finish() always emits a final line', () {
      final clock = _FakeClock();
      final sink = _Sink();
      final pl = ProgressLogger(
        'Stage X',
        total: 100,
        now: clock.call,
        emit: sink.add,
      )..tick(50); // initial line
      final beforeFinish = sink.lines.length;
      // Same tick — cadence window not passed.
      pl.finish();
      expect(sink.lines.length, beforeFinish + 1);
      expect(sink.lines.last, contains('done:'));
    });

    test('zero total → no divide-by-zero, ETA prints "(total unknown)"', () {
      final clock = _FakeClock();
      final sink = _Sink();
      final pl = ProgressLogger(
        'Stage B',
        total: 0,
        now: clock.call,
        emit: sink.add,
      )..tick(42);
      expect(sink.lines, hasLength(1));
      expect(sink.lines.first, contains('total unknown'));
      // finish() must also survive total=0.
      clock.advance(const Duration(seconds: 3));
      pl.finish();
      expect(sink.lines.last, contains('done:'));
    });

    test('thousands separators appear in the emitted line', () {
      final clock = _FakeClock();
      final sink = _Sink();
      ProgressLogger(
        'Stage D',
        total: 4070051,
        unit: 'ways',
        everyPct: 0,
        now: clock.call,
        emit: sink.add,
      ).tick(1925340); // initial line
      expect(sink.lines.first, contains('1,925,340'));
      expect(sink.lines.first, contains('4,070,051'));
      expect(sink.lines.first, contains('ways'));
    });
  });

  group('ProgressLogger.absorb', () {
    test('N workers × M ticks accumulate into single _done', () {
      final clock = _FakeClock();
      final sink = _Sink();
      final pl = ProgressLogger(
        'Stage D',
        total: 1000,
        everyPct: 0,
        now: clock.call,
        emit: sink.add,
      );

      // 4 workers × 250 ticks each = 1000 total. Advance clock enough
      // between batches to test cadence gate at the coordinator.
      for (var w = 0; w < 4; w++) {
        pl.absorb(WorkerTick(w, 250, 100 * (w + 1)));
      }
      expect(pl.done, 1000);
      // Cadence gate is coordinator-side: first absorb emits initial line,
      // subsequent absorbs within the window are gated by cadence/pct until
      // completion, and the final absorb crosses completion → emit.
      expect(sink.lines.length, greaterThanOrEqualTo(1));
      // Final line must show 100 %.
      expect(sink.lines.last, contains('100.0%'));
    });

    test('WorkerTick construction is const-friendly', () {
      const t = WorkerTick(3, 42, 1234);
      expect(t.workerId, 3);
      expect(t.deltaTicks, 42);
      expect(t.elapsedMs, 1234);
    });
  });

  group('ETA formatter branches', () {
    test('> 1h renders "{h}h {m}m"', () {
      final clock = _FakeClock();
      final sink = _Sink();
      final pl = ProgressLogger(
        'Stage X',
        total: 10000,
        everyPct: 0,
        now: clock.call,
        emit: sink.add,
      )..tick(); // initial line at t=0
      // 100 items in 1 s → 100/s. remaining = 9900. eta ≈ 99 s. That's < 1m.
      // Need bigger horizon: 100 done in 100 s → 1/s → eta = 9900 s ≈ 2h 45m.
      clock.advance(const Duration(seconds: 100));
      pl.tick(99); // done=100 at t=100s
      // rate = 100*1000/100000 = 1/s. remaining = 9900. eta = 9900 s.
      expect(sink.lines.last, matches(RegExp(r'ETA \d+h \d+m')));
    });

    test('> 1m renders "{m}m {s}s"', () {
      final clock = _FakeClock();
      final sink = _Sink();
      final pl = ProgressLogger(
        'Stage X',
        total: 1000,
        everyPct: 0,
        now: clock.call,
        emit: sink.add,
      )..tick(); // initial @ t=0
      clock.advance(const Duration(seconds: 10));
      pl.tick(9); // done=10 at t=10s
      // rate = 10/10 = 1/s. remaining = 990. eta = 990s = 16m 30s.
      expect(sink.lines.last, matches(RegExp(r'ETA \d+m \d+s')));
    });
  });
}
