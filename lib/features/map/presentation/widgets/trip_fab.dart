import 'package:auto_explore/features/map/presentation/widgets/glass_circle.dart';
import 'package:flutter/material.dart';

/// Bottom-right glass FAB stub for starting trip recording.
///
/// Phase 2 stub: tap shows a SnackBar "Trip recording is coming in Phase 3".
/// Phase 3 wires this button to the real trip-start flow.
class TripFab extends StatelessWidget {
  const TripFab({super.key});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Start trip — not yet available',
      button: true,
      child: GestureDetector(
        onTap: () {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Trip recording is coming in Phase 3'),
              duration: Duration(seconds: 2),
            ),
          );
        },
        child: const GlassCircle(
          size: 56,
          child: Icon(Icons.fiber_manual_record, size: 26),
        ),
      ),
    );
  }
}
