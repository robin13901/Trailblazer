---
plan: "05"
name: "platform-permissions-manifest"
wave: 2
depends_on: ["01"]
files_modified:
  - "ios/Runner/Info.plist"
  - "android/app/src/main/AndroidManifest.xml"
autonomous: true
requirements: ["FND-11"]
must_haves:
  truths:
    - "Every `UIBackgroundModes` entry in iOS Info.plist has a matching `NS*UsageDescription` string (App Store rule)."
    - "Android manifest declares BOTH `FOREGROUND_SERVICE` and `FOREGROUND_SERVICE_LOCATION` for Android 14+ compatibility."
    - "A `<service>` element with `foregroundServiceType=\"location\"` is present as a skeleton for Phase 3."
    - "iOS + Android debug builds still exit 0 (`flutter build ios --release --no-codesign` / `flutter build apk --debug`)."
  artifacts:
    - path: "ios/Runner/Info.plist"
      provides: "All 6 location/motion/Bluetooth purpose strings + UIBackgroundModes"
      contains: "NSLocationAlwaysAndWhenInUseUsageDescription"
    - path: "android/app/src/main/AndroidManifest.xml"
      provides: "Full permission block + foreground service declaration"
      contains: "foregroundServiceType=\"location\""
  key_links:
    - from: "ios/Runner/Info.plist"
      to: "UIBackgroundModes.location"
      via: "matched by NSLocationAlwaysAndWhenInUseUsageDescription"
      pattern: "NSLocationAlwaysAndWhenInUseUsageDescription"
    - from: "android/app/src/main/AndroidManifest.xml"
      to: "<service ... foregroundServiceType=\"location\" />"
      via: "matches FOREGROUND_SERVICE_LOCATION permission"
      pattern: "FOREGROUND_SERVICE_LOCATION"
---

<objective>
Declare all iOS `Info.plist` purpose strings + `UIBackgroundModes` and the full Android permission block (location, motion, Bluetooth, notifications, foreground service) so Phase 3 (`flutter_background_geolocation`) and Phase 9 (Bluetooth) can add runtime code without a native manifest reconfigure. No runtime permission calls are made in Phase 1 — that's Phase 3's job.
</objective>

<context>
- **iOS Info.plist additions:** RESEARCH.md lines 766-796.
- **iOS gotchas:** RESEARCH.md lines 799-803 (must-have keys for App Store validation).
- **Android manifest additions:** RESEARCH.md lines 806-850.
- **Android gotchas:** RESEARCH.md lines 852-857 (FOREGROUND_SERVICE_LOCATION is separate from FOREGROUND_SERVICE; service declaration mandatory).
- **CONTEXT.md decision:** location permission is triggered on first map interaction (Phase 2), NOT during onboarding — so this plan only declares, never prompts.
- **The `<service>` element** is a skeleton for `flutter_background_geolocation` in Phase 3; do NOT implement the actual Android service class here. `android:name=".LocationRecordingService"` is a placeholder — Phase 3 will map it to the plugin's real service.
</context>

<tasks>

<task id="5.1" type="auto">
  <name>Add all iOS purpose strings + UIBackgroundModes to Info.plist</name>
  <files>
    - `ios/Runner/Info.plist`
  </files>
  <action>
    Open `ios/Runner/Info.plist` (XML plist created by `flutter create` in Plan 01). Add the following keys inside the top-level `<dict>` — DO NOT overwrite existing entries like `CFBundleName`, `CFBundleIdentifier`, `UILaunchStoryboardName`.

    Insert this block near the end of the top-level `<dict>` (immediately before `</dict>`):

    ```xml
    <!-- ==== Auto-Explore permission strings ==== -->

    <key>NSLocationWhenInUseUsageDescription</key>
    <string>Auto-Explore records your route while you drive to show which roads you've explored.</string>

    <key>NSLocationAlwaysAndWhenInUseUsageDescription</key>
    <string>Auto-Explore records trips in the background so you never miss a road you've driven.</string>

    <key>NSLocationAlwaysUsageDescription</key>
    <string>Auto-Explore needs Always location access to record trips while your phone is locked.</string>

    <key>NSMotionUsageDescription</key>
    <string>Auto-Explore uses motion sensors to detect when you start and stop driving.</string>

    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>Auto-Explore can use your car's Bluetooth connection to automatically detect which vehicle you're driving.</string>

    <key>NSBluetoothCentralUsageDescription</key>
    <string>Auto-Explore can use Bluetooth to detect your vehicle.</string>

    <key>UIBackgroundModes</key>
    <array>
      <string>location</string>
      <string>bluetooth-central</string>
    </array>

    <!-- ==== end Auto-Explore ==== -->
    ```

    Verification detail — every `UIBackgroundModes` value must have a matching `NS*UsageDescription`:
    - `location` → `NSLocationAlwaysAndWhenInUseUsageDescription` ✓
    - `bluetooth-central` → `NSBluetoothAlwaysUsageDescription` ✓

    Do NOT add `NSBluetoothPeripheralUsageDescription` (deprecated per RESEARCH.md line 800).
  </action>
  <verify>
    ```bash
    # Plist syntax validation (macOS only; on Windows/Linux, xmllint works too):
    xmllint --noout ios/Runner/Info.plist

    # Confirm all keys present:
    for k in NSLocationWhenInUseUsageDescription \
             NSLocationAlwaysAndWhenInUseUsageDescription \
             NSLocationAlwaysUsageDescription \
             NSMotionUsageDescription \
             NSBluetoothAlwaysUsageDescription \
             NSBluetoothCentralUsageDescription \
             UIBackgroundModes; do
      grep -q "<key>$k</key>" ios/Runner/Info.plist || { echo "MISSING: $k"; exit 1; }
    done
    echo "All Info.plist keys present."
    ```
  </verify>
  <done>Plist is well-formed XML and contains all 7 required keys.</done>
