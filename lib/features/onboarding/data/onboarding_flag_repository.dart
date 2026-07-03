import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Repository around [SharedPreferencesAsync] for the one-shot
/// `onboarding_done` flag. Kept minimal — no in-memory cache; the router
/// reads it once at redirect time.
class OnboardingFlagRepository {
  OnboardingFlagRepository(this._prefs);

  static const String prefsKey = 'onboarding_done';

  final SharedPreferencesAsync _prefs;

  Future<bool> isDone() async => (await _prefs.getBool(prefsKey)) ?? false;

  Future<void> markDone() async => _prefs.setBool(prefsKey, true);

  Future<void> reset() async => _prefs.remove(prefsKey);
}

/// Provider for the singleton [OnboardingFlagRepository].
///
/// NOTE: Uses a plain `Provider` (not `@Riverpod` code-gen) because
/// `riverpod_generator`/`custom_lint` are temporarily out of the toolchain
/// (see STATE.md Plan 01-01 decision).
final onboardingFlagRepositoryProvider = Provider<OnboardingFlagRepository>(
  (ref) => OnboardingFlagRepository(SharedPreferencesAsync()),
);
