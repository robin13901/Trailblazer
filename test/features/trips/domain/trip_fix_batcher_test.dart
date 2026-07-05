import 'package:auto_explore/features/trips/domain/trip_fix_batcher.dart';
import 'package:auto_explore/features/trips/domain/trip_point.dart';
import 'package:flutter_test/flutter_test.dart';

// Fake sink that records (tripId, batchLength) per call.
class _FakeSink implements TripPointsSink {
  final calls = <(int tripId, int length)>[];

  @override
  Future<void> appendPoints(int tripId, List<TripPoint> points) async {
    calls.add((tripId, points.length));
  }
}

TripPoint _point(int seq) => TripPoint(
      tripId: 1,
      seq: seq,
      ts: DateTime.utc(2026, 7, 5, 8).add(Duration(seconds: seq)),
      lat: 50 + seq * 0.0001,
      lon: 9,
    );

void main() {
  group('TripFixBatcher', () {
    test('19 points → no flush', () async {
      final sink = _FakeSink();
      final batcher = TripFixBatcher(tripId: 1, sink: sink);

      for (var i = 0; i < 19; i++) {
        await batcher.add(_point(i));
      }

      expect(batcher.pendingCount, equals(19));
      expect(sink.calls, isEmpty);
    });

    test('20th point triggers auto-flush of 20, pendingCount == 0', () async {
      final sink = _FakeSink();
      final batcher = TripFixBatcher(tripId: 1, sink: sink);

      for (var i = 0; i < 20; i++) {
        await batcher.add(_point(i));
      }

      expect(sink.calls.length, equals(1));
      expect(sink.calls.first, equals((1, 20)));
      expect(batcher.pendingCount, equals(0));
    });

    test('25 points → 1 auto-flush of 20, pendingCount == 5', () async {
      final sink = _FakeSink();
      final batcher = TripFixBatcher(tripId: 1, sink: sink);

      for (var i = 0; i < 25; i++) {
        await batcher.add(_point(i));
      }

      expect(sink.calls.length, equals(1));
      expect(sink.calls.first, equals((1, 20)));
      expect(batcher.pendingCount, equals(5));
    });

    test('explicit flush on 5-pending → 1 sink call of length 5', () async {
      final sink = _FakeSink();
      final batcher = TripFixBatcher(tripId: 1, sink: sink);

      for (var i = 0; i < 25; i++) {
        await batcher.add(_point(i));
      }
      // After 25 adds: 1 auto-flush of 20, 5 pending
      expect(sink.calls.length, equals(1));

      await batcher.flush();

      expect(sink.calls.length, equals(2));
      expect(sink.calls[1], equals((1, 5)));
      expect(batcher.pendingCount, equals(0));
    });

    test('flush on empty buffer → no sink call', () async {
      final sink = _FakeSink();
      final batcher = TripFixBatcher(tripId: 1, sink: sink);

      await batcher.flush();

      expect(sink.calls, isEmpty);
    });

    test('tripId is forwarded to sink', () async {
      final sink = _FakeSink();
      const tripId = 42;
      final batcher = TripFixBatcher(tripId: tripId, sink: sink, batchSize: 1);

      await batcher.add(
        TripPoint(
          tripId: tripId,
          seq: 0,
          ts: DateTime.utc(2026, 7, 5, 8),
          lat: 50,
          lon: 9,
        ),
      );

      expect(sink.calls.first.$1, equals(tripId));
    });

    test('custom batchSize of 3 flushes at 3', () async {
      final sink = _FakeSink();
      final batcher = TripFixBatcher(tripId: 1, sink: sink, batchSize: 3);

      for (var i = 0; i < 3; i++) {
        await batcher.add(_point(i));
      }

      expect(sink.calls.length, equals(1));
      expect(sink.calls.first, equals((1, 3)));
    });
  });
}
