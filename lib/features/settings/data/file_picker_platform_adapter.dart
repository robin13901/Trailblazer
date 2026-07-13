import 'package:auto_explore/features/settings/data/file_platform.dart';
import 'package:file_picker/file_picker.dart';
import 'package:share_plus/share_plus.dart';

/// Production [FilePlatform] adapter that wraps `file_picker` and `share_plus`.
///
/// This is the ONLY file in the codebase that imports `file_picker` or
/// `share_plus` directly. All other code depends on the [FilePlatform]
/// interface and uses either this adapter (prod) or `FakeFilePlatform` (tests).
class FilePickerPlatformAdapter implements FilePlatform {
  /// Creates a [FilePickerPlatformAdapter].
  const FilePickerPlatformAdapter();

  @override
  Future<String?> pickBackupFile() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['trailblazer'],
    );
    return result?.files.single.path;
  }

  @override
  Future<bool> shareFile(String path, {String? subject}) async {
    final result = await SharePlus.instance.share(
      ShareParams(
        files: [XFile(path)],
        subject: subject,
      ),
    );
    return result.status == ShareResultStatus.success;
  }
}
