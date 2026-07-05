import 'package:auto_explore/features/onboarding/data/permission_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Provider for the [PermissionService] singleton.
///
/// Override this in tests with a `FakePermissionService` — no method-channel
/// mocking needed.
///
/// Plain `Provider<T>` — no `@Riverpod` codegen (see STATE.md Plan 01-01).
final permissionServiceProvider = Provider<PermissionService>(
  (ref) => const PermissionHandlerService(),
);
