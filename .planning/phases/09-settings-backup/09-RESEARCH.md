# Phase 9: Settings + Backup — Research

**Researched:** 2026-07-13
**Domain:** Flutter/Dart — Drift/SQLite live-database backup/restore, file picker/share, settings UI
**Confidence:** HIGH (core backup recipe), HIGH (file picker), HIGH (retention/permissions seams)

---

## Summary

Phase 9 is mostly a wiring phase: six of the seven in-scope requirements reuse existing code
with only glue needed. The one genuinely hard problem is backup/restore of a live WAL-mode Drift
database. The research resolves it with a concrete, testable recipe.

**Backup verdict:** Use `VACUUM INTO '<path>'` (SQLite 3.27+, bundled SQLite is 3.53.x so guaranteed
available). This produces a single-file snapshot with all WAL pages checkpointed into it — no -wal/-shm
sidecars on the output. The backup file is a plain .sqlite file. Share via `share_plus` 13.x on iOS
(UIActivityViewController) and Android (ACTION\_SEND) — this gives the user the OS-native share sheet
including iCloud Drive / Google Drive / Files. For restore-import, use `file_picker` 11.x `pickFiles()`
on both platforms.

**Restore verdict:** Validate incoming file (integrity\_check + user\_version), take a safety snapshot
(second VACUUM INTO), then: call `db.close()` explicitly, delete and replace the file(s), call
`ref.invalidate(appDatabaseProvider)` — Riverpod's `_performRebuild()` calls `runOnDispose()` which
fires the registered `db.close()` hook (confirmed from riverpod-3.0.3 source), then rebuilds the
provider via the `AppDatabase()` constructor which opens a fresh connection.

**Primary recommendation:** VACUUM INTO for export, share\_plus for export destination, file\_picker for
import source, explicit `db.close()` + file swap + `ref.invalidate()` for restore.

---

## Reuse Map

| SET req | Existing seam | What Phase 9 adds |
|---------|--------------|-------------------|
| SET-03 Permissions inspector | `PermissionService` 5 read-only status methods; `FakePermissionService` | New `PermissionsSection` widget; re-read on `AppLifecycleState.resumed` |
| SET-04 Coverage color | `CoverageColorSection` widget already in Settings under `_SectionHeader('Coverage')` | Keep it; just rename section header if needed |
| SET-05 Raw-GPS retention | `sweepRawGpsRetention(retention:)` in `TripsRepository`; `AppPrefs` key/setter pattern | Add `kRawGpsRetentionDays` key to `AppPrefs`; purge-now confirm dialog; feed retention value to sweep call |
| SET-06 Diagnostics HUD | `TrackingDiagnosticsScreen` (`kDebugMode`-gated, `/settings/diagnostics`) | Add `AppPrefs` bool toggle; remove `kDebugMode` gate from tile; extend `TrackingDiagnostics` with matcher queue depth + cache-hit rate |
| SET-07 Backup | Nothing — new feature | `BackupService` interface + `DriftBackupService` impl |
| SET-08 Restore | Nothing — new feature | `RestoreService` interface + `DriftRestoreService` impl |
| SET-09 About | `AboutSection` widget, already in Settings | No change needed |

---

## Standard Stack

### Core (existing, confirmed current as of 2026-07-13)

| Library | Version in pubspec | Purpose | Notes |
|---------|--------------------|---------|-------|
| drift | ^2.34.0 (2.34.1 latest) | ORM + `customStatement` | `customStatement` signature: `Future<void> customStatement(String, [List?])` |
| drift_flutter | ^0.3.0 (0.3.1 latest) | `driftDatabase(name:)` factory | **Uses `getApplicationDocumentsDirectory()`** (confirmed from source) |
| path_provider | ^2.1.6 | Resolves app-documents path | Already a direct dep |
| permission_handler | ^12.0.3 | Permission status rungs | Already used |
| shared_preferences | ^2.5.5 | `AppPrefs` backing store | Already used |

### New packages needed

