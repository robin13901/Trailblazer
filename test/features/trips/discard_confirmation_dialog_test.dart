// Trailblazer Phase 6, Plan 06-05 Task 1 tests:
// DiscardConfirmationDialog — Cancel/Confirm return values + copy + destructive
// styling.

import 'package:auto_explore/core/theme/app_theme.dart';
import 'package:auto_explore/features/trips/presentation/widgets/discard_confirmation_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  /// Pumps a button that opens the dialog and records its bool result.
  Future<bool?> openAndTap(WidgetTester tester, String actionLabel) async {
    bool? captured;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () async {
                  captured = await DiscardConfirmationDialog.show(context);
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(actionLabel));
    await tester.pumpAndSettle();
    return captured;
  }

  testWidgets('Cancel returns false', (tester) async {
    final result = await openAndTap(tester, 'Cancel');
    expect(result, isFalse);
  });

  testWidgets('Confirm (Discard) returns true', (tester) async {
    final result = await openAndTap(tester, 'Discard');
    expect(result, isTrue);
  });

  testWidgets('title + body copy present', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: const Scaffold(body: DiscardConfirmationDialog()),
      ),
    );
    expect(find.text('Discard this trip?'), findsOneWidget);
    expect(
      find.textContaining('Raw GPS will be deleted'),
      findsOneWidget,
    );
    expect(find.textContaining('cannot be undone'), findsOneWidget);
  });

  testWidgets('Discard button uses the theme error color', (tester) async {
    final theme = AppTheme.light;
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: const Scaffold(body: DiscardConfirmationDialog()),
      ),
    );

    final discardButton = tester.widget<TextButton>(
      find.ancestor(
        of: find.text('Discard'),
        matching: find.byType(TextButton),
      ),
    );
    final resolvedColor = discardButton.style?.foregroundColor
        ?.resolve(<WidgetState>{});
    expect(resolvedColor, theme.colorScheme.error);
  });
}
