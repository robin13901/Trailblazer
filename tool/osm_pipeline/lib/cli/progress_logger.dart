/// Stateful progress emitter for long-running pipeline stages.
///
/// Owned by the main isolate. Callable directly for single-threaded stages
/// via `tick`. Ready for Wave 4 (Stage D isolates) via `absorb` — worker
/// isolates post `WorkerTick` messages through a `SendPort`, the coordinator
/// funnels them into a single `ProgressLogger.absorb(msg)` call which shares
/// the same cadence gate.
///
/// The `Logger` static class in `logger.dart` stays untouched; this is a
/// sibling stateful helper with cadence + rate + ETA awareness.
///
/// Log line format (via `Logger.info`):
///
/// ```text
/// Stage D progress: 47.3% (1,925,340 / 4,070,051 ways) — 12,340/s — ETA 3m 22s
/// ```
///
/// When `total` is `0` (sentinel for "total unknown up front" — Stage B pass A,
/// Stage F.1 PBF passes), the emitter falls back to a done-count + rate line
/// with `--` in place of percentage and ETA. Ugly-looking `%: --` is by design
/// per 04-10-1-01 plan §Deviations.
library;

import 'package:osm_pipeline/cli/logger.dart';

DateTime _defaultNow() => DateTime.now();

/// Tick message posted by an isolate worker to the coordinator.
///
/// Wire pattern (Wave 4):
///
/// 1. Worker maintains a local counter of processed items.
/// 2. Every N items (recommended: N=1000 to amortize SendPort cost), the
///    worker posts `WorkerTick(workerId, deltaTicks: N, elapsedMs: ...)`
///    to the coordinator's `ReceivePort`.
/// 3. Coordinator listens on that port and calls
///    `progressLogger.absorb(msg)` on the main isolate.
///
/// [deltaTicks] is the count SINCE the last tick from this worker (not
/// cumulative). The [ProgressLogger] accumulates deltas into its own
/// `_done` counter so N workers contribute correctly to a single progress
/// aggregate.
///
/// [elapsedMs] is the worker's local wall-clock elapsed at the moment of
/// posting — informational for future per-worker rate reporting; Wave 1
/// does not display it.
class WorkerTick {
  /// Create a tick.
  const WorkerTick(this.workerId, this.deltaTicks, this.elapsedMs);

  /// Zero-based worker index (coordinator-assigned).
  final int workerId;

  /// Number of items processed since the last tick posted by this worker.
  final int deltaTicks;

  /// Worker-local wall-clock elapsed at post time, in milliseconds.
  final int elapsedMs;
}

/// Stateful progress-emitter. Owned by the main isolate.
class ProgressLogger {
  /// Create a logger for [stage] (e.g. `'Stage D'`).
  ///
  /// [total] is the total unit count. Pass `0` when the total is
  /// genuinely unknown up front — the emitter switches to a rate-only
  /// format.
  ///
  /// [unit] is the noun that pluralises the counted units (e.g. `'ways'`,
  /// `'features'`). Defaults to `'items'`.
  ///
  /// [everyMs] is the minimum interval between emitted lines. Default:
  /// 5000 (one line per 5 s).
  ///
  /// [everyPct] is the pct-boundary trigger (emit when done crosses an
  /// N% boundary regardless of cadence). Default: 5. Set to `0` to
  /// disable the pct-boundary trigger.
  ///
  /// [now] is an injectable clock for testing.
  ProgressLogger(
    this.stage, {
    required this.total,
    this.unit = 'items',
    this.everyMs = 5000,
    this.everyPct = 5,
    DateTime Function() now = _defaultNow,
    void Function(String)? emit,
  })  : _now = now,
        _emit = emit ?? Logger.info,
        _startedAt = now();

  /// Stage label used in every emitted line (e.g. `'Stage D'`).
  final String stage;

  /// Total unit count; `0` means "unknown" (rate-only mode).
  final int total;

  /// Pluralised unit noun for the counted items.
  final String unit;

  /// Minimum wall-clock interval between emitted lines, in milliseconds.
  final int everyMs;

  /// Pct-boundary trigger; set to `0` to disable.
  final int everyPct;

  final DateTime Function() _now;
  final void Function(String) _emit;
  final DateTime _startedAt;

  int _done = 0;
  DateTime? _lastEmitAt;
  int _lastEmitPct = 0;

  /// Number of items processed so far. Read for tests + reporting.
  int get done => _done;