| Library | Recommended version | Purpose | Why |
|---------|--------------------|---------|----|
| **share\_plus** | ^13.2.0 | Export: trigger OS share sheet (iOS UIActivityViewController, Android ACTION\_SEND) | The only correct mobile export mechanism; `file_picker.saveFile()` is desktop-only |
| **file\_picker** | ^11.0.2 | Import: OS file picker for restore | Works on iOS and Android; supports `FileType.custom` with extension filtering |

**Installation:**
```bash
# pubspec.yaml (alphabetize per sort_pub_dependencies lint)
file_picker: ^11.0.2
share_plus: ^13.2.0
```

### Alternatives considered

| Instead of | Could use | Tradeoff |
|------------|-----------|----------|
| share\_plus | file\_saver 0.4.0 | file\_saver saves to app-documents or Downloads, not share sheet — user can't choose cloud destination |
| file\_picker | Manual SAF / UIDocumentPickerViewController | Correct but requires platform-channel code; file\_picker is the established abstraction |

---

## Architecture Patterns

### Recommended project structure additions

```
lib/features/settings/
├── data/
│   ├── backup_service.dart          # abstract interface class BackupService
│   ├── drift_backup_service.dart    # DriftBackupService implements BackupService
│   └── backup_service_provider.dart # backupServiceProvider
├── domain/
│   └── backup_validation_result.dart # sealed: BackupValid / BackupInvalid(reason)
└── presentation/
    ├── settings_screen.dart          # EXTEND (new sections)
    ├── widgets/
    │   ├── data_backup_section.dart  # SET-07/08 backup+restore tiles
    │   ├── permissions_section.dart  # SET-03
    │   └── raw_gps_retention_section.dart # SET-05
    └── tracking_diagnostics_screen.dart  # EXTEND (toggle + new metrics)
```

---

## Backup / Restore Recipe (THE Hard Part)

### 1. Where drift\_flutter 0.3.0 stores the database

**Confirmed from source** (`drift_flutter-0.3.0/lib/src/native.dart` lines 36-37):

```dart
final resolvedDirectory = await (native?.databaseDirectory ??
    getApplicationDocumentsDirectory)();
// ...
File(p.join(resolvedDirectory.path, '$name.sqlite'))
```

`getApplicationDocumentsDirectory()` is called, not `getApplicationSupportDirectory()`.

| Platform | Path pattern |
|----------|-------------|
| Android | `/data/user/0/com.example.auto_explore/app_flutter/app_db.sqlite` |
| iOS | `/var/mobile/Containers/Data/Application/<UUID>/Documents/app_db.sqlite` |

Because the DB is in WAL mode (`PRAGMA journal_mode = WAL` in `beforeOpen`), three files may exist:
- `app_db.sqlite` — main database
- `app_db.sqlite-wal` — write-ahead log (may hold committed but not yet checkpointed data)
- `app_db.sqlite-shm` — shared memory index for the WAL

**A naive `File.copy()` of just `app_db.sqlite` while the DB is open will produce a corrupt backup if
the WAL holds unflushed pages.** Do not do this.

### 2. Backup approach: VACUUM INTO

**Why VACUUM INTO, not file copy + wal\_checkpoint:**

| Approach | Pros | Cons |
|----------|------|------|
| `PRAGMA wal_checkpoint(TRUNCATE)` then copy | Simple | Still copies three files; requires close or exclusive lock to be fully safe; race window between checkpoint and copy |
| SQLite Online Backup API | Correct, works while open | Not directly exposed by drift or sqlite3 Dart package at a high level; needs raw `sqlite3_backup_*` C API |
| **`VACUUM INTO 'path'`** | **Single SQL statement; produces one clean file; no sidecars on output; consistent snapshot; works while DB is open; SQLite 3.27+ (we have 3.53.x)** | Slightly slower than file copy on large DBs (reads all pages); output is in DELETE journal mode, not WAL — this is a feature, not a bug, for a portable backup |

**VACUUM INTO introduced in SQLite 3.27.0 (2019-02-07).** Bundled SQLite via `sqlite3 ^3.0.0` is
3.53.x as confirmed from the sqlite3 Dart package changelog. VACUUM INTO is available.

