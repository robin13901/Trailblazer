import 'package:auto_explore/features/map/domain/follow_mode.dart';
import 'package:meta/meta.dart';

/// Immutable camera state. Manual `copyWith` + `==` (no freezed —
/// Phase 1 locked in a no-codegen policy for state classes).
@immutable
class CameraState {
  const CameraState({
    required this.latitude,
    required this.longitude,
    required this.zoom,
    this.bearing = 0,
    this.followMode = FollowMode.none,
  });

  final double latitude;
  final double longitude;
  final double zoom;
  final double bearing;
  final FollowMode followMode;

  /// Phase-2 default: unknown position, zoom 15 (address-level),
  /// no follow. Replaced as soon as first location fix arrives OR
  /// the user pans.
  static const CameraState initial = CameraState(
    latitude: 0,
    longitude: 0,
    zoom: 15,
  );

  CameraState copyWith({
    double? latitude,
    double? longitude,
    double? zoom,
    double? bearing,
    FollowMode? followMode,
  }) => CameraState(
        latitude: latitude ?? this.latitude,
        longitude: longitude ?? this.longitude,
        zoom: zoom ?? this.zoom,
        bearing: bearing ?? this.bearing,
        followMode: followMode ?? this.followMode,
      );

  @override
  bool operator ==(Object other) =>
      other is CameraState &&
      other.latitude == latitude &&
      other.longitude == longitude &&
      other.zoom == zoom &&
      other.bearing == bearing &&
      other.followMode == followMode;

  @override
  int get hashCode =>
      Object.hash(latitude, longitude, zoom, bearing, followMode);
}
