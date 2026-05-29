import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/traewelling_models.dart';
import '../services/traewelling_service.dart';
import 'service_providers.dart';

/// Authentication state for the Träwelling integration.
class TraewellingAuthState {
  /// null while we haven't checked storage yet (splash/initial).
  final bool initialized;
  final TrwlUser? user;
  final bool isLoading;
  final String? error;

  const TraewellingAuthState({
    this.initialized = false,
    this.user,
    this.isLoading = false,
    this.error,
  });

  bool get isLoggedIn => user != null;

  TraewellingAuthState copyWith({
    bool? initialized,
    TrwlUser? user,
    bool? isLoading,
    String? error,
    bool clearUser = false,
    bool clearError = false,
  }) {
    return TraewellingAuthState(
      initialized: initialized ?? this.initialized,
      user: clearUser ? null : (user ?? this.user),
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class TraewellingAuthNotifier extends Notifier<TraewellingAuthState> {
  TraewellingService get _service => ref.read(traewellingServiceProvider);

  @override
  TraewellingAuthState build() {
    _restore();
    return const TraewellingAuthState();
  }

  /// On startup: if a token exists, fetch the current user to validate it.
  Future<void> _restore() async {
    try {
      if (await _service.hasSession()) {
        final user = await _service.currentUser();
        state = state.copyWith(initialized: true, user: user);
        return;
      }
    } catch (_) {
      // Stale/invalid token — fall through to logged-out.
      await _service.logout();
    }
    state = state.copyWith(initialized: true, clearUser: true);
  }

  Future<void> login() async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final user = await _service.login();
      state = state.copyWith(isLoading: false, user: user);
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: _humanize(e),
        clearUser: true,
      );
    }
  }

  Future<void> logout() async {
    await _service.logout();
    state = const TraewellingAuthState(initialized: true);
    // Drop any cached feed/social data tied to the old session.
    ref.invalidate(trwlDashboardProvider);
    ref.invalidate(trwlFollowersProvider);
    ref.invalidate(trwlFollowingsProvider);
    ref.invalidate(trwlFollowRequestsProvider);
  }

  Future<void> refreshUser() async {
    try {
      final user = await _service.currentUser();
      state = state.copyWith(user: user);
    } catch (_) {/* keep current */}
  }

  String _humanize(Object e) {
    final msg = e is TraewellingException ? e.message : e.toString();
    if (msg.contains('CANCELED') || msg.contains('cancel')) {
      return 'Anmeldung abgebrochen';
    }
    return msg;
  }
}

final traewellingAuthProvider =
    NotifierProvider<TraewellingAuthNotifier, TraewellingAuthState>(
        TraewellingAuthNotifier.new);

// --- Read-only feeds (auto-disposed, refreshable via ref.invalidate) --------

final trwlDashboardProvider =
    FutureProvider.autoDispose<List<TrwlStatus>>((ref) async {
  return ref.watch(traewellingServiceProvider).dashboard();
});

final trwlFollowersProvider =
    FutureProvider.autoDispose<List<TrwlUser>>((ref) async {
  return ref.watch(traewellingServiceProvider).followers();
});

final trwlFollowingsProvider =
    FutureProvider.autoDispose<List<TrwlUser>>((ref) async {
  return ref.watch(traewellingServiceProvider).followings();
});

final trwlFollowRequestsProvider =
    FutureProvider.autoDispose<List<TrwlUser>>((ref) async {
  return ref.watch(traewellingServiceProvider).followRequests();
});

/// Another user's public profile + statuses, keyed by username.
final trwlUserProfileProvider =
    FutureProvider.autoDispose.family<TrwlUser, String>((ref, username) async {
  return ref.watch(traewellingServiceProvider).userProfile(username);
});

final trwlUserStatusesProvider = FutureProvider.autoDispose
    .family<List<TrwlStatus>, String>((ref, username) async {
  return ref.watch(traewellingServiceProvider).userStatuses(username);
});
