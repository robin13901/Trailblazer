import 'dart:math' as math;

import 'package:auto_explore/features/map/domain/camera_state.dart';
import 'package:auto_explore/features/map/domain/follow_mode.dart';
import 'package:auto_explore/features/map/presentation/providers/camera_state_provider.dart';
import 'package:auto_explore/features/map/presentation/widgets/align_north_button.dart';
import 'package:auto_explore/features/map/presentation/widgets/glass_circle.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Fixed [CameraState] notifier used to inject a specific bearing.
class _FixedCameraStateNotifier extends CameraStateNotifier {
  _FixedCameraStateNotifier(this._initial);

  final CameraState _initial;

  @override
  CameraState build() => _initial;
}

Future<void> _pumpAlignNorth(
  WidgetTester tester, {
  double bearing = 0,
}) async {
  final camera = const CameraState(
    latitude: 0,
    longitude: 0,
    zoom: 15,
  ).copyWith(bearing: bearing, followMode: FollowMode.none);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        cameraStateProvider.overrideWith(
          () => _FixedCameraStateNotifier(camera),
        ),
      ],
      child: const MaterialApp(
        home: Scaffold(body: Center(child: AlignNorthButton())),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  group('AlignNorthButton', () {
    testWidgets('renders a 44 dp GlassCircle', (tester) async {
      await _pumpAlignNorth(tester);

      final glass = tester.widget<GlassCircle>(find.byType(GlassCircle));
      expect(
        glass.size,
        44,
        reason: 'Must mirror SettingsGlassButton (44 dp) per plan 04-19',
      );
    });

    testWidgets('has semantics label "Align map to north"', (tester) async {
      await _pumpAlignNorth(tester);

      final semantics = tester.getSemantics(find.byType(AlignNorthButton));
      expect(semantics.label, 'Nach Norden ausrichten');
    });

    testWidgets('renders a navigation compass icon', (tester) async {
      await _pumpAlignNorth(tester);

      final icon = tester.widget<Icon>(find.byType(Icon));
      expect(icon.icon, Icons.navigation_outlined);
      expect(icon.size, 20);
    });

    testWidgets(
      'icon Transform.rotate angle mirrors -bearing (radians) when bearing=0',
      (tester) async {
        await _pumpAlignNorth(tester);

        final transform =
            tester.widget<Transform>(find.byType(Transform).first);
        // Transform.rotate constructs a rotation matrix; the entry
        // storage[0] is cos(angle). angle=0 → cos=1.
        expect(transform.transform.storage[0], closeTo(1, 1e-6));
      },
    );

    testWidgets(
      'icon counter-rotates to bearing (90° map → -90° arrow)',
      (tester) async {
        await _pumpAlignNorth(tester, bearing: 90);

        final transform =
            tester.widget<Transform>(find.byType(Transform).first);
        // For angle = -pi/2, cos(angle) = 0, sin(angle) = -1.
        // Rotation matrix storage: [cos, sin, 0, 0, -sin, cos, ...].
        expect(transform.transform.storage[0], closeTo(0, 1e-6));
        // sin(-pi/2) = -1
        expect(
          transform.transform.storage[1],
          closeTo(-1, 1e-6),
          reason: 'Bearing 90° must produce -pi/2 rotation (counter-CW)',
        );
        // Sanity: -bearing * pi / 180 = -pi/2
        expect(-90 * math.pi / 180, closeTo(-math.pi / 2, 1e-9));
      },
    );

    testWidgets(
      'tap with no map controller wired is a no-op (fail-soft)',
      (tester) async {
        // No mapControllerProvider override — the provider default is null.
        await _pumpAlignNorth(tester);

        // Tapping must not throw even without a controller.
        await tester.tap(find.byType(AlignNorthButton));
        await tester.pump();

        expect(tester.takeException(), isNull);
      },
    );
  });
}
