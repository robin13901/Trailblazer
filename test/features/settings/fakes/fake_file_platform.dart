import 'package:auto_explore/features/settings/data/file_platform.dart';

/// Test double for [FilePlatform].
///
/// Configures pick result and share outcome without touching platform channels.
/// Used in Plan 09-05 widget tests via `ProviderScope.overrides`.
class FakeFilePlatform implements FilePlatform {
  /// Path returned by [pickBackupFile]. Set to `null` to simulate cancellation.
  String? pickResult;

  /// Whether [shareFile] should report success. Defaults to `true`.
  bool shareSucceeds = true;

  /// Paths passed to [shareFile] in call order.
  final List<String> sharedPaths = [];

  @override
  Future<String?> pickBackupFile() async => pickResult;

  @override
  Future<bool> shareFile(String path, {String? subject}) async {
    sharedPaths.add(path);
    return shareSucceeds;
  }
}
