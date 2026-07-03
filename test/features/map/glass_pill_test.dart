import 'package:auto_explore/core/theme/liquid_glass_settings.dart';
import 'package:auto_explore/features/map/presentation/widgets/glass_circle.dart';
import 'package:auto_explore/features/map/presentation/widgets/glass_pill.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_renderer/liquid_glass_renderer.dart' as lg;

/// Pumps [widget] inside a [MaterialApp] with the given [brightness].
Future<void> pumpGlass(
  WidgetTester tester,
  Widget widget, {
  Brightness brightness = Brightness.light,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(brightness: brightness),
      home: Scaffold(body: Center(child: widget)),
    ),
  );
}

void main() {
  // Reset the G1 flag after every test to avoid cross-test pollution.
  tearDown(() {
    LiquidGlassSettings.platformBlurEnabled = false;
  });

  group('GlassPill — fallback path (platformSupportsBlurOverMap = false)', () {
    setUp(() {
      LiquidGlassSettings.platformBlurEnabled = false;
    });

    testWidgets('renders GlassPillFallback when flag is false', (tester) async {
      await pumpGlass(tester, const GlassPill(child: Text('X')));

      expect(find.byType(GlassPillFallback), findsOneWidget);
      expect(find.byType(lg.LiquidGlass), findsNothing);
    });

    testWidgets('does not use BackdropFilter', (tester) async {
      await pumpGlass(tester, const GlassPill(child: Text('X')));

      expect(find.byType(BackdropFilter), findsNothing);
    });

    testWidgets('fallback uses lightGlassTint in light theme', (tester) async {
      await pumpGlass(
        tester,
        const GlassPill(child: Text('X')),
      );

      final fallback = tester.widget<GlassPillFallback>(
        find.byType(GlassPillFallback),
      );
      expect(
        fallback.tint,
        LiquidGlassSettings.instance.lightGlassTint,
      );
    });

    testWidgets('fallback uses darkGlassTint in dark theme', (tester) async {
      await pumpGlass(
        tester,
        const GlassPill(child: Text('X')),
        brightness: Brightness.dark,
      );

      final fallback = tester.widget<GlassPillFallback>(
        find.byType(GlassPillFallback),
      );
      expect(
        fallback.tint,
        LiquidGlassSettings.instance.darkGlassTint,
      );
    });
  });

  group(
    'GlassPill — liquid glass path (platformSupportsBlurOverMap = true)',
    () {
      setUp(() {
        LiquidGlassSettings.platformBlurEnabled = true;
      });

      testWidgets('renders LiquidGlass when flag is true', (tester) async {
        await pumpGlass(tester, const GlassPill(child: Text('X')));

        expect(find.byType(lg.LiquidGlass), findsOneWidget);
        expect(find.byType(GlassPillFallback), findsNothing);
      });

      testWidgets('wraps LiquidGlass in a LiquidGlassLayer', (tester) async {
        await pumpGlass(tester, const GlassPill(child: Text('X')));

        expect(find.byType(lg.LiquidGlassLayer), findsOneWidget);
      });
    },
  );

  group(
    'GlassCircle — fallback path (platformSupportsBlurOverMap = false)',
    () {
      setUp(() {
        LiquidGlassSettings.platformBlurEnabled = false;
      });

      testWidgets('renders GlassCircleFallback when flag is false', (
        tester,
      ) async {
        await pumpGlass(
          tester,
          const GlassCircle(size: 44, child: Icon(Icons.settings_outlined)),
        );

        expect(find.byType(GlassCircleFallback), findsOneWidget);
        expect(find.byType(lg.LiquidGlass), findsNothing);
      });

      testWidgets('does not use BackdropFilter', (tester) async {
        await pumpGlass(
          tester,
          const GlassCircle(size: 44, child: Icon(Icons.settings_outlined)),
        );

        expect(find.byType(BackdropFilter), findsNothing);
      });
    },
  );

  group(
    'GlassCircle — liquid glass path (platformSupportsBlurOverMap = true)',
    () {
      setUp(() {
        LiquidGlassSettings.platformBlurEnabled = true;
      });

      testWidgets('renders LiquidGlass when flag is true', (tester) async {
        await pumpGlass(
          tester,
          const GlassCircle(size: 44, child: Icon(Icons.settings_outlined)),
        );

        expect(find.byType(lg.LiquidGlass), findsOneWidget);
        expect(find.byType(GlassCircleFallback), findsNothing);
      });
    },
  );
}