</task>

<task id="5.2" type="auto">
  <name>Add full permission block + foreground service to AndroidManifest.xml</name>
  <files>
    - `android/app/src/main/AndroidManifest.xml`
  </files>
  <action>
    Edit `android/app/src/main/AndroidManifest.xml` (created by `flutter create` in Plan 01). Insert the `<uses-permission>` elements INSIDE the `<manifest>` element but BEFORE the `<application>` element. Insert the `<service>` element INSIDE the existing `<application>` block.

    **Permissions block — insert between `<manifest ...>` and `<application ...>`:**

    ```xml
    <!-- ==== Auto-Explore permissions (Phase 1 scaffolding) ==== -->

    <!-- Location -->
    <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
    <uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION" />
    <!-- Background location — separate runtime prompt on Android 10+ -->
    <uses-permission android:name="android.permission.ACCESS_BACKGROUND_LOCATION" />

    <!-- Foreground service (base + type-specific for Android 14+) -->
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_LOCATION" />

    <!-- Activity recognition — Android 10+ (API 29+) -->
    <uses-permission android:name="android.permission.ACTIVITY_RECOGNITION" />

    <!-- Bluetooth Classic (legacy devices; capped at API 30) -->
    <uses-permission android:name="android.permission.BLUETOOTH"
                     android:maxSdkVersion="30" />
    <uses-permission android:name="android.permission.BLUETOOTH_ADMIN"
                     android:maxSdkVersion="30" />

    <!-- Bluetooth modern (Android 12+ / API 31+) -->
    <uses-permission android:name="android.permission.BLUETOOTH_SCAN" />
    <uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />

    <!-- Notifications — Android 13+ (API 33+); needed for FGS notification -->
    <uses-permission android:name="android.permission.POST_NOTIFICATIONS" />

    <!-- Wake lock — required by flutter_background_geolocation in Phase 3 -->
    <uses-permission android:name="android.permission.WAKE_LOCK" />

    <!-- ==== end Auto-Explore permissions ==== -->
    ```

    **Foreground service skeleton — insert INSIDE the existing `<application ...>` element** (near the end, before `</application>`):

    ```xml
    <!-- Foreground service skeleton for Phase 3 (flutter_background_geolocation
         will map its actual service class to this declaration). -->
    <service
        android:name=".LocationRecordingService"
        android:enabled="true"
        android:exported="false"
        android:foregroundServiceType="location" />
    ```

    Notes:
    - `android:name=".LocationRecordingService"` uses the app package's default namespace. Phase 3 will point this at the plugin's actual `TSLocationManager` service (or add a matching class); at Phase 1 the declaration alone satisfies FND-11's "scaffolded from day one".
    - Do NOT touch existing `<activity android:name=".MainActivity" ...>` — `flutter create` generated it correctly.
    - Ensure the `xmlns:android="http://schemas.android.com/apk/res/android"` on the `<manifest>` element is preserved.
  </action>
  <verify>
    ```bash
    xmllint --noout android/app/src/main/AndroidManifest.xml

    for perm in ACCESS_FINE_LOCATION ACCESS_BACKGROUND_LOCATION \
                FOREGROUND_SERVICE FOREGROUND_SERVICE_LOCATION \
                ACTIVITY_RECOGNITION BLUETOOTH_SCAN BLUETOOTH_CONNECT \
                POST_NOTIFICATIONS WAKE_LOCK; do
      grep -q "android.permission.$perm" android/app/src/main/AndroidManifest.xml \
        || { echo "MISSING: $perm"; exit 1; }
    done
    grep -q 'foregroundServiceType="location"' android/app/src/main/AndroidManifest.xml
    echo "AndroidManifest.xml validated."

    # And prove Gradle still compiles the manifest — this catches typos that xmllint misses:
    flutter build apk --debug
    ```
  </verify>
  <done>
    - Manifest is well-formed XML.
    - All required permissions present.
    - `<service ... foregroundServiceType="location" />` present.
    - `flutter build apk --debug` exits 0.
  </done>
</task>

</tasks>

<verification>
```bash
xmllint --noout ios/Runner/Info.plist android/app/src/main/AndroidManifest.xml
flutter build apk --debug
# On a macOS runner:
# flutter build ios --release --no-codesign
```
Both builds exit 0.
</verification>

<must_haves>
Delivers FND-11. Contributes directly to phase Success Criterion 5 (empty app launches on iOS + Android using declared Info.plist purpose strings and Android manifest foregroundServiceType="location" without crashing). Contributes to SC3 (iOS + Android builds succeed in CI — Plan 06 runs them).
</must_haves>
