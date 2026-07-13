import 'package:auto_explore/features/map/presentation/widgets/glass_circle.dart';
import 'package:flutter/material.dart';

/// Top-left glass button that navigates to the Settings route.
///
/// The tap behaviour is injected via [onTap] so this widget stays
/// router-agnostic and testable in isolation. The caller (MapScreen) passes
/// `() => context.go('/settings')`.
///
/// Phase 2 default: if [onTap] is null, the button renders but does nothing
/// (defensive for widget tests that pump this widget in isolation without a
/// GoRouter present).
class SettingsGlassButton extends StatelessWidget {
  const SettingsGlassButton({this.onTap, super.key});

  /// Called when the user taps the button.
  ///
  /// In production, the map screen passes `() => context.go('/settings')`.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Einstellungen',
      button: true,
      child: GestureDetector(
        onTap: onTap,
        child: const GlassCircle(
          size: 44,
          overMap: true,
          child: Icon(Icons.settings_outlined, size: 20),
        ),
      ),
    );
  }
}
