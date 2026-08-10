// Issue #2: Regions search must FULLY RESET when the user LEAVES the Regions
// tab. This test exercises the reset mechanism — `RegionsSearchResetOnLeave` —
// in isolation: it clears `regionSearchQueryProvider` on a branch-index
// transition OUT of the Regions branch (2), and does NOT clear on unrelated
// transitions or while staying on the Regions tab.

import 'package:auto_explore/features/map/presentation/widgets/regions_search_reset_on_leave.dart';
import 'package:auto_explore/features/regions/presentation/providers/region_browser_provider.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(int currentIndex) => ProviderScope(
  child: Directionality(
    textDirection: TextDirection.ltr,
    child: RegionsSearchResetOnLeave(currentIndex: currentIndex),
  ),
);

/// Reads the shared query provider from the pumped tree.
ProviderContainer _containerOf(WidgetTester tester) =>
    ProviderScope.containerOf(
      tester.element(find.byType(RegionsSearchResetOnLeave)),
    );

void main() {
  testWidgets('clears the search query when leaving the Regions tab (2 → 0)', (
    tester,
  ) async {
    await tester.pumpWidget(_host(2)); // start ON the Regions tab
    final container = _containerOf(tester);
    container.read(regionSearchQueryProvider.notifier).query = 'Kleinheubach';
    expect(container.read(regionSearchQueryProvider), 'Kleinheubach');

    // Leave the Regions tab → Map tab.
    await tester.pumpWidget(_host(0));
    // The clear is deferred to a post-frame callback (Riverpod forbids provider
    // writes inside didUpdateWidget), so pump one more frame to run it.
    await tester.pump();

    expect(container.read(regionSearchQueryProvider), '');
  });

  testWidgets('does NOT clear while staying on the Regions tab (2 → 2)', (
    tester,
  ) async {
    await tester.pumpWidget(_host(2));
    final container = _containerOf(tester);
    container.read(regionSearchQueryProvider.notifier).query = 'Bayern';

    // Rebuild with the SAME index (e.g. an unrelated MapScreen rebuild).
    await tester.pumpWidget(_host(2));

    expect(container.read(regionSearchQueryProvider), 'Bayern');
  });

  testWidgets(
    'does NOT clear on transitions between non-Regions tabs (0 → 1)',
    (tester) async {
      await tester.pumpWidget(_host(0));
      final container = _containerOf(tester);
      container.read(regionSearchQueryProvider.notifier).query = 'x';

      await tester.pumpWidget(_host(1));

      expect(container.read(regionSearchQueryProvider), 'x');
    },
  );
}