**VACUUM INTO output journal mode:** The output database starts in DELETE (rollback journal) mode
because it is a newly created file. When Drift opens it on restore, the `beforeOpen` callback sets
`PRAGMA journal_mode = WAL`, converting it automatically on first open. This is correct behavior.

**Drift API:** Use `db.customStatement("VACUUM INTO ?", [outputPath])`. This is a single-statement
call and does not update stream queries (the Drift docs caveat about `customStatement` not updating
stream queries does not apply here — VACUUM INTO writes to a separate file, not the open DB).

```dart
// In DriftBackupService.createBackup():
final destPath = p.join(tempDir.path, _buildFilename());
await db.customStatement('VACUUM INTO ?', [destPath]);
// destPath now contains a single-file, WAL-free, consistent backup.
```

**VACUUM INTO is transactional:** It produces a consistent snapshot even if a write transaction is
in progress concurrently. No need to pause the app or stop FGB.

### 3. Archive format

**Recommendation: bare `.trailblazer` extension.** Rationale:
- A VACUUM INTO output is already a single self-contained file — no zip/tar needed.
- A custom extension (`.trailblazer`) allows `file_picker` to filter by extension on restore
  (`allowedExtensions: ['trailblazer']`), and prevents users from accidentally opening a random
  `.sqlite` as a backup.
- File is internally a valid SQLite3 binary (magic bytes `53 51 4C 69 74 65 20 66 6F 72 6D 61 74 20 33`),
  so it is still inspect-able with any SQLite tool.
- Naming convention: `trailblazer_backup_YYYYMMDD_HHmm.trailblazer`.

### 4. Export flow

```dart
// 1. Create backup in temp directory (app-controlled, no permissions needed).
final tempDir = await getTemporaryDirectory();
final filename = 'trailblazer_backup_${_timestamp()}.trailblazer';
final tempFile = File(p.join(tempDir.path, filename));

// 2. VACUUM INTO the temp path.
await db.customStatement('VACUUM INTO ?', [tempFile.path]);

// 3. Share via OS share sheet.
await SharePlus.instance.share(
  ShareParams(files: [XFile(tempFile.path)]),
);

// 4. Clean up temp file after share completes (optional, OS will GC eventually).
await tempFile.delete();
```

Error mapping: wrap IO exceptions as `StorageError`, wrap DB exceptions as `DatabaseError`.

### 5. Archive validation (before restore)

Run these checks on the incoming file **before** touching the live database:

```dart
// Open the candidate file as a read-only in-memory connection.
// Use sqlite3 package directly for validation (not drift) to avoid
// triggering Drift's migration machinery prematurely.
import 'package:sqlite3/sqlite3.dart';

Future<BackupValidationResult> validateBackup(String path) {
  Database? db;
  try {
    db = sqlite3.open(path, mode: OpenMode.readOnly);

    // 1. SQLite magic bytes / file integrity.
    final intCheck = db.select('PRAGMA integrity_check').first.values.first;
    if (intCheck != 'ok') return BackupInvalid('integrity_check: $intCheck');

    // 2. Schema version must be <= current app schemaVersion (4).
    //    Drift stores schemaVersion in PRAGMA user_version.
    final uv = db.select('PRAGMA user_version').first.values.first as int;
    if (uv > kCurrentSchemaVersion) {
      return BackupInvalid('backup from newer app version ($uv > $kCurrentSchemaVersion)');
    }
    if (uv < 1) return BackupInvalid('not a Trailblazer backup (user_version=0)');

    // 3. Expected tables present.
    final tables = db.select(
      "SELECT name FROM sqlite_master WHERE type='table'"
    ).map((r) => r['name'] as String).toSet();
    const required = {'trips', 'trip_points', 'driven_way_intervals'};
    final missing = required.difference(tables);
    if (missing.isNotEmpty) return BackupInvalid('missing tables: $missing');

    return BackupValid(schemaVersion: uv);
  } on SqliteException catch (e) {
    return BackupInvalid('not a valid SQLite file: $e');
  } finally {
    db?.dispose();
  }
}
```

