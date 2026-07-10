import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:maplibre_gl/maplibre_gl.dart' show CameraPosition;
import 'package:meta/meta.dart';

/// Latest live camera reading. Emitted on every `onCameraMove` frame (unlike
/// `cameraStateProvider` which only updates on idle). Consumed by the focus
/// pill (Plan 08-05) with a trailing debounce + hold-last-value.
@immutable
class LiveCamera {
  const LiveCamera({
    required this.latitude,
    required this.longitude,
    required this.zoom,
  });

  final double latitude;
  final double longitude;
  final double zoom;

  @override
  bool operator ==(Object other) =>
      other is LiveCamera &&
      other.latitude == latitude &&
      other.longitude == longitude &&
      other.zoom == zoom;

  @override
  int get hashCode => Object.hash(latitude, longitude, zoom);
}

/// Live camera notifier. Starts null (no reading yet). `MapWidget`'s
/// `onCameraMove` calls [update] on every frame.
///
/// Plain [Notifier] — no `@Riverpod` codegen (STATE.md Plan 01-01 decision).
class LiveCameraNotifier extends Notifier<LiveCamera?> {
  @override
  LiveCamera? build() => null;

  /// Push the latest raw camera position from `MapWidget.onCameraMove`.
  ///
  /// Debounce + region-resolution logic lives in the focus pill (Plan 08-05),
  /// NOT here. This callback is on the hot pan/zoom path and must remain cheap
  /// (a single state assignment; RESEARCH.md line 571).
  void update(CameraPosition position) {
    state = LiveCamera(
      latitude: position.target.latitude,
      longitude: position.target.longitude,
      zoom: position.zoom,
    );
  }
}

/// Provider for the latest live camera position.
///
/// Null until the first `onCameraMove` fires after map creation.
final liveCameraProvider =
    NotifierProvider<LiveCameraNotifier, LiveCamera?>(LiveCameraNotifier.new);
