import 'package:auto_explore/core/errors/result.dart';
import 'package:auto_explore/features/settings/data/cloud_backup_folder.dart';

/// Test double for [CloudBackupFolder].
///
/// Mutable public fields configure each method's outcome; spy lists record
/// calls. No platform channel is touched. Injected via `ProviderScope.overrides`
/// (mirrors `FakeFilePlatform`).
class FakeCloudBackupFolder implements CloudBackupFolder {
  /// Return value of [pickFolder] (true = a folder was picked).
  bool pickSucceeds = true;

  /// Return value of [hasFolder].
  bool hasFolderResult = true;

  /// Return value of [writeBackup]. Defaults to success.
  Result<void> writeResult = const Ok(null);

  /// Return value of [folderDisplayName].
  String? displayName = 'OneDrive › Trailblazer';

  /// Records how often [pickFolder] was called.
  int pickFolderCalls = 0;

  /// Records every (localFilePath, destFileName) pair passed to [writeBackup].
  final List<({String localFilePath, String destFileName})> writtenFiles =
      <({String localFilePath, String destFileName})>[];

  @override
  Future<bool> pickFolder() async {
    pickFolderCalls++;
    return pickSucceeds;
  }

  @override
  Future<bool> hasFolder() async => hasFolderResult;

  @override
  Future<Result<void>> writeBackup(
    String localFilePath,
    String destFileName,
  ) async {
    writtenFiles.add(
      (localFilePath: localFilePath, destFileName: destFileName),
    );
    return writeResult;
  }

  @override
  Future<String?> folderDisplayName() async => displayName;
}