**Schema version mismatch handling:**
- `user_version < current (4)`: Accept. Drift will run `onUpgrade` migrations when the restored
  file is opened by `appDatabaseProvider`. This is the standard migration path.
- `user_version > current (4)`: **Reject.** The app cannot interpret a schema from a future version.
  Show an error: "This backup was created with a newer version of Trailblazer. Please update the app."
- `user_version == 0`: Reject (not a Drift DB, or a corrupt file).

**Note on `PRAGMA schema_version` vs `PRAGMA user_version`:** `schema_version` is SQLite-internal
and changes with every DDL operation — not suitable for our app version check. Drift stores
`schemaVersion` in `user_version`. Use `user_version`.

### 6. Restore flow (full wipe-and-swap)

```dart
Future<Result<void>> restore(String pickedFilePath) async {
  // Step 1: Validate incoming backup BEFORE touching anything.
  final validation = await validateBackup(pickedFilePath);
  if (validation is BackupInvalid) {
    return Err(StorageError('Invalid backup: ${validation.reason}'));
  }

  // Step 2: Safety snapshot of current DB into temp dir.
  //  (If anything goes wrong during swap, user still has their data here.)
  final tempDir = await getTemporaryDirectory();
  final safetyPath = p.join(tempDir.path, 'pre_restore_safety.trailblazer');
  await db.customStatement('VACUUM INTO ?', [safetyPath]);

  // Step 3: Close the live Drift database.
  //  CRITICAL: must happen before any file operations.
  await db.close();

  // Step 4: Delete existing DB files (main + wal + shm sidecars).
  final docsDir = await getApplicationDocumentsDirectory();
  final mainFile = File(p.join(docsDir.path, 'app_db.sqlite'));
  final walFile = File('${mainFile.path}-wal');
  final shmFile = File('${mainFile.path}-shm');
  for (final f in [mainFile, walFile, shmFile]) {
    if (await f.exists()) await f.delete();
  }

  // Step 5: Copy backup to DB location.
  await File(pickedFilePath).copy(mainFile.path);

  // Step 6: Invalidate appDatabaseProvider — Riverpod calls runOnDispose
  //  (fires db.close() again — safe, Drift close is idempotent), then
  //  rebuilds by calling AppDatabase() which opens a fresh connection.
  //  Drift's migration machinery will run onUpgrade if user_version < 4.
  ref.invalidate(appDatabaseProvider);

  return const Ok(null);
}
```

**CRITICAL DETAIL — provider invalidation timing:** `ref.invalidate()` schedules the rebuild for
the *next frame*, not synchronously. Any code that reads `appDatabaseProvider` immediately after
`invalidate()` in the same frame will still see the old (closed) provider. The backup UI should
navigate away or show a "restoring…" state; Riverpod will rebuild dependents on the next frame
and the DB will be open again.

**CRITICAL DETAIL — FGB does not hold a DB handle.** FGB runs in its own native process; it does
not hold a Dart/Drift connection to `app_db.sqlite`. The Drift background isolate (created by
`NativeDatabase.createBackgroundConnection`) is the only non-main-isolate reader. When `db.close()`
is called, that background isolate shuts down (confirmed from `drift_flutter-0.3.0` source:
`shutdownAfterLastDisconnect: true`). No stale handle risk from FGB.

**CRITICAL DETAIL — db.close() before ref.invalidate():** The sequence MUST be:
`db.close()` → file swap → `ref.invalidate()`. Do NOT call `ref.invalidate()` first and expect
the `onDispose` hook to close the DB before the file swap — `invalidate()` schedules the rebuild
for later and the dispose fires only when the rebuild actually runs (in `_performRebuild()`).
Explicitly call `db.close()` before touching files.

### 7. Test seam

```dart
// abstract interface class BackupService
abstract interface class BackupService {
  Future<Result<String>> createBackup();    // returns path of backup file
  Future<Result<void>> validateBackup(String path);
  Future<Result<void>> restore(String path);
}

// Fake for tests — no filesystem access, no drift
class FakeBackupService implements BackupService {
  String? lastExportedPath;
  bool validateShouldFail = false;
  bool restoreShouldFail = false;

  @override
  Future<Result<String>> createBackup() async {
    lastExportedPath = '/fake/backup.trailblazer';
    return Ok(lastExportedPath!);
  }
  // ...
}
```

