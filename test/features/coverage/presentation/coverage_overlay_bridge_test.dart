// Trailblazer Phase 7, Plan 07-06:
// Unit tests for CoverageOverlayBridge via a recording-fake CoverageOverlayApplier.
//
// The recording fake records calls REGARDLESS of controller null-ness (the null
// controller is provided via mapControllerProvider override). The bridge passes
// the (possibly null) controller directly to the applier — the production applier
// early-returns on null; the fake here records calls so assertions still fire.
//
// Overrides applied:
//   - coverageOverlayApplierProvider → FakeCoverageOverlayApplier (records calls)
//   - coverageOverlayDataProvider → StreamProvider override emitting empty data
//   - coveragePresetProvider → _FakeCoveragePresetNotifier (amber initial)
//   - coveragePresetValueProvider → amber initial, updated by tests
//   - mapControllerProvider → null (no live MapLibre platform view in tests)
//
// Test scenarios:
//   1. Style-load tick bump → applier.apply() called with amber + data.
//   2. Preset change (amber → green) → applier.updateColors() (NOT a 2nd full apply).
//   3. Coverage data re-emit → applier.apply() called again (reactive update path).

import 'dart:async';

import 'package:auto_explore/features/coverage/data/coverage_overlay_data.dart';
import 'package:auto_explore/features/coverage/data/coverage_overlay_providers.dart';
import 'package:auto_explore/features/coverage/domain/coverage_color_preset.dart';
import 'package:auto_explore/features/coverage/presentation/coverage_overlay_bridge.dart';
import 'package:auto_explore/features/coverage/presentation/coverage_overlay_layers.dart';
import 'package:auto_explore/features/coverage/presentation/coverage_preset_provider.dart';
import 'package:auto_explore/features/map/presentation/providers/map_controller_provider.dart';
import 'package:auto_explore/features/map/presentation/providers/map_style_loaded_provider.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart' show MapLibreMapController;

// ---------------------------------------------------------------------------
// Recording fakes
// ---------------------------------------------------------------------------

/// Sealed call-record type for `_FakeCoverageOverlayApplier`.
sealed class _ApplierCall {}

final class _ApplyCall extends _ApplierCall {
  _ApplyCall({required this.preset, required this.data});
  final CoverageColorPreset preset;
  final CoverageOverlayData data;
}

final class _UpdateColorsCall extends _ApplierCall {
  _UpdateColorsCall({required this.preset});
  final CoverageColorPreset preset;
}

final class _RemoveCall extends _ApplierCall {}

/// Records apply/updateColors/remove calls REGARDLESS of controller null-ness.
///
/// The production `MapLibreCoverageOverlayApplier` early-returns on null
/// controller, but this fake records calls so tests can assert on the
/// bridge's dispatch logic without a live map view.
class _FakeCoverageOverlayApplier implements CoverageOverlayApplier {
  final List<_ApplierCall> calls = [];

  @override
  Future<void> apply(
    MapLibreMapController? controller, {
    required CoverageOverlayData data,
    required CoverageColorPreset preset,
    required Brightness brightness,
  }) async {
    calls.add(_ApplyCall(preset: preset, data: data));
  }

  @override
  Future<void> updateColors(
    MapLibreMapController? controller, {
    required CoverageColorPreset preset,
    required Brightness brightness,
  }) async {
    calls.add(_UpdateColorsCall(preset: preset));
  }

  @override
  Future<void> remove(MapLibreMapController? controller) async {
    calls.add(_RemoveCall());
  }
}

/// Controllable Notifier that wraps a mutable [CoverageColorPreset] so tests
/// can update it synchronously without SharedPreferences.
class _FakeCoveragePresetNotifier
    extends AsyncNotifier<CoverageColorPreset>
    implements CoveragePresetNotifier {
  @override
  Future<CoverageColorPreset> build() async => CoverageColorPreset.amber;

  @override
  Future<void> select(CoverageColorPreset preset) async {
    state = AsyncData(preset);
  }
}

