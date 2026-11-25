import 'package:auto_explore/core/errors/domain_error.dart';
import 'package:auto_explore/core/errors/result.dart';
import 'package:auto_explore/features/settings/data/cloud_backup_folder.dart';
import 'package:flutter/services.dart';

/// Production [CloudBackupFolder] backed by a native platform channel.
///
/// This is the ONLY file wiring the `MethodChannel` for persistent cloud-folder
/// access — the native handlers live in `ios/Runner/CloudBackupFolderPlugin.swift`
/// and `android/.../CloudBackupFolderHandler.kt`. Keep it the single importer of
/// the channel, mirroring how `FilePickerPlatformAdapter` owns `file_picker`.
///
/// Every method maps native failures to [Result] / `bool`; `PlatformException`s
/// are caught and wrapped in a [StorageError] so no raw throwable escapes. The
/// native `stale_bookmark` / `lost_permission` error codes map to a
/// user-facing "folder access lost — please re-pick" message.
class MethodChannelCloudBackupFolder implements CloudBackupFolder {
  const MethodChannelCloudBackupFolder();

  /// Error code the native side returns when the persisted folder handle can
  /// no longer be resolved or written (stale iOS bookmark / revoked Android
  /// SAF grant). Mapped to a re-pick prompt.
  static const String _lostAccessCode = 'stale_bookmark';
  static const String _lostAccessCodeAndroid = 'lost_permission';

  static const MethodChannel _channel = MethodChannel(
    'de.autoexplore.auto_explore/cloud_backup_folder',
  );

  @override
  Future<bool> pickFolder() async {
    try {
      final result = await _channel.invokeMethod<bool>('pickFolder');
      return result ?? false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<bool> hasFolder() async {
    try {
      final result = await _channel.invokeMethod<bool>('hasFolder');
      return result ?? false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<Result<void>> writeBackup(
    String localFilePath,
    String destFileName,
  ) async {
    try {
      await _channel.invokeMethod<void>('writeBackup', <String, String>{
        'localFilePath': localFilePath,
        'destFileName': destFileName,
      });
      return const Ok(null);
    } on PlatformException catch (e, st) {
      if (e.code == _lostAccessCode || e.code == _lostAccessCodeAndroid) {
        return Err(
          StorageError(
            'Ordnerzugriff verloren – bitte erneut wählen.',
            cause: e,
            stackTrace: st,
          ),
        );
      }
      return Err(
        StorageError(
          'Backup konnte nicht gespeichert werden: ${e.message ?? e.code}',
          cause: e,
          stackTrace: st,
        ),
      );
    }
  }

  @override
  Future<String?> folderDisplayName() async {
    try {
      return await _channel.invokeMethod<String>('folderDisplayName');
    } on PlatformException {
      return null;
    }
  }
}
