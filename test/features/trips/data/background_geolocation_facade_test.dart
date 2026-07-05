// Stability contract test for BackgroundGeolocationFacade.
//
// This is NOT a functional test of the FGB plugin (that requires a real device
// with the native SDK). It's a canary: if a future plan renames or removes
// an interface method, this test fails immediately, catching the breakage
// before Wave 2's fake implementations go out of sync.
//
// The test exercises only pure-Dart code — no platform channel, no native.

import 'dart:async';

import 'package:auto_explore/features/trips/data/background_geolocation_facade.dart';
import 'package:auto_explore/features/trips/domain/trip_fix_input.dart';
import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// A minimal fake that implements every abstract member.
// If the interface gains or removes a method, this class will produce a
// compile-time error here, making regression visible instantly.
// ---------------------------------------------------------------------------

class _FakeFacade implements BackgroundGeolocationFacade {
  @override
  Future<void> ready() async {}

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> changePace({required bool moving}) async {}

  @override
  Future<void> setNotificationText(String text) async {}

  @override
  Future<void> showIgnoreBatteryOptimizations() async {}

  @override
  Stream<FixInput> get onLocation => const Stream.empty();

  @override
  Stream<MotionChange> get onMotionChange => const Stream.empty();

  @override
  Stream<ActivityChange> get onActivityChange => const Stream.empty();

  @override
  Future<FgbState> currentState() async =>
      const FgbState(enabled: false, isMoving: false);
}

void main() {
  group('BackgroundGeolocationFacade interface contract', () {
    test('can be implemented by a fake without native code', () {
      final facade = _FakeFacade();
      expect(facade, isA<BackgroundGeolocationFacade>());
    });

    test('FgbState is const-constructable', () {
      const state = FgbState(enabled: true, isMoving: false);
      expect(state.enabled, isTrue);
      expect(state.isMoving, isFalse);
    });

    test('MotionChange can be constructed', () {
      final mc = MotionChange(isMoving: true, ts: DateTime(2026, 7, 5));
      expect(mc.isMoving, isTrue);
    });

    test('ActivityChange can be constructed', () {
      final ac = ActivityChange(
        activityType: 'in_vehicle',
        confidence: 90,
        ts: DateTime(2026, 7, 5),
      );
      expect(ac.activityType, equals('in_vehicle'));
      expect(ac.confidence, equals(90));
    });

    test('fake streams are empty (no native calls made)', () async {
      final facade = _FakeFacade();
      expect(await facade.onLocation.isEmpty, isTrue);
      expect(await facade.onMotionChange.isEmpty, isTrue);
      expect(await facade.onActivityChange.isEmpty, isTrue);
    });
  });
}