Widget tests inject `FakeBackupService` via `ProviderScope.overrides`.
Unit tests for `DriftBackupService` use `NativeDatabase.memory()` for `AppDatabase`.

---

## File Picker / Share — Package Specification

### Export: share\_plus 13.2.0

```dart
// share_plus 13.x API (verified from pub.dev)
import 'package:share_plus/share_plus.dart';

await SharePlus.instance.share(
  ShareParams(
    files: [XFile(backupFilePath)],
    // subject shown in iOS share sheet title
    subject: 'Trailblazer Backup',
  ),
);
```

- No additional AndroidManifest or Info.plist configuration needed for file sharing.
- iOS: triggers `UIActivityViewController` — user sees AirDrop, Files, iCloud Drive, etc.
- Android: triggers `ACTION_SEND` — user sees Google Drive, Files, email, etc.
- Returns `ShareResult` with status (`success/dismissed/unavailable`).

### Import (restore): file\_picker 11.0.2

```dart
// file_picker 11.x API (verified from pub.dev)
import 'package:file_picker/file_picker.dart';

final result = await FilePicker.platform.pickFiles(
  type: FileType.custom,
  allowedExtensions: ['trailblazer'],
);

if (result != null) {
  final path = result.files.single.path!; // non-null on mobile
  // proceed to validateBackup(path) → restore(path)
}
```

iOS setup (Info.plist): For `FileType.custom` with a non-system extension, add:
- `UISupportsDocumentBrowser: true` (or `LSSupportsOpeningDocumentsInPlace: true`)

Android: No extra manifest entries for file\_picker 11.x; SAF is used automatically.

**Abstract interface for tests:**

```dart
abstract interface class FilePlatform {
  Future<String?> pickBackupFile();
  Future<void> shareFile(String path, {String? subject});
}

class FilePickerPlatformAdapter implements FilePlatform { /* wraps file_picker + share_plus */ }
class FakeFilePlatform implements FilePlatform {
  String? pickResult;  // set in test setup
  List<String> sharedPaths = [];
  @override Future<String?> pickBackupFile() async => pickResult;
  @override Future<void> shareFile(String path, {String? subject}) async {
    sharedPaths.add(path);
  }
}
```

---

## Raw-GPS Retention Setting

### AppPrefs additions

Following the existing getter/setter pattern in `app_prefs.dart`:

```dart
static const String kRawGpsRetentionDays = 'raw_gps_retention_days';

/// Retention window options: 0, 30, 365, or null (forever).
/// null = keep raw GPS points forever (no sweep).
/// 0 = delete points immediately after matching.
Future<int?> getRawGpsRetentionDays() =>
    _prefs.getInt(kRawGpsRetentionDays);

/// Persists [days]. Pass null for "forever" (deletes the key).
Future<void> setRawGpsRetentionDays(int? days) async {
  if (days == null) {
    await _prefs.remove(kRawGpsRetentionDays);
  } else {
    await _prefs.setInt(kRawGpsRetentionDays, days);
  }
}
```

**Sentinel values for `sweepRawGpsRetention`:**
- `days == null` (forever): do not call sweep at all.
- `days == 0` (delete after matching): call sweep with `retention: Duration.zero`.
  `sweepRawGpsRetention` computes `cutoff = now.subtract(Duration.zero) = now`, which deletes all
  trip_points for matched trips regardless of age. Verify this is what `TripsDao.deleteTripPointsForMatchedTripsOlderThan(cutoff)` does (it uses `isSmallerThanValue(cutoff)` — confirmed from the existing dao).
- `days == 30`: `Duration(days: 30)` — current default.
- `days == 365`: `Duration(days: 365)`.

**Purge-now on shortening:** When the user selects a shorter window (or 0), show a confirm dialog,
then call `sweepRawGpsRetention(retention: Duration(days: newDays), now: DateTime.now())` immediately.
The existing periodic sweep (Plan 05-01) continues enforcing the window on new trips.

