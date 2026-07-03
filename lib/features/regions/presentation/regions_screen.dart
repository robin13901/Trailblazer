import 'package:flutter/material.dart';

/// Placeholder for the Regions browser — wired in Phase 8.
///
/// No AppBar — this screen renders inside the map shell stack when the Regions
/// tab is active. The opaque Scaffold background masks the base map. Chrome
/// (focus pill, settings button, FAB) is hidden on this tab.
class RegionsScreen extends StatelessWidget {
  const RegionsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Text(
          'Regions browser comes in Phase 8.',
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}
