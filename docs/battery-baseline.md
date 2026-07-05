# Battery baseline — Trailblazer tracking (Phase 3)

Regression threshold: any change that increases the drain rate by > 20% (relative)
vs the reference row below must be justified and re-baselined.

## Reference measurement — Phase 3 close-out

| Metric | Value |
|---|---|
| Device | Samsung Galaxy S24 (SM-S921B) |
| OS | TBD |
| App version | 0.1.0+1 |
| Commit | TBD |
| Recorded | TBD |
| Duration | 60 min |
| Start battery % | TBD |
| End battery % | TBD |
| Drain % | TBD |
| Drain rate | TBD %/hour |
| Est. mAh (S24 4000 mAh) | TBD |
| Build mode | debug (Android release-license not procured yet — STATE.md 01-01/01-05) |
| Screen state | off during the drive |
| Notification | live-stats visible throughout |
| Profile | 20 min urban + 20 min Landstraße + 20 min Autobahn |

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
