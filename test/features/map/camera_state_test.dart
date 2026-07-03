import 'package:auto_explore/features/map/domain/camera_state.dart';
import 'package:auto_explore/features/map/domain/follow_mode.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('FollowMode', () {
    test('has exactly 3 values in the correct order', () {
      expect(FollowMode.values, hasLength(3));
      expect(FollowMode.values[0], FollowMode.none);
      expect(FollowMode.values[1], FollowMode.location);
      expect(FollowMode.values[2], FollowMode.locationAndHeading);
    });
  });

  group('CameraState', () {
    test('initial sentinel has correct defaults', () {
      expect(CameraState.initial.latitude, 0);
      expect(CameraState.initial.longitude, 0);
      expect(CameraState.initial.zoom, 15);
      expect(CameraState.initial.bearing, 0);
      expect(CameraState.initial.followMode, FollowMode.none);
    });

    test('constructor sets all fields', () {
      const state = CameraState(
        latitude: 52.52,
        longitude: 13.40,
        zoom: 14,
        bearing: 90,
        followMode: FollowMode.location,
      );
      expect(state.latitude, 52.52);
      expect(state.longitude, 13.40);
      expect(state.zoom, 14);
      expect(state.bearing, 90);
      expect(state.followMode, FollowMode.location);
    });

    group('copyWith', () {
      test('returns identical state when no args provided', () {
        const original = CameraState(
          latitude: 52.52,
          longitude: 13.40,
          zoom: 15,
        );
        final copy = original.copyWith();
        expect(copy, equals(original));
      });

      test('overrides only the specified fields', () {
        const original = CameraState(
          latitude: 52.52,
          longitude: 13.40,
          zoom: 15,
        );
        final updated = original.copyWith(
          latitude: 48,
          followMode: FollowMode.location,
        );
        expect(updated.latitude, 48);
        expect(updated.longitude, 13.40); // unchanged
        expect(updated.zoom, 15); // unchanged
        expect(updated.bearing, 0); // unchanged
        expect(updated.followMode, FollowMode.location);
      });

      test('copyWith zoom only', () {
        final updated = CameraState.initial.copyWith(zoom: 12);
        expect(updated.zoom, 12);
        expect(updated.latitude, 0);
      });
    });

    group('equality', () {
      test('two states with same fields are equal', () {
        const a = CameraState(latitude: 1, longitude: 2, zoom: 15);
        const b = CameraState(latitude: 1, longitude: 2, zoom: 15);
        expect(a, equals(b));
        expect(a.hashCode, equals(b.hashCode));
      });

      test('states with different latitude are not equal', () {
        const a = CameraState(latitude: 1, longitude: 2, zoom: 15);
        const b = CameraState(latitude: 1.1, longitude: 2, zoom: 15);
        expect(a, isNot(equals(b)));
      });

      test('states with different followMode are not equal', () {
        const a = CameraState(
          latitude: 1,
          longitude: 2,
          zoom: 15,
        );
        const b = CameraState(
          latitude: 1,
          longitude: 2,
          zoom: 15,
          followMode: FollowMode.location,
        );
        expect(a, isNot(equals(b)));
      });
    });
  });
}