**Where to wire the periodic sweep:** The startup sweep currently hardcodes 30 days. Phase 9 should
thread `AppPrefs.getRawGpsRetentionDays()` into the sweep call at startup. The planner should
identify the startup sweep call site and parameterize it.

---

## Permissions Inspector

### What exists

`PermissionService` already has exactly the five status rungs needed:

| Required row | `PermissionService` method |
|-------------|---------------------------|
| Location Always | `statusAlways()` |
| Location whenInUse | `statusWhenInUse()` |
| Motion/Activity | `statusActivityRecognition()` |
| Notifications | `statusNotification()` |
| Battery optimization | `statusIgnoreBatteryOptimizations()` |

iOS returns `PermissionStatus.granted` for `statusIgnoreBatteryOptimizations()` (no equivalent
concept on iOS) — already handled in `PermissionHandlerService`.

### Widget pattern

Re-read permissions on `AppLifecycleState.resumed` (user may have changed permissions in Settings
while app was backgrounded). This matches the existing denial-banner invalidation pattern (Plan 03-05).

```dart
class _PermissionsSection extends StatefulWidget ... {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refresh(); // re-read all statuses via PermissionService
    }
  }
}
```

No deep-links, no `openAppSettings()` calls — read-only in v1. The `FakePermissionService` from
`test/features/onboarding/fakes/fake_permission_service.dart` already exists for test doubles.

---

## Diagnostics HUD Toggle + Extension

### AppPrefs toggle key

```dart
static const String kShowDiagnosticsHud = 'show_diagnostics_hud';

Future<bool> getShowDiagnosticsHud() async =>
    (await _prefs.getBool(kShowDiagnosticsHud)) ?? false;

Future<void> setShowDiagnosticsHud(bool show) =>
    _prefs.setBool(kShowDiagnosticsHud, show);
```

### kDebugMode gate removal

Currently `TrackingDiagnosticsScreen` has a `_ReleaseModeShortCircuit` guard and the Settings tile
is inside `if (kDebugMode)`. Phase 9 must:
1. Remove the `if (kDebugMode)` block from `SettingsScreen` and replace with a `FutureBuilder` /
   `AppLifecycleAware` tile that shows/hides based on the new `AppPrefs` toggle.
2. Remove (or demote) the `_ReleaseModeShortCircuit` inside `TrackingDiagnosticsScreen` itself.

**Risk:** The existing `kDebugMode` guard means the stress-coverage tile (`_StressCoverageTile`) is
also in that block. It should remain debug-only. Separate the stress tile guard from the diagnostics
tile guard.

### Matcher queue depth + cache-hit rate metrics

**Matcher queue depth:** `PendingRoadFetchesDao.listPending()` returns all pending road-fetch rows.
`listPending().then((rows) => rows.length)` gives the queue depth. This is already in the app DB and
requires only a DAO read. `PendingRoadFetchesDao` is accessible via `appDatabaseProvider`.

**Overpass cache-hit rate:** `OverpassWayCandidateSource` does NOT currently expose per-call hit/miss
counters. The logic is entirely internal (`freshCached` and `missing` local maps in `_collectFreshTiles`).
There are no counters, no notifiers, no exposed metrics.

**Implication for planning:** To add cache-hit rate to the HUD, the planner has two options:
1. Add `int _cacheHits` and `int _cacheMisses` fields to `OverpassWayCandidateSource`, incrementing
   in `_collectFreshTiles`, and expose via a getter or a `DiagnosticsSnapshot` value object.
2. Derive a proxy metric: `OverpassWayCacheDao.totalBytes()` (shows cache is warm) + the count of
   `pending_road_fetches` rows (proxy for cache misses that needed a network fetch).

Option 1 is cleaner. The planner should flag this as a task: extend `OverpassWayCandidateSource`
with optional hit/miss counters, exposed via a new provider or via `TripMatchCoordinator`.