  /// Advance the counter by [n] items and emit a progress line if the
  /// cadence gate opens.
  ///
  /// Called from single-threaded stage code. For isolate workers, use
  /// [absorb] on the coordinator side instead.
  void tick([int n = 1]) {
    _done += n;
    _maybeEmit();
  }

  /// Coordinator-side ingestion for isolate workers (Wave 4).
  ///
  /// Accumulates the delta into `_done` and runs the shared cadence gate.
  void absorb(WorkerTick msg) {
    _done += msg.deltaTicks;
    _maybeEmit();
  }

  /// Emit the final 100 % line — bypasses the cadence gate so a stage
  /// that finishes mid-window still prints a closing line.
  void finish() {
    final now = _now();
    final elapsedMs = now.difference(_startedAt).inMilliseconds;
    final rate = _rate(elapsedMs);
    _emit(
      '$stage done: ${_thousands(_done)} $unit in '
      '${_formatElapsed(elapsedMs)} (${_thousands(rate.round())}/s)',
    );
    _lastEmitAt = now;
    _lastEmitPct = total > 0 ? 100 : 0;
  }

  void _maybeEmit() {
    final now = _now();
    final firstEmit = _lastEmitAt == null;
    final msSinceLast =
        firstEmit ? everyMs : now.difference(_lastEmitAt!).inMilliseconds;

    final pct = total > 0 ? (_done * 100) ~/ total : 0;
    final pctGate = everyPct > 0 &&
        total > 0 &&
        (pct - _lastEmitPct) >= everyPct;

    final cadenceGate = msSinceLast >= everyMs;
    final completionGate = total > 0 && _done >= total;

    if (!cadenceGate && !pctGate && !completionGate) return;

    final elapsedMs = now.difference(_startedAt).inMilliseconds;
    final rate = _rate(elapsedMs);
    final line = total > 0
        ? _formatKnownTotal(pct, rate, elapsedMs)
        : _formatUnknownTotal(rate);
    _emit(line);

    _lastEmitAt = now;
    _lastEmitPct = pct;
  }

  double _rate(int elapsedMs) {
    if (elapsedMs <= 0) return 0;
    return _done * 1000 / elapsedMs;
  }

  String _formatKnownTotal(int pct, double rate, int elapsedMs) {
    final remaining = total - _done;
    final etaSec = rate > 0 && remaining > 0 ? remaining / rate : 0.0;
    final pctStr = total > 0
        ? (_done * 100 / total).toStringAsFixed(1)
        : '--';
    final rateStr = rate > 0 ? _thousands(rate.round()) : '0';
    final etaStr = rate > 0 && remaining > 0 ? _formatEta(etaSec) : '--';
    return '$stage progress: $pctStr% '
        '(${_thousands(_done)} / ${_thousands(total)} $unit) — '
        '$rateStr/s — ETA $etaStr';
  }

  String _formatUnknownTotal(double rate) {
    final rateStr = rate > 0 ? _thousands(rate.round()) : '0';
    return '$stage progress: ${_thousands(_done)} $unit — $rateStr/s '
        '(total unknown)';
  }
}

/// Hand-rolled thousands-separator (avoids pulling in `intl` for one call
/// site). Uses non-breaking-ASCII `,` — matches the plan's example line.
String _thousands(int n) {
  if (n == 0) return '0';
  final neg = n < 0;
  final digits = n.abs().toString();
  final buf = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buf.write(',');
    buf.write(digits[i]);
  }
  return neg ? '-$buf' : buf.toString();
}

/// Format an ETA in seconds into a human-readable string.
///
///   * > 1 h  → `{h}h {m}m`
///   * > 1 m  → `{m}m {s}s`
///   * else   → `{s}s`
String _formatEta(double etaSec) {
  if (etaSec.isNaN || etaSec.isInfinite || etaSec <= 0) return '--';
  final total = etaSec.round();
  if (total >= 3600) {
    final h = total ~/ 3600;
    final m = (total % 3600) ~/ 60;
    return '${h}h ${m}m';
  }
  if (total >= 60) {
    final m = total ~/ 60;
    final s = total % 60;
    return '${m}m ${s}s';
  }
  return '${total}s';
}

/// Format elapsed millis for the finish() line — same rules as [_formatEta]
/// but always prints a value (never `--`).
String _formatElapsed(int elapsedMs) {
  final s = (elapsedMs / 1000).round();
  if (s >= 3600) {
    final h = s ~/ 3600;
    final m = (s % 3600) ~/ 60;
    return '${h}h ${m}m';
  }
  if (s >= 60) {
    final m = s ~/ 60;
    final r = s % 60;
    return '${m}m ${r}s';
  }
  return '${s}s';
}
