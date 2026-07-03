---
phase: "01"
plan: "05"
name: "platform-permissions-manifest"
subsystem: "platform/native-config"
tags: ["ios", "android", "permissions", "manifest", "info-plist", "foreground-service", "background-location", "bluetooth", "motion"]
requires: ["01-01"]
provides:
  - "iOS Info.plist purpose strings for Location (WhenInUse/Always/AlwaysAndWhenInUse), Motion, Bluetooth (Always/Central)"
  - "iOS UIBackgroundModes: location + bluetooth-central"
  - "Android permission declarations for location (fine/coarse/background), foreground service (base + FGS_LOCATION), activity recognition, Bluetooth (legacy + modern), post_notifications, wake_lock"
  - "Android <service> skeleton with android:foregroundServiceType=\"location\" (placeholder .LocationRecordingService)"
affects:
  - "03-recording (flutter_background_geolocation runtime permission prompts + service class binding)"
  - "09-vehicle-detection (Bluetooth scan/connect runtime prompts)"
  - "01-06 (CI builds must succeed with these manifest changes)"
tech-stack:
  added: []
  patterns:
    - "iOS: purpose-string-per-UIBackgroundMode discipline (App Store validation)"
    - "Android: split legacy Bluetooth (maxSdkVersion=30) from modern BLUETOOTH_SCAN/CONNECT (API 31+)"
    - "Android 14+: FOREGROUND_SERVICE plus type-specific FOREGROUND_SERVICE_LOCATION"
key-files:
  created: []
  modified:
    - "ios/Runner/Info.plist"
    - "android/app/src/main/AndroidManifest.xml"
decisions:
  - "Skipped NSBluetoothPeripheralUsageDescription — deprecated per RESEARCH.md line 800; app is central-only."
  - "Kept minSdk = flutter.minSdkVersion (no bump) — all permission gating handled at manifest level via maxSdkVersion attributes + runtime prompts in Phase 3."
  - "Foreground service class is a placeholder (.LocationRecordingService). Phase 3 will rebind android:name to flutter_background_geolocation's TSLocationManager service."
metrics:
  duration: "~2 min"
  completed: "2026-07-03"
---

# Phase 01 Plan 05: Platform Permissions Manifest Summary

One-liner: **Declared all iOS Info.plist purpose strings + UIBackgroundModes and the full Android manifest permission block (location/motion/Bluetooth/FGS/notifications) plus a foreground-service skeleton, so Phase 3 can wire runtime code without touching native config.**

## What Was Built

### iOS (`ios/Runner/Info.plist`)
Appended purpose strings + UIBackgroundModes to the top-level `<dict>` (before `</dict>`, after existing Flutter-generated keys):

- `NSLocationWhenInUseUsageDescription`
- `NSLocationAlwaysAndWhenInUseUsageDescription`
- `NSLocationAlwaysUsageDescription`
- `NSMotionUsageDescription`
- `NSBluetoothAlwaysUsageDescription`
- `NSBluetoothCentralUsageDescription`
- `UIBackgroundModes` → `[location, bluetooth-central]`

Every `UIBackgroundModes` entry is backed by a matching purpose string (App Store rule):
- `location` → `NSLocationAlwaysAndWhenInUseUsageDescription`
- `bluetooth-central` → `NSBluetoothAlwaysUsageDescription`

`NSBluetoothPeripheralUsageDescription` intentionally omitted (deprecated; app is central-only).

### Android (`android/app/src/main/AndroidManifest.xml`)
Inserted permission block between `<manifest>` and `<application>`:

- Location: `ACCESS_FINE_LOCATION`, `ACCESS_COARSE_LOCATION`, `ACCESS_BACKGROUND_LOCATION`
- Foreground service: `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_LOCATION` (Android 14+)
- Motion: `ACTIVITY_RECOGNITION` (Android 10+)
- Bluetooth legacy (capped at API 30): `BLUETOOTH`, `BLUETOOTH_ADMIN`
- Bluetooth modern (API 31+): `BLUETOOTH_SCAN`, `BLUETOOTH_CONNECT`
- Notifications: `POST_NOTIFICATIONS` (Android 13+) — required for FGS ongoing notification
- `WAKE_LOCK`

Inserted `<service>` inside `<application>` (before `</application>`):

```xml
<service
    android:name=".LocationRecordingService"
    android:enabled="true"
    android:exported="false"
    android:foregroundServiceType="location" />
```

## Tasks Executed

| # | Task | Type | Commit | Notes |
|---|------|------|--------|-------|
| 5.1 | Add all iOS purpose strings + UIBackgroundModes to Info.plist | auto | `18d7f09` | 7 keys added, plist XML validated with Python ElementTree |
| 5.2 | Add full permission block + foreground service to AndroidManifest.xml | auto | `9f48362` | 10 permissions + <service> declaration, XML validated |

Final metadata commit: (recorded after this file is committed).

## Verification Status

- iOS Info.plist parses as valid XML (Python `xml.etree.ElementTree.parse` OK — used because `xmllint` unavailable on this Windows/Git Bash toolchain).
- All 7 required iOS keys present (grep confirmed).
- Android manifest parses as valid XML.
- All 10 required Android permissions + `foregroundServiceType="location"` present (grep confirmed).
- `flutter analyze` exits 0 (no issues found). Confirms no unintended Dart-side impact.
- `flutter build apk --debug` NOT executed on this machine — Android SDK licenses not accepted locally per STATE.md pending-todo; Plan 01-06 CI will exercise this.

## Deviations from Plan

### Auto-fixed / Auto-added

None. Manifest-only work executed exactly per spec.

### Rule 3 (unblock)

**xmllint unavailable on Git Bash / Windows.** Substituted Python `xml.etree.ElementTree.parse` for XML syntax validation (equivalent parser-level check). Documented here for reproducibility.

## Authentication Gates

None.

## Wave 2 Coordination Notes

- Ran alongside Plans 02 (Drift), 03 (router), 04 (errors/logging). No file-level overlap.
- Left the following unstaged files untouched (belong to sibling agents): `lib/core/logging/app_logger.dart`, `pubspec.yaml`, `pubspec.lock`, `lib/features/onboarding/data/`, `test/features/`.
- Only staged files: `ios/Runner/Info.plist`, `android/app/src/main/AndroidManifest.xml` per plan scope.

## Next Phase Readiness

- **Phase 3 (Recording):** Manifest ground truth is in place. `flutter_background_geolocation` initialisation can proceed without native config changes. Phase 3 will need to update `android:name=".LocationRecordingService"` to point at the plugin's real service class, and add runtime prompt UX for background location + activity recognition.
- **Phase 9 (Vehicle detection):** Bluetooth permissions are declared for both legacy and modern API levels. Runtime prompts (`BLUETOOTH_CONNECT`, `BLUETOOTH_SCAN`) still to add.
- **Plan 01-06 (CI):** First real `flutter build apk --debug` / `flutter build ios --release --no-codesign` executions happen there; they should pass on the strength of this plan's manifest correctness.

## Files Changed

- `ios/Runner/Info.plist` — +19 lines (purpose strings + UIBackgroundModes)
- `android/app/src/main/AndroidManifest.xml` — +41 lines (permissions + `<service>` skeleton)