**`TrackingDiagnostics` DTO extension:** Add fields:
```dart
final int matcherQueueDepth;       // from PendingRoadFetchesDao.listPending().length
final int? overpassCacheHits;      // null until OverpassWayCandidateSource exposes counter
final int? overpassCacheMisses;    // null until same
```

---

## Common Pitfalls

### Pitfall 1: WAL sidecars on file copy
**What goes wrong:** Copying `app_db.sqlite` without the `-wal` sidecar produces a backup that is
missing committed but not-yet-checkpointed rows. The backup appears to open fine but is silently stale.
**How to avoid:** Use `VACUUM INTO` — it reads through the WAL and produces a single consistent file.
**Warning signs:** Backup round-trip test shows fewer rows than expected.

### Pitfall 2: ref.invalidate() before db.close()
**What goes wrong:** `invalidate()` schedules a rebuild for the next frame. If a file swap happens
between `invalidate()` and the actual dispose/rebuild, there is a window where the old (closed or
partially open) Drift connection tries to execute queries on a file that has already been replaced.
**How to avoid:** Explicit `await db.close()` BEFORE the file swap. Then `ref.invalidate()` after
the swap.

### Pitfall 3: drift_flutter path vs. app-support directory
**What goes wrong:** Assuming the DB is in `getApplicationSupportDirectory()` (common misconception).
`drift_flutter` uses `getApplicationDocumentsDirectory()`.
**Impact:** Restore deletes/replaces the wrong path, leaving the live DB intact and the swap silently
failing.
**How to avoid:** Call `getApplicationDocumentsDirectory()` to resolve the path, matching drift_flutter's behavior exactly.

### Pitfall 4: Backup including -wal sidecar on iOS
**What goes wrong:** VACUUM INTO produces a clean single file, but if someone accidentally copies
the main sqlite file only (e.g. via a file scan), they will get stale data on iOS where the WAL
may be large.
**How to avoid:** Use VACUUM INTO exclusively; never copy `app_db.sqlite` directly.

### Pitfall 5: user_version vs schema_version confusion
**What goes wrong:** Checking `PRAGMA schema_version` instead of `PRAGMA user_version` for the
backup schema check. `schema_version` increments with every DDL statement and is not under app
control; `user_version` is what Drift writes.
**How to avoid:** Use `PRAGMA user_version` in the validation step.

### Pitfall 6: file_picker.saveFile() on mobile
**What goes wrong:** Calling `FilePicker.platform.saveFile()` on iOS or Android — it is
**desktop-only** (confirmed from file\_picker wiki). Returns `null` silently on mobile.
**How to avoid:** Use `share_plus` for export on mobile. `saveFile()` is only for Windows/macOS/Linux.

### Pitfall 7: Riverpod invalidation scope
**What goes wrong:** After restore, widgets that were watching `appDatabaseProvider` dependents
(DAOs, repository providers) may briefly show stale data before the provider tree rebuilds.
**How to avoid:** Navigate to a loading/confirmation screen after triggering restore. The provider
chain will rebuild on the next navigation frame, giving all dependents a fresh DB.

### Pitfall 8: BackupService holds a direct db reference
**What goes wrong:** `DriftBackupService` stores a plain `AppDatabase` reference. After restore,
`ref.invalidate(appDatabaseProvider)` recreates the DB but `BackupService` still points at the old
closed instance.
**How to avoid:** `BackupService` should read `appDatabaseProvider` via `Ref.read()` on each call,
not cache the `AppDatabase` instance. Alternatively, make `BackupService` itself a Riverpod Provider
that is also invalidated on restore.

---

## State of the Art

| Old approach | Current approach | Impact |
|-------------|-----------------|--------|
| `PRAGMA wal_checkpoint(TRUNCATE)` + file copy | `VACUUM INTO 'path'` | Single SQL call, no sidecar race, cleaner output |
| Manual permission status checks in widget | `PermissionService.statusX()` (already abstracted) | Test doubles already exist |
| `kDebugMode`-gated HUD | AppPrefs bool toggle | Works in release builds |

---

## Open Questions

