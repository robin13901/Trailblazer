import 'dart:io';

import 'package:auto_explore/features/onboarding/data/permission_service_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

/// FutureProvider that resolves to `true` when the denial banner should be
/// visible — i.e., when Always location is not granted, or (Android 13+)
/// when notification permission is not granted.
///
/// Uses `!isGranted` (not `isDenied`) to cover `denied`, `restricted`,
/// `limited`, and `permanentlyDenied` uniformly.
///
/// Defined here so tests can override it directly with a known value and
/// avoid any async timing in widget tests.
final permissionDenialBannerVisibleProvider = FutureProvider<bool>((ref) async {
  final svc = ref.watch(permissionServiceProvider);
  final always = await svc.statusAlways();
  if (!always.isGranted) return true;
  if (Platform.isAndroid) {
    final notif = await svc.statusNotification();
    if (!notif.isGranted) return true;
  }
  return false;
});

/// Full-width yellow glass banner that appears at the top of the map when
/// Always location (or Android notification) is not granted.
///
/// Tapping opens OS Settings via `PermissionService.openAppSettings`.
/// Re-evaluates on [AppLifecycleState.resumed] so the banner disappears
/// when the user grants the permission from Settings and returns.
class PermissionDenialBanner extends ConsumerStatefulWidget {
  const PermissionDenialBanner({super.key});

  @override
  ConsumerState<PermissionDenialBanner> createState() =>
      _PermissionDenialBannerState();
}

class _PermissionDenialBannerState extends ConsumerState<PermissionDenialBanner>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Invalidate and re-read after returning from Settings.
      ref.invalidate(permissionDenialBannerVisibleProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final visibleAsync = ref.watch(permissionDenialBannerVisibleProvider);

    return visibleAsync.when(
      data: (visible) {
        if (!visible) return const SizedBox.shrink();
        return _BannerContent(
          onTap: () async {
            await ref.read(permissionServiceProvider).openAppSettings();
          },
        );
      },
      loading: () => const SizedBox.shrink(),
      error: (_, _) => const SizedBox.shrink(),
    );
  }
}

/// Visual strip for the denial banner.
class _BannerContent extends StatelessWidget {
  const _BannerContent({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          height: 44,
          decoration: BoxDecoration(
            // Yellow glass: amber 500 at 85 % opacity.
            // withValues(alpha:) per STATE.md — never withOpacity.
            color: const Color(0xFFFFC107).withValues(alpha: 0.85),
            borderRadius: BorderRadius.circular(12),
            boxShadow: const [
              BoxShadow(
                color: Color(0x30000000),
                blurRadius: 8,
                offset: Offset(0, 2),
              ),
            ],
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Standort „Immer" aktivieren — zum Öffnen der Einstellungen tippen',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w500,
                        color: const Color(0xFF3E2C00),
                      ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const Icon(
                Icons.chevron_right,
                size: 18,
                color: Color(0xFF3E2C00),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
