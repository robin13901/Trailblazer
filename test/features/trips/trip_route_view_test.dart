import 'package:auto_explore/features/trips/domain/trip_list_item.dart';
import 'package:auto_explore/features/trips/domain/trip_status.dart';
import 'package:auto_explore/features/trips/presentation/widgets/trip_overlay_layers.dart';
import 'package:auto_explore/features/trips/presentation/widgets/trip_route_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart' show LatLng, LatLngBounds;

TripListItem _item() => TripListItem(
      id: 1,
      status: TripStatus.confirmed,
      startedAt: DateTime(2026),
      endedAt: DateTime(2026, 1, 1, 0, 42),
      distanceMeters: 28400,
      durationSeconds: 2520,
      startLat: 49.50,
      startLon: 9,
      endLat: 49.52,
      endLon: 9.02,
      intervalCount: 1,
    );

TripDetailData _data({
  List<LatLng> raw = const [],
  List<List<LatLng>> matched = const [],
  LatLngBounds? bounds,
  bool offline = false,
}) =>
    TripDetailData(
      item: _item(),
      rawPolyline: raw,
      matchedSegments: matched,
      bounds: bounds,
      matchedWayCount: matched.length,
      matchedFraction: matched.isEmpty ? null : 0.5,
      offline: offline,
    );

void main() {
  group('TripRouteView', () {
    testWidgets('empty polyline → shows "No route to display."',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TripRouteView(
              data: _data(),
              rawColor: Colors.grey,
              matchedColor: Colors.green,
            ),
          ),
        ),
      );
      expect(find.text('No route to display.'), findsOneWidget);
      expect(find.byType(CustomPaint), findsWidgets); // background only
    });

    testWidgets('with a polyline → paints (no MapLibre platform view)',
        (tester) async {
      final raw = <LatLng>[
        const LatLng(49.50, 9),
        const LatLng(49.51, 9.01),
        const LatLng(49.52, 9.02),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TripRouteView(
              data: _data(
                raw: raw,
                matched: [
                  [const LatLng(49.505, 9.005), const LatLng(49.515, 9.015)],
                ],
              ),
              rawColor: Colors.grey,
              matchedColor: Colors.green,
            ),
          ),
        ),
      );
      // The empty-state text must NOT appear; the CustomPaint is present.
      expect(find.text('No route to display.'), findsNothing);
      expect(find.byType(CustomPaint), findsWidgets);
    });
  });
}
