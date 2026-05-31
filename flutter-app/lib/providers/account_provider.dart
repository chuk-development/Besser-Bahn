import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/db_account.dart';
import '../models/db_ticket.dart';
import '../services/db_account_service.dart';
import 'service_providers.dart';

/// Auth state for the DB account login.
class DbAuthState {
  /// false until storage has been checked (initial splash).
  final bool initialized;
  final DbProfile? profile;
  final bool isLoading;
  final String? error;

  const DbAuthState({
    this.initialized = false,
    this.profile,
    this.isLoading = false,
    this.error,
  });

  bool get isLoggedIn => profile != null;

  DbAuthState copyWith({
    bool? initialized,
    DbProfile? profile,
    bool? isLoading,
    String? error,
    bool clearProfile = false,
    bool clearError = false,
  }) {
    return DbAuthState(
      initialized: initialized ?? this.initialized,
      profile: clearProfile ? null : (profile ?? this.profile),
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class DbAuthNotifier extends Notifier<DbAuthState> {
  DbAccountService get _service => ref.read(dbAccountServiceProvider);

  @override
  DbAuthState build() {
    _restore();
    return const DbAuthState();
  }

  /// On startup: if a token exists, load the profile to validate the session.
  Future<void> _restore() async {
    try {
      if (await _service.hasSession()) {
        final profile = await _service.profile();
        state = state.copyWith(initialized: true, profile: profile);
        return;
      }
    } on DbAccountException catch (e) {
      // Only a genuine auth failure (401) means the stored session is dead —
      // then drop the tokens. The service has already cleared them on a failed
      // refresh, but be explicit. A transient error (offline, timeout, missing
      // platform keyring) must NOT wipe a valid refresh token, or the user is
      // forced to log in again on every cold start.
      if (e.status == 401) await _service.logout();
    } catch (_) {
      // Network/platform hiccup — keep the tokens, just show logged-out for
      // now; the next launch (or a manual retry) re-validates the session.
    }
    state = state.copyWith(initialized: true, clearProfile: true);
  }

  /// Runs the DB browser login.
  Future<void> login() async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final profile = await _service.login();
      state = state.copyWith(isLoading: false, profile: profile);
      _invalidateData();
    } catch (e) {
      state = state.copyWith(
          isLoading: false, error: _message(e), clearProfile: true);
    }
  }

  Future<void> logout() async {
    await _service.logout();
    state = const DbAuthState(initialized: true);
    _invalidateData();
  }

  /// Re-pull the profile (e.g. pull-to-refresh on the Profile tab).
  Future<void> reload() async {
    if (!state.isLoggedIn) return;
    try {
      final profile = await _service.profile();
      state = state.copyWith(profile: profile, clearError: true);
    } catch (e) {
      state = state.copyWith(error: _message(e));
    }
    _invalidateData();
  }

  void _invalidateData() {
    ref.invalidate(bahnbonusProvider);
    ref.invalidate(bahncardsProvider);
    ref.invalidate(ticketIndicesProvider);
  }

  String _message(Object e) {
    final s = e.toString();
    if (s.contains('CANCELED') || s.contains('cancel')) {
      return 'Anmeldung abgebrochen';
    }
    return e is DbAccountException ? e.message : 'Anmeldung fehlgeschlagen';
  }
}

final dbAuthProvider =
    NotifierProvider<DbAuthNotifier, DbAuthState>(DbAuthNotifier.new);

/// BahnBonus status — only fetched while logged in.
final bahnbonusProvider = FutureProvider<DbBahnBonus?>((ref) async {
  final auth = ref.watch(dbAuthProvider);
  if (!auth.isLoggedIn) return null;
  return ref.read(dbAccountServiceProvider).bahnbonus();
});

/// The user's BahnCards.
final bahncardsProvider = FutureProvider<List<DbBahnCard>>((ref) async {
  final auth = ref.watch(dbAuthProvider);
  if (!auth.isLoggedIn) return const [];
  return ref.read(dbAccountServiceProvider).bahncards();
});

/// Booked-trip overview (all orders, newest first).
final ticketIndicesProvider = FutureProvider<List<DbReiseIndex>>((ref) async {
  final auth = ref.watch(dbAuthProvider);
  if (!auth.isLoggedIn) return const [];
  return ref.read(dbAccountServiceProvider).reisenuebersicht(onlyCurrent: false);
});

/// A single booked ticket, keyed by "auftragsnummer/kundenwunschId".
final ticketProvider =
    FutureProvider.family<DbTicket, String>((ref, key) async {
  final parts = key.split('/');
  return ref.read(dbAccountServiceProvider).ticket(parts[0], parts[1]);
});

/// Maps a locally-saved journey key → the `rkUuid` of the matching DB "Meine
/// Reisen" trip created when the user bookmarked it while logged in, so the
/// same bookmark can remove it from the DB account again. In-memory for the
/// session (cross-session removal reconciles via the trip overview).
class DbSavedReiseIds extends Notifier<Map<String, String>> {
  @override
  Map<String, String> build() => {};

  void put(String key, String rkUuid) => state = {...state, key: rkUuid};

  /// Removes and returns the stored id for [key] (null if none).
  String? take(String key) {
    final id = state[key];
    if (id != null) state = {...state}..remove(key);
    return id;
  }
}

final dbSavedReiseIdsProvider =
    NotifierProvider<DbSavedReiseIds, Map<String, String>>(
        DbSavedReiseIds.new);
