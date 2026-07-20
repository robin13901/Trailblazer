// Trailblazer region-outline overlay:
// Widget tests for RegionOutlineBridge via a recording-fake RegionOutlineApplier.
//
// The fake records addOrUpdate/remove calls regardless of controller null-ness
// (mapControllerProvider overridden to null — no live MapLibre view in tests).
// Overrides:
//   - regionOutlineApplierProvider → _FakeRegionOutlineApplier (records calls)
//   - mapControllerProvider → null
//   - regionOutlineProvider / mapStyleLoadedTickProvider driven by the tests

import 'package:auto_explore/features/admin/data/admin_region.dart';
import 'package:auto_explore/features/map/presentation/providers/map_controller_provider.dart';
import 'package:auto_explore/features/map/presentation/providers/map_style_loaded_provider.dart';
import 'package:auto_explore/features/map/presentation/providers/region_outline_applier.dart';
import 'package:auto_explore/features/map/presentation/providers/region_outline_provider.dart';
import 'package:auto_explore/features/map/presentation/widgets/region_outline_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart' show MapLibreMapController;

sealed class _Call {}

final class _AddOrUpdate extends _Call {
  _AddOrUpdate(this.borderHex, this.fillHex);
  final String borderHex;
  final String fillHex;
}

final class _Remove extends _Call {}

class _FakeRegionOutlineApplier implements RegionOutlineApplier {
  final List<_Call> calls = [];

  @override
  Future<void> addOrUpdate(
    MapLibreMapController? controller,
    AdminRegion region, {
    required String borderHex,
    required String fillHex,
  }) async {
    calls.add(_AddOrUpdate(borderHex, fillHex));
  }

  @override
  Future<void> remove(MapLibreMapController? controller) async {
    calls.add(_Remove());
  }
}

class _NullMapControllerNotifier extends MapControllerNotifier {
  @override
  MapLibreMapController? build() => null;
}

AdminRegion _region() => const AdminRegion(
      osmId: 1,
      adminLevel: 8,
      name: 'Test',
      bboxMinLat: 48,
      bboxMinLon: 11,
      bboxMaxLat: 49,
      bboxMaxLon: 12,
      polygons: [
        [
          [
            [48.0, 11.0],
            [48.0, 12.0],
            [49.0, 12.0],
            [49.0, 11.0],
            [48.0, 11.0],
          ],
        ],
      ],
    );

Future<_FakeRegionOutlineApplier> _pump(
  WidgetTester tester, {
  required Brightness brightness,
}) async {
  final fake = _FakeRegionOutlineApplier();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        regionOutlineApplierProvider.overrideWithValue(fake),
        mapControllerProvider.overrideWith(_NullMapControllerNotifier.new),
      ],
      child: MaterialApp(
        theme: ThemeData(brightness: brightness),
        home: const Scaffold(body: RegionOutlineBridge()),
      ),
    ),
  );
  return fake;
}

ProviderContainer _container(WidgetTester tester) => ProviderScope.containerOf(
      tester.element(find.byType(RegionOutlineBridge)),
    );

void main() {
  group('RegionOutlineBridge', () {
    testWidgets('renders headless (SizedBox.shrink)', (tester) async {
      await _pump(tester, brightness: Brightness.dark);
      expect(
        find.descendant(
          of: find.byType(RegionOutlineBridge),
          matching: find.byType(SizedBox),
        ),
        findsOneWidget,
      );
    });

    testWidgets('show → addOrUpdate with light neutral hex in dark mode',
        (tester) async {
      final fake = await _pump(tester, brightness: Brightness.dark);
      _container(tester).read(regionOutlineProvider.notifier).show(_region());
      await tester.pump();

      final adds = fake.calls.whereType<_AddOrUpdate>().toList();
      expect(adds, hasLength(1));
      expect(adds.single.borderHex, equals(kRegionOutlineBorderDarkMode));
      expect(adds.single.fillHex, equals(kRegionOutlineFillDarkMode));
    });

    testWidgets('show → addOrUpdate with dark neutral hex in light mode',
        (tester) async {
      final fake = await _pump(tester, brightness: Brightness.light);
      _container(tester).read(regionOutlineProvider.notifier).show(_region());
      await tester.pump();

      final adds = fake.calls.whereType<_AddOrUpdate>().toList();
      expect(adds, hasLength(1));
      expect(adds.single.borderHex, equals(kRegionOutlineBorderLightMode));
      expect(adds.single.fillHex, equals(kRegionOutlineFillLightMode));
    });

    testWidgets('clear → remove', (tester) async {
      final fake = await _pump(tester, brightness: Brightness.dark);
      final notifier =
          _container(tester).read(regionOutlineProvider.notifier)..show(_region());
      await tester.pump();
      notifier.clear();
      await tester.pump();

      expect(fake.calls.whereType<_Remove>(), hasLength(1));
    });

    testWidgets('style-load tick re-adds while a region is set (Pitfall 1)',
        (tester) async {
      final fake = await _pump(tester, brightness: Brightness.dark);
      final container = _container(tester);
      container.read(regionOutlineProvider.notifier).show(_region());
      await tester.pump();
      final before = fake.calls.whereType<_AddOrUpdate>().length;

      // Simulate a style reload (light/dark swap wipes programmatic sources).
      container.read(mapStyleLoadedTickProvider.notifier).bump();
      await tester.pump();

      expect(
        fake.calls.whereType<_AddOrUpdate>().length,
        greaterThan(before),
        reason: 'outline re-added after style reload',
      );
    });

    testWidgets('style-load tick does NOT add when no region is set',
        (tester) async {
      final fake = await _pump(tester, brightness: Brightness.dark);
      _container(tester).read(mapStyleLoadedTickProvider.notifier).bump();
      await tester.pump();
      expect(fake.calls.whereType<_AddOrUpdate>(), isEmpty);
    });
  });
}
