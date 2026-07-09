// Trailblazer Phase 6, Plan 06-04 Task 1 tests:
// inbox / history / in-flight presentation providers.
//
// A fake TripsInboxRepository is injected via `tripsInboxRepositoryProvider`
// override; its streams are driven by broadcast StreamControllers so we can
// push controlled data and assert re-emission, error propagation, and
// late-subscriber caching.

import 'dart:async';

import 'package:auto_explore/features/trips/data/trips_repository_inbox_extensions.dart';
import 'package:auto_explore/features/trips/domain/trip_list_item.dart';
import 'package:auto_explore/features/trips/domain/trip_status.dart';
import 'package:auto_explore/features/trips/presentation/providers/inbox_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Minimal fake repository — only the three stream getters are exercised.
/// Keep/Discard flows are not under test here (06-02 covers those).
class _FakeInboxRepository implements TripsInboxRepository {
  final inbox = StreamController<List<TripListItem>>.broadcast();
  final history = StreamController<List<TripListItem>>.broadcast();
  final inFlight = StreamController<int>.broadcast();

  @override
  Stream<List<TripListItem>> watchInboxItems() => inbox.stream;

  @override
  Stream<List<TripListItem>> watchHistoryItems() => history.stream;

  @override
  Stream<int> watchInFlightCount() => inFlight.stream;

  // Not exercised by these tests.
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

TripListItem _item(int id, TripStatus status) => TripListItem(
      id: id,
      status: status,
      startedAt: DateTime(2026, 7, 9, 10),
      endedAt: DateTime(2026, 7, 9, 11),
      distanceMeters: 1000,
      durationSeconds: 3600,
      startLat: 52,
      startLon: 13,
      endLat: 52.1,
      endLon: 13.1,
      intervalCount: 3,
    );

void main() {
  late _FakeInboxRepository fake;
  late ProviderContainer container;

  setUp(() {
    fake = _FakeInboxRepository();
    container = ProviderContainer(
      overrides: [
        tripsInboxRepositoryProvider.overrideWithValue(fake),
      ],
    );
  });

  tearDown(() async {
    container.dispose();
    await fake.inbox.close();
    await fake.history.close();
    await fake.inFlight.close();
  });

  test('inboxTripsProvider re-emits when fake stream pushes new list',
      () async {
    final sub = container.listen(inboxTripsProvider, (_, _) {});
    addTearDown(sub.close);

    expect(container.read(inboxTripsProvider).isLoading, isTrue);

    fake.inbox.add([_item(1, TripStatus.matched)]);
    await container.read(inboxTripsProvider.future);
    expect(container.read(inboxTripsProvider).value, hasLength(1));

    fake.inbox.add([
      _item(1, TripStatus.matched),
      _item(2, TripStatus.matched),
    ]);
    await Future<void>.delayed(Duration.zero);
    expect(container.read(inboxTripsProvider).value, hasLength(2));
  });

  test('historyTripsProvider re-emits', () async {
    final sub = container.listen(historyTripsProvider, (_, _) {});
    addTearDown(sub.close);

    fake.history.add([_item(1, TripStatus.confirmed)]);
    await container.read(historyTripsProvider.future);
    expect(container.read(historyTripsProvider).value, hasLength(1));
  });

  test('inFlightCountProvider emits sequence 0 → 1 → 2 → 0', () async {
    final seen = <int>[];
    final sub = container.listen<AsyncValue<int>>(
      inFlightCountProvider,
      (_, next) {
        final v = next.value;
        if (v != null) seen.add(v);
      },
      fireImmediately: true,
    );
    addTearDown(sub.close);

    for (final n in [0, 1, 2, 0]) {
      fake.inFlight.add(n);
      await Future<void>.delayed(Duration.zero);
    }

    expect(seen, [0, 1, 2, 0]);
  });

  test('errors in stream propagate to AsyncError state', () async {
    final sub = container.listen(inFlightCountProvider, (_, _) {});
    addTearDown(sub.close);

    fake.inFlight.addError(StateError('boom'));
    await Future<void>.delayed(Duration.zero);

    final state = container.read(inFlightCountProvider);
    expect(state.hasError, isTrue);
    expect(state.error, isA<StateError>());
  });

  test('late subscriber sees latest cached value (broadcast behavior)',
      () async {
    final sub = container.listen(inFlightCountProvider, (_, _) {});
    addTearDown(sub.close);

    fake.inFlight.add(7);
    await Future<void>.delayed(Duration.zero);
    expect(container.read(inFlightCountProvider).value, 7);

    // A late reader (new keepAlive read) sees the cached AsyncData, not a
    // fresh loading state, because the provider is already subscribed.
    expect(container.read(inFlightCountProvider).value, 7);
  });
}
