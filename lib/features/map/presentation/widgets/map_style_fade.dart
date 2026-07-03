import 'package:flutter/material.dart';

/// Wraps its [child] in an [AnimatedOpacity].
///
/// Used by the map widget to fade the map out before `setStyle()` and
/// back in when `onStyleLoadedCallback` fires.
///
/// - [visible] == `true`  → opacity 1.0 (fully shown)
/// - [visible] == `false` → opacity 0.0 (faded out)
///
/// The 180 ms ease-in-out duration is intentionally short so the transition
/// feels snappy on theme toggle without a jarring cut.
class MapStyleFade extends StatelessWidget {
  const MapStyleFade({
    required this.visible,
    required this.child,
    super.key,
  });

  /// When `true` the child is fully opaque; when `false` it fades to 0.
  final bool visible;

  /// The widget to animate — typically the map host widget.
  final Widget child;

  @override
  Widget build(BuildContext context) => AnimatedOpacity(
        opacity: visible ? 1.0 : 0.0,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeInOut,
        child: child,
      );
}
