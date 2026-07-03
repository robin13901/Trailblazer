import 'package:flutter/material.dart';

/// Placeholder for the Trips inbox — wired in Phase 6.
///
/// No AppBar — this screen renders inside the map shell stack when the Trips
/// tab is active. The opaque Scaffold background masks the base map. Chrome
/// (focus pill, settings button, FAB) is hidden on this tab.
class TripsScreen extends StatelessWidget {
  const TripsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Text(
          'Trips inbox comes in Phase 6.',
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}