/// Null map controller notifier — returns null for the controller, simulating
/// the state before map creation or in widget tests without a real MapLibre view.
class _NullMapControllerNotifier extends MapControllerNotifier {
  @override
  MapLibreMapController? build() => null;
}

// ---------------------------------------------------------------------------
// Controllable stream source for coverage overlay data
// ---------------------------------------------------------------------------

/// A [StreamController] exposed to tests so they can push new
/// [CoverageOverlayData] values and simulate the "trip confirmed" reactive
/// update path.
final _dataStreamController =
    StreamController<CoverageOverlayData>.broadcast();

/// A second distinct-reference empty CoverageOverlayData for re-emit tests.
///
/// Using a list literal (not the canonical const `[]`) avoids Riverpod
/// deduplicating the second emission against [CoverageOverlayData.empty]:
/// both have 0 ways but this instance's list has a different identity, so
/// `==` returns false and the listener fires (List identity != List equality).
// ignore: prefer_const_constructors, prefer_const_literals_to_create_immutables
final _distinctEmptyData = CoverageOverlayData(<CoverageWay>[]);

// ---------------------------------------------------------------------------
// Test helpers
// ---------------------------------------------------------------------------

/// Builds a [ProviderScope] wrapping [CoverageOverlayBridge] with all
/// required overrides.
///
/// Returns the [_FakeCoverageOverlayApplier] and [ProviderContainer]
/// for assertions and state manipulation.
({
  Widget widget,
  _FakeCoverageOverlayApplier fake,
  ProviderContainer container,
}) _buildTestScope({CoverageColorPreset initialPreset = CoverageColorPreset.amber}) {
  final fake = _FakeCoverageOverlayApplier();

  final container = ProviderContainer(
    overrides: [
      coverageOverlayApplierProvider.overrideWithValue(fake),
      // Override coverageOverlayDataProvider with a controllable stream.
      coverageOverlayDataProvider.overrideWith(
        (ref) => _dataStreamController.stream,
      ),
      coveragePresetProvider.overrideWith(_FakeCoveragePresetNotifier.new),
      coveragePresetValueProvider.overrideWithValue(initialPreset),
      // Null controller — no live MapLibre; fake records calls regardless.
      mapControllerProvider
          .overrideWith(_NullMapControllerNotifier.new),
    ],
  );

  final widget = UncontrolledProviderScope(
    container: container,
    child: const Directionality(
      textDirection: TextDirection.ltr,
      child: CoverageOverlayBridge(),
    ),
  );

  return (widget: widget, fake: fake, container: container);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  setUp(() {
    // Recreate the stream controller for each test to avoid cross-test
    // pollution from the broadcast stream.
    if (_dataStreamController.hasListener) {
      _dataStreamController.add(CoverageOverlayData.empty);
    }
  });

  group('CoverageOverlayBridge', () {
    testWidgets(
      'style-load tick bump → applier.apply() called with amber + data',
      (tester) async {
        final (:widget, :fake, :container) = _buildTestScope();
        addTearDown(container.dispose);

        await tester.pumpWidget(widget);
        await tester.pump();

        // Emit coverage data before the tick bump so the bridge has data
        // to work with when the tick fires.
        _dataStreamController.add(CoverageOverlayData.empty);
        await tester.pump();
        await tester.pump();

        final countBefore = fake.calls.whereType<_ApplyCall>().length;

        // Simulate MapWidget._onStyleLoaded calling bump().
        container.read(mapStyleLoadedTickProvider.notifier).bump();
        // Emit data again so the bridge's _scheduleApplyWithCurrentData
        // finds it via ref.read(coverageOverlayDataProvider).value.
        _dataStreamController.add(CoverageOverlayData.empty);
        await tester.pump();
        await tester.pump(); // allow unawaited apply to complete

        final applyCalls = fake.calls.whereType<_ApplyCall>().toList();
        expect(
          applyCalls.length,
          greaterThan(countBefore),
          reason: 'apply() should have been called after tick bump',
        );
        expect(applyCalls.last.preset, CoverageColorPreset.amber);
      },
    );

    testWidgets(
      'data re-emit after tick bump → applier.apply() called again',
      (tester) async {
        final (:widget, :fake, :container) = _buildTestScope();
        addTearDown(container.dispose);

        await tester.pumpWidget(widget);
        await tester.pump();

        // Simulate style load + initial data.
        container.read(mapStyleLoadedTickProvider.notifier).bump();
        _dataStreamController.add(CoverageOverlayData.empty);
        await tester.pump();
        await tester.pump();

        final applyCountAfterBump =
            fake.calls.whereType<_ApplyCall>().length;
        expect(applyCountAfterBump, greaterThan(0),
            reason: 'expected at least one apply after bump + initial data');

        // Emit new coverage data — simulates a trip being confirmed.
        // Use a distinct-reference instance so Riverpod's equality check
        // detects a genuine change and fires the coverageOverlayDataProvider
        // listener (emitting CoverageOverlayData.empty again would be
        // deduplicated since empty == empty).
        _dataStreamController.add(_distinctEmptyData);
        await tester.pump();
        await tester.pump();

        final applyCountAfterReemit =
            fake.calls.whereType<_ApplyCall>().length;
        expect(
          applyCountAfterReemit,
          greaterThan(applyCountAfterBump),
          reason:
              'a data re-emit when style is ready must trigger another apply()',
        );
      },
    );

    testWidgets(
      'preset amber → green triggers updateColors (NOT a second full apply)',
      (tester) async {
        final (:widget, :fake, :container) = _buildTestScope();
        addTearDown(container.dispose);

        await tester.pumpWidget(widget);
        await tester.pump();

        // Simulate style load + initial data so _styleReady=true + _sourceAdded=true.
        container.read(mapStyleLoadedTickProvider.notifier).bump();
        _dataStreamController.add(CoverageOverlayData.empty);
        await tester.pump();
        await tester.pump();

        final applyCountAfterBump =
            fake.calls.whereType<_ApplyCall>().length;
        expect(applyCountAfterBump, greaterThan(0),
            reason: 'expected at least one apply after bump');

        // Change preset to green (update both async and sync providers).
        unawaited(
          container
              .read(coveragePresetProvider.notifier)
              .select(CoverageColorPreset.green),
        );
        container.updateOverrides([
          coverageOverlayApplierProvider.overrideWithValue(fake),
          coverageOverlayDataProvider.overrideWith(
            (ref) => _dataStreamController.stream,
          ),
          coveragePresetProvider
              .overrideWith(_FakeCoveragePresetNotifier.new),
          coveragePresetValueProvider
              .overrideWithValue(CoverageColorPreset.green),
          mapControllerProvider
              .overrideWith(_NullMapControllerNotifier.new),
        ]);
        await tester.pump();
        await tester.pump(); // allow unawaited updateColors to complete

        final applyCountAfterPresetChange =
            fake.calls.whereType<_ApplyCall>().length;
        final updateColorsCalls =
            fake.calls.whereType<_UpdateColorsCall>().toList();

        // No additional apply() — updateColors was used instead.
        expect(
          applyCountAfterPresetChange,
          equals(applyCountAfterBump),
          reason:
              'preset change after source is added must call updateColors, '
              'not a second full apply()',
        );
        expect(updateColorsCalls, isNotEmpty,
            reason: 'updateColors() must be called on preset change '
                'when source is already added');
        expect(updateColorsCalls.last.preset, CoverageColorPreset.green);
      },
    );

    testWidgets('renders a SizedBox.shrink (no visible UI)', (tester) async {
      final (:widget, :fake, :container) = _buildTestScope();
      addTearDown(container.dispose);

      await tester.pumpWidget(widget);
      await tester.pump();

      expect(
        find.descendant(
          of: find.byType(CoverageOverlayBridge),
          matching: find.byType(SizedBox),
        ),
        findsOneWidget,
      );
    });
  });
}
