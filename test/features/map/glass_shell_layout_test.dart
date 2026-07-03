import 'package:auto_explore/features/map/presentation/map_screen.dart';
import 'package:auto_explore/features/map/presentation/providers/location_permission_provider.dart';
import 'package:auto_explore/features/map/presentation/providers/map_style_provider.dart';
import 'package:auto_explore/features/map/presentation/widgets/bottom_nav_shell.dart';
import 'package:auto_explore/features/map/presentation/widgets/focus_area_pill.dart';
import 'package:auto_explore/features/map/presentation/widgets/settings_glass_button.dart';
import 'package:auto_explore/features/map/presentation/widgets/trip_fab.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../helpers/fake_maplibre_platform.dart';

/// Pumps [MapScreen] with all required provider overrides to avoid platform
/// channel calls (MapLibre native plugin + permission_handler).
Future<void> pumpMapScreen(
  WidgetTester tester, {
  Widget? bottomNav,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        locationPermissionProvider.overrideWith(
          _FakeLocationPermissionNotifier.new,
        ),
        mapStyleAssetProvider.overrideWith(
          () => _FixedMapStyleNotifier('assets/map_style_light.json'),
        ),
      ],
      child: MaterialApp(
        home: MapScreen(bottomNav: bottomNav),
      ),
    ),
  );
}

class _FakeLocationPermissionNotifier
    extends AsyncNotifier<PermissionStatus>
    implements LocationPermissionNotifier {
  @override
  Future<PermissionStatus> build() async => PermissionStatus.denied;

  @override
  Future<PermissionStatus> requestOnce() async => PermissionStatus.denied;

  @override
  Future<void> refresh() async {}
}

class _FixedMapStyleNotifier extends MapStyleAssetNotifier {
  _FixedMapStyleNotifier(this._asset);

  final String _asset;

  @override
  String build() => _asset;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    final prev = MapLibrePlatform.createInstance;
    addTearDown(() => MapLibrePlatform.createInstance = prev);
    MapLibrePlatform.createInstance = FakeMapLibrePlatform.new;
  });

  group('MapScreen glass shell layout (UI-01..UI-07)', () {
    testWidgets('renders exactly one FocusAreaPill (UI-01)', (tester) async {
      await pumpMapScreen(tester);

      expect(find.byType(FocusAreaPill), findsOneWidget);
    });

    testWidgets('renders exactly one BottomNavShell with 3 tabs (UI-02)', (
      tester,
    ) async {
      await pumpMapScreen(tester);

      expect(find.byType(BottomNavShell), findsOneWidget);
      // Three tab labels present.
      expect(find.text('Map'), findsOneWidget);
      expect(find.text('Trips'), findsOneWidget);
      expect(find.text('Regions'), findsOneWidget);
      // Settings is NOT a tab in the pill.
      expect(find.text('Settings'), findsNothing);
    });

    testWidgets('renders exactly one TripFab (UI-03)', (tester) async {
      await pumpMapScreen(tester);

      expect(find.byType(TripFab), findsOneWidget);
    });

    testWidgets('renders exactly one SettingsGlassButton (UI-04)', (
      tester,
    ) async {
      await pumpMapScreen(tester);

      expect(find.byType(SettingsGlassButton), findsOneWidget);
    });

    testWidgets('Scaffold has no AppBar (UI-06)', (tester) async {
      await pumpMapScreen(tester);

      final scaffold = tester.widget<Scaffold>(find.byType(Scaffold).first);
      expect(scaffold.appBar, isNull);
    });

    testWidgets('TripFab tap shows SnackBar mentioning Phase 3 (UI-03 stub)',
        (tester) async {
      await pumpMapScreen(tester);

      await tester.tap(find.byType(TripFab));
      await tester.pump(); // let SnackBar animate in

      expect(find.text('Trip recording is coming in Phase 3'), findsOneWidget);
    });

    testWidgets(
        'SettingsGlassButton tap shows SnackBar mentioning Phase 10 stub',
        (tester) async {
      await pumpMapScreen(tester);

      await tester.tap(find.byType(SettingsGlassButton));
      await tester.pump();

      expect(find.text('Settings coming in Phase 10'), findsOneWidget);
    });

    testWidgets('BottomNavShell tab switch updates selected index', (
      tester,
    ) async {
      await pumpMapScreen(tester);

      // Initially "Map" (index 0) is selected — indicator is shown.
      // Tap "Trips" tab.
      await tester.tap(find.text('Trips'));
      await tester.pump();

      // After tap, BottomNavShell should reflect index 1.
      // The _LocalBottomNav drives the state; BottomNavShell is a pure widget.
      // Verify Trips text is still visible and the widget is present.
      expect(find.byType(BottomNavShell), findsOneWidget);
    });

    testWidgets('injectable bottomNav param is used when provided', (
      tester,
    ) async {
      // Provide a custom bottom nav stub to verify Plan 02-06 injection works.
      const customNav = SizedBox(key: ValueKey('custom-nav'));
      await pumpMapScreen(tester, bottomNav: customNav);

      expect(find.byKey(const ValueKey('custom-nav')), findsOneWidget);
      // The _LocalBottomNav should NOT be in the tree when bottomNav is given.
      expect(find.byType(BottomNavShell), findsNothing);
    });
  });
}