1. **Startup periodic sweep parameterization.** Where exactly is `sweepRawGpsRetention()` called at
   startup? The planner needs to find this call site and thread in `AppPrefs.getRawGpsRetentionDays()`.
   The method exists (`TripsRepository.sweepRawGpsRetention`), but the periodic caller location was
   not confirmed during this research pass.

2. **file\_picker iOS Info.plist requirement.** Confirm whether `UISupportsDocumentBrowser: true` or
   `LSSupportsOpeningDocumentsInPlace: true` is required in the project's Info.plist for
   `FileType.custom` to work on iOS. The app's current Info.plist was not inspected during this
   research. The planner should add a task to verify and patch.

3. **VACUUM INTO output journal mode — empirical confirmation.** The research confirms VACUUM INTO
   produces a single file and is introduced in SQLite 3.27. Whether the output is in DELETE mode
   (no WAL) was not definitively confirmed from documentation, only inferred (new file → no WAL
   sidecar). The restore path works regardless (Drift sets WAL on open), but a unit test that runs
   VACUUM INTO on an in-memory DB and checks the output's journal mode would close this gap.

4. **`OverpassWayCandidateSource` cache counter extension scope.** Planner should decide whether
   hit/miss counters go in the same Phase 9 execution wave as the HUD toggle, or if the HUD ships
   with `null` for cache metrics in v1.

5. **Safety snapshot deletion.** The pre-restore safety snapshot written to `getTemporaryDirectory()`
   is never explicitly deleted after a successful restore. The OS will eventually GC it. Planner
   should decide: delete on success, keep for N days, or expose a "clear backup cache" action.

---

## Sources

### Primary (HIGH confidence)
- `drift_flutter-0.3.0/lib/src/native.dart` (local pub cache) — confirmed `getApplicationDocumentsDirectory()` usage
- `riverpod-3.0.3/lib/src/core/element.dart` (local pub cache) — confirmed `_performRebuild()` calls `runOnDispose()` before rebuild; `ref.invalidate()` triggers full disposal lifecycle
- sqlite3 changelog (pub.dev/packages/sqlite3/changelog) — confirmed SQLite 3.53.x bundled
- SQLite release notes 3.27.0 (sqlite.org/releaselog/3_27_0.html) — confirmed VACUUM INTO introduced in 3.27.0
- drift docs + source — `customStatement(String, [List?])` signature confirmed; WAL setup in `app_database.dart` confirmed
- `lib/core/db/app_database.dart` (project source) — schemaVersion=4, `beforeOpen` sets WAL + foreign\_keys
- `lib/features/trips/data/trips_repository.dart` (project source) — `sweepRawGpsRetention` signature confirmed
- `lib/features/onboarding/data/permission_service.dart` (project source) — 5 read-only status rungs confirmed

### Secondary (MEDIUM confidence)
- pub.dev/packages/share\_plus — version 13.2.0, XFile-based API, iOS UIActivityViewController + Android ACTION\_SEND
- pub.dev/packages/file\_picker — version 11.0.2, `pickFiles(FileType.custom)` works on iOS+Android; `saveFile()` confirmed desktop-only
- pub.dev/packages/drift\_flutter — confirmed `getApplicationDocumentsDirectory()` usage

### Tertiary (LOW confidence)
- VACUUM INTO output journal mode (DELETE vs WAL): inferred from SQLite docs (new file → no WAL sidecar), not explicitly documented. Recommend empirical test.

---

## Metadata

**Confidence breakdown:**
- Backup recipe (VACUUM INTO): HIGH — SQLite version confirmed (3.53.x), API confirmed (`customStatement`), WAL behavior well-understood
- drift\_flutter path resolution: HIGH — confirmed from local pub cache source
- Riverpod invalidate disposal: HIGH — confirmed from local pub cache source (element.dart)
- file\_picker + share\_plus package versions: HIGH — verified from pub.dev
- saveFile() desktop-only: HIGH — confirmed from file\_picker wiki
- VACUUM INTO output journal mode: MEDIUM — not explicitly documented, inferred

**Research date:** 2026-07-13
**Valid until:** 2026-08-13 (stable libraries; drift and riverpod release infrequently)
