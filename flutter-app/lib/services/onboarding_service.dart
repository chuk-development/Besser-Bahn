import 'package:shared_preferences/shared_preferences.dart';

/// Persists whether the one-time first-launch onboarding has been completed.
///
/// The router reads [seen] (loaded once at startup, cached in the provider) so
/// the redirect decision is instant and never flashes the wrong screen.
/// Existing users who upgrade into this feature have no flag set, so they see
/// the intro exactly once; after [markSeen] it never returns.
class OnboardingService {
  OnboardingService._();

  static const _key = 'seen_onboarding';

  /// Whether the user has already completed (or skipped through) onboarding.
  static Future<bool> hasSeen() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_key) ?? false;
  }

  /// Mark onboarding as done so it never shows again.
  static Future<void> markSeen() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_key, true);
  }
}
