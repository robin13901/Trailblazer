import 'package:auto_explore/features/trips/data/tracking_service_providers.dart';
import 'package:auto_explore/features/trips/domain/tracking_diagnostics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Read-through provider — the debug HUD reads this once per polling tick
/// (~500 ms) via `ref.read`. `TrackingService.diagnostics` constructs a
/// fresh snapshot each call; there is no caching and no stream.
///
/// The HUD deliberately does NOT `watch` — it drives its own refresh via
/// `Timer.periodic + setState` so Riverpod doesn't rebuild the tree on
/// every fix.
///
/// Plain `Provider<T>` — no `@Riverpod` codegen (STATE.md 01-01 decision).
final trackingDiagnosticsProvider = Provider<TrackingDiagnostics>((ref) {
  return ref.watch(trackingServiceProvider).diagnostics;
});
