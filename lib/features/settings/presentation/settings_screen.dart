import 'package:flutter/material.dart';

/// Placeholder for the Settings screen — wired in Phase 10.
///
/// This is a top-level route (`/settings`), NOT inside the shell.
/// Reachable from the top-left settings glass button on the map screen.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: const Center(
        child: Text(
          'Settings comes in Phase 10.',
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}
