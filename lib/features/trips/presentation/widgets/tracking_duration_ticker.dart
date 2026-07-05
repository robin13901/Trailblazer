import 'dart:async';

import 'package:flutter/material.dart';

/// Thin StatefulWidget that owns a 1-second Timer.periodic and provides
/// the current wall-clock time to its child via a builder pattern.
///
/// The timer is created in initState and cancelled in dispose, ensuring
/// no timer leak on rebuild or tree removal (RESEARCH.md Pitfall 4 mitigation).
///
/// Usage:
/// ```dart
/// TrackingDurationTicker(
///   builder: (context, now) {
///     final elapsed = now.difference(startedAt);
///     return Text('${elapsed.inSeconds}s');
///   },
/// )
/// ```
class TrackingDurationTicker extends StatefulWidget {
  const TrackingDurationTicker({required this.builder, super.key});

  /// Called every second with the current wall-clock time.
  final Widget Function(BuildContext context, DateTime now) builder;

  @override
  State<TrackingDurationTicker> createState() =>
      _TrackingDurationTickerState();
}

class _TrackingDurationTickerState extends State<TrackingDurationTicker> {
  late Timer _t;
  DateTime _now = DateTime.now();

  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _now = DateTime.now());
    });
  }

  @override
  void dispose() {
    _t.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _now);
}
