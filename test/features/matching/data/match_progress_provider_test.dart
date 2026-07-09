// Phase 6 (Plan 06-07): MatchProgressNotifier unit tests.
//
// Covers update (clamping + replace), clear (present + absent), and the
// initial empty state.

import 'package:auto_explore/features/matching/data/match_progress_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late ProviderContainer container;

  setUp(() => container = ProviderContainer());
  tearDown(() => container.dispose());

  MatchProgressNotifier notifier() =>
      container.read(matchProgressProvider.notifier);
  Map<int, double> readState() => container.read(matchProgressProvider);

  test('initial state is empty', () {
    expect(readState(), isEmpty);
  });

  test('update sets a fraction for a trip', () {
    notifier().update(3, 0.42);
    expect(readState()[3], closeTo(0.42, 1e-9));
  });

  test('update replaces the fraction on the same trip', () {
    notifier()
      ..update(3, 0.1)
      ..update(3, 0.9);
    expect(readState()[3], closeTo(0.9, 1e-9));
    expect(readState(), hasLength(1));
  });

  test('update keeps independent per-trip fractions', () {
    notifier()
      ..update(1, 0.25)
      ..update(2, 0.75);
    expect(readState()[1], closeTo(0.25, 1e-9));
    expect(readState()[2], closeTo(0.75, 1e-9));
  });

  test('update clamps fractions into 0..1', () {
    notifier()
      ..update(1, -0.5)
      ..update(2, 1.7);
    expect(readState()[1], equals(0.0));
    expect(readState()[2], equals(1.0));
  });

  test('clear removes a present trip', () {
    notifier()
      ..update(3, 0.5)
      ..clear(3);
    expect(readState().containsKey(3), isFalse);
  });

  test('clear on an absent trip is a no-op', () {
    notifier()
      ..update(1, 0.5)
      ..clear(99);
    expect(readState(), hasLength(1));
    expect(readState()[1], closeTo(0.5, 1e-9));
  });
}
