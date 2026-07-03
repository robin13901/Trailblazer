import 'package:auto_explore/features/map/presentation/widgets/glass_pill.dart';
import 'package:flutter/material.dart';

/// Stub top-center focus-area pill.
///
/// Displays a placeholder dash (`—`) until Phase 8 wires this pill to live
/// region + coverage data. No tap handler in Phase 2.
///
/// Semantics label communicates the future intent to screen-reader users.
class FocusAreaPill extends StatelessWidget {
  const FocusAreaPill({super.key});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Focus area (not yet available)',
      child: GlassPill(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 18),
        child: Text(
          '—',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w500,
            fontSize: 14,
          ),
        ),
      ),
    );
  }
}
