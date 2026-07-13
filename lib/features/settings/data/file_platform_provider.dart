import 'package:auto_explore/features/settings/data/file_picker_platform_adapter.dart';
import 'package:auto_explore/features/settings/data/file_platform.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Provides the production [FilePlatform] implementation.
///
/// Plain `Provider` — Riverpod codegen is OFF per project conventions.
/// Override with `FakeFilePlatform` in widget tests to avoid platform channels.
final filePlatformProvider = Provider<FilePlatform>(
  (_) => const FilePickerPlatformAdapter(),
);
