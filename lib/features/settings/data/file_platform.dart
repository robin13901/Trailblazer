/// Abstract seam for OS-level file platform operations:
/// export (share sheet) and import (file picker).
///
/// Isolates all platform-channel code to `FilePickerPlatformAdapter` so the
/// backup/restore UI and its widget tests never touch a platform channel.
///
/// Pattern mirrors `BackgroundGeolocationFacade` — prod adapter wraps the
/// real packages; tests inject `FakeFilePlatform`.
abstract interface class FilePlatform {
  /// Opens the OS document picker filtered to `.trailblazer` files.
  ///
  /// Returns the picked file path, or `null` if the user cancelled.
  Future<String?> pickBackupFile();

  /// Hands [path] to the OS share sheet (iOS UIActivityViewController /
  /// Android ACTION_SEND).
  ///
  /// Returns `true` if the share sheet reported success.
  Future<bool> shareFile(String path, {String? subject});
}
