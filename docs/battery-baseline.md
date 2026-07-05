# Battery baseline — Trailblazer tracking (Phase 3)

Regression threshold: any change that increases the drain rate by > 20% (relative)
vs the reference row below must be justified and re-baselined.

**Status:** PENDING in-car drive. CLI shipped (`tool/battery_baseline.dart`); artifact scaffold in place.
Numeric fields below are populated by running `dart run tool/battery_baseline.dart stop` after the 60-minute
baseline drive. See 03-VERIFICATION.md SC5 for the deferred verification item.

## Reference measurement — Phase 3 close-out

| Metric | Value |
|---|---|
| Device | Samsung Galaxy S24 (SM-S921B) |
| OS | Android 14 (PENDING: exact build string from `adb shell getprop ro.build.display.id`) |
| App version | 0.1.0+1 |
| Commit | PENDING: in-car drive |
| Recorded | PENDING: in-car drive |
| Duration | 60 min |
| Start battery % | PENDING: in-car drive |
| End battery % | PENDING: in-car drive |
| Drain % | PENDING: in-car drive |
| Drain rate | PENDING: in-car drive %/hour |
| Est. mAh (S24 4000 mAh) | PENDING: in-car drive |
| Build mode | debug (Android release-license not procured yet — STATE.md 01-01/01-05) |
| Screen state | off during the drive |
| Notification | live-stats visible throughout (30 s update interval via `_notificationTicker` in `TrackingService`) |
| Profile | 20 min urban + 20 min Landstraße + 20 min Autobahn |

## Methodology

The measurement uses Android's `dumpsys batterystats --charged` per-UID power accounting.
The CLI resets the stats at drive start so the mAh reading is trip-scoped, not device-lifetime.

**Device setup:**
- Samsung Galaxy S24 (SM-S921B) — nominal battery 4000 mAh
- Android 14, Impeller renderer (Flutter 3.44.4 default)
- Background App Refresh permitted (battery-optimization exemption granted in onboarding)
- Location permission: Always
- Debug APK (FGB license is a "debug" FGB license — no GPS accuracy reduction vs release)

**FGB configuration at measurement time:**
- `distanceFilter: 10` (10-metre fix spacing)
- `desiredAccuracy: BackgroundGeolocationConfig.DESIRED_ACCURACY_HIGH`
- `heartbeatInterval: 60` (FGB heartbeat for iOS — no-op on Android)
- `notificationInterval: 30 s` (`_notificationTicker` in `TrackingService`)

**Known caveats:**
- Debug build: Dart VM and extra asserts inflate CPU cost ~10–15% vs release profile
- `flutter_background_geolocation` 5.3.0 "debug" license: functionally identical to commercial license (no mock GPS, same native SDK)
- Release-mode baseline deferred until Android FGB commercial license procured (STATE.md pending todos)

## Repro

1. Charge the device to 100%; unplug it.
2. `flutter run --debug --flavor prod` on the device (or `flutter install --debug` and launch by hand).
3. Grant all permissions in the onboarding ladder (whenInUse + Always + Notification + battery-optimization exemption).
4. On the map, tap the FAB to start a manual trip (auto-detection also captures if you drive off before tapping).
5. Drive the 20/20/20 profile above; keep the screen off (Trailblazer's notification will keep the FGS alive).
6. After ~60 minutes, tap the red Stop FAB to close the trip.
7. From a laptop with adb access:
   ```
   adb devices           # verify the S24 is listed
   dart run tool/battery_baseline.dart stop
   ```
8. Review the emitted row; commit `docs/battery-baseline.md` + `docs/battery-baseline.json`.

## Regression history

(Rows will accumulate here in future phases as we re-baseline.)
