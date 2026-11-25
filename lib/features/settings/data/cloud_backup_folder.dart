import 'package:auto_explore/core/errors/domain_error.dart';
import 'package:auto_explore/core/errors/result.dart';
import 'package:auto_explore/features/settings/data/file_platform.dart';

/// Abstract seam for PERSISTENT write access to a user-chosen cloud folder
/// (intended to be a OneDrive-synced folder) used by the automatic-backup
/// feature.
///
/// `file_picker` cannot provide this: on iOS its directory pick returns a
/// transient path with no security-scoped bookmark, worthless after an app
/// restart. So each platform implements persistent folder access natively:
///
/// * **iOS** — `UIDocumentPickerViewController` (folder mode) saves a
///   security-scoped bookmark; writes resolve it via
///   `URL(resolvingBookmarkData:)` + `startAccessingSecurityScopedResource()`.
/// * **Android** — Storage Access Framework: `ACTION_OPEN_DOCUMENT_TREE` +
///   `takePersistableUriPermission`; writes go through `DocumentFile`.
///
/// The actual folder handle (bookmark blob / tree-URI) lives NATIVELY. Dart
/// only ever sees booleans, a display name, and `Result`s — never the
/// security-sensitive, platform-specific token.
///
/// Pattern mirrors [FilePlatform] and `BackgroundGeolocationFacade`: a single
/// `FakeCloudBackupFolder`. All failures surface via [Result] / `bool` — no
/// raw throwables leak.
abstract interface class CloudBackupFolder {
  /// Opens the native folder picker. On success, persists the folder handle
  /// (bookmark / tree-URI permission) natively and returns `true`. Returns
  /// `false` when the user cancels. Never throws.
  Future<bool> pickFolder();

  /// Whether a previously-picked folder handle is still resolvable AND
  /// writable right now. Returns `false` if no folder was chosen or access has
  /// been revoked / gone stale. Never throws.
  Future<bool> hasFolder();

  /// Copies the file at [localFilePath] into the chosen folder under the name
  /// [destFileName].
  ///
  /// Returns [Err] on any native failure (stale bookmark / lost permission /
  /// I/O). A lost-access failure is surfaced as a [StorageError] whose message
  /// is suitable for prompting the user to re-pick the folder.
  Future<Result<void>> writeBackup(String localFilePath, String destFileName);

  /// A best-effort display name of the chosen folder for the settings
  /// subtitle (e.g. `OneDrive › Trailblazer`), or `null` if none / unknown.
  Future<String?> folderDisplayName();
}
