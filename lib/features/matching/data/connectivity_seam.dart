// Phase 4 rescope Wave 2 (Plan 04-15):
// Thin abstraction over `connectivity_plus` — the app only needs a boolean
// "is the device online enough to hit Overpass". A separate seam keeps the
// coordinator (04-15) testable without a platform channel and gives us
// somewhere to house any future retry-friendly heuristics (Wi-Fi vs mobile,
// captive portal detection).

import 'package:connectivity_plus/connectivity_plus.dart';

/// Seam that answers "does the device have a usable network connection?".
///
/// The real implementation (`ConnectivityPlusSeam`) delegates to
/// `connectivity_plus`; tests use a fake (`FakeConnectivitySeam` under
/// `test/helpers/`) that returns a canned value.
// The interface has a single method; downstream implementations may add
// helpers (e.g. `stream<bool>`), but the coordinator only needs `isOnline`.
// ignore_for_file: one_member_abstracts
abstract class ConnectivitySeam {
  Future<bool> isOnline();
}

/// Production adapter over `connectivity_plus`.
///
/// `connectivity_plus 7.x` returns a `List<ConnectivityResult>` — the device
/// can have multiple active links (e.g. Wi-Fi + VPN). We treat "online" as
/// "at least one non-`none` link" — the actual reachability check is left to
/// the HTTP layer (Overpass client's retry/fallback).
class ConnectivityPlusSeam implements ConnectivitySeam {
  ConnectivityPlusSeam({Connectivity? connectivity})
      : _connectivity = connectivity ?? Connectivity();

  final Connectivity _connectivity;

  @override
  Future<bool> isOnline() async {
    final result = await _connectivity.checkConnectivity();
    return result.any((r) => r != ConnectivityResult.none);
  }
}
