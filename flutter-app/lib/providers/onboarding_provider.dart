import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/onboarding_service.dart';

/// Holds whether the first-launch onboarding has been completed.
///
/// Loaded once asynchronously at startup; until it resolves the value is
/// `null`, which the router treats as "don't redirect yet" so we never flash
/// the wrong screen. The onboarding flow flips it to `true` via [complete].
class OnboardingNotifier extends Notifier<bool?> {
  @override
  bool? build() {
    // Kick off the async load; the router stays put (initialLocation) until the
    // result lands and rebuilds the redirect.
    OnboardingService.hasSeen().then((v) => state = v);
    return null;
  }

  /// Mark onboarding finished and persist it.
  Future<void> complete() async {
    await OnboardingService.markSeen();
    state = true;
  }
}

final onboardingSeenProvider = NotifierProvider<OnboardingNotifier, bool?>(
  OnboardingNotifier.new,
);
