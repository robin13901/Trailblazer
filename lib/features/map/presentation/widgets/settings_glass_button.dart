import 'package:auto_explore/features/map/presentation/widgets/glass_circle.dart';
import 'package:flutter/material.dart';

/// Top-left glass button that will navigate to the Settings route.
///
/// Phase 2 stub: tap shows a SnackBar "Settings coming in Phase 10".
/// Plan 02-06 wires the route; Phase 10 implements the settings screen.
class SettingsGlassButton extends StatelessWidget {
  const SettingsGlassButton({super.key});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Settings',
      button: true,
      child: GestureDetector(
        onTap: () {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Settings coming in Phase 10'),
              duration: Duration(seconds: 2),
            ),
          );
        },
        child: const GlassCircle(
          size: 44,
          child: Icon(Icons.settings_outlined, size: 20),
        ),
      ),
    );
  }
}
