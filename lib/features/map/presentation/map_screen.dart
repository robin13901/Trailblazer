import 'package:auto_explore/features/map/presentation/widgets/map_widget.dart';
import 'package:flutter/material.dart';

/// Phase-2 map screen. In this plan it hosts only the base [MapWidget].
///
/// Later plans layer glass chrome (02-05) and wire into the router via a
/// `StatefulShellRoute` (02-06). Deliberately has no [AppBar] per UI-06.
class MapScreen extends StatelessWidget {
  const MapScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      // No AppBar — UI-06 mandate (glass shell added in 02-05).
      body: MapWidget(),
    );
  }
}
