// Phase 4 rescope Wave 2 (Plan 04-13):
// Riverpod providers for the Overpass client stack.
//
// Uses plain `Provider<T>` — no `@Riverpod` codegen (STATE Plan 01-01).
// Tests override any of these providers via `ProviderScope.overrides` /
// `ProviderContainer(overrides:)`.

import 'package:auto_explore/features/matching/data/overpass_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

/// Primary Overpass endpoint. Tests override with a `MockClient`-hosted URL
/// or an in-memory fixture endpoint.
final overpassEndpointProvider = Provider<Uri>(
  (_) => kOverpassPrimaryEndpoint,
);

/// Fallback Overpass endpoint. Selected via live probe on 2026-07-08 (Kumi +
/// private.coffee unresponsive; VK Maps mirror healthy — see
/// `overpass_client.dart` docstring).
final overpassFallbackEndpointProvider = Provider<Uri>(
  (_) => kOverpassFallbackEndpoint,
);

/// Shared `http.Client` for outbound HTTP. Closed automatically when the
/// container disposes.
final httpClientProvider = Provider<http.Client>((ref) {
  final client = http.Client();
  ref.onDispose(client.close);
  return client;
});

/// Overpass client wired to the shared HTTP client and endpoint providers.
final overpassClientProvider = Provider<OverpassClient>((ref) {
  final client = OverpassClient(
    client: ref.watch(httpClientProvider),
    primaryEndpoint: ref.watch(overpassEndpointProvider),
    fallbackEndpoint: ref.watch(overpassFallbackEndpointProvider),
  );
  // OverpassClient.close() would double-close the shared http.Client; we
  // deliberately do NOT register a dispose hook here — the httpClient's
  // own onDispose is the single lifecycle owner.
  return client;
});
