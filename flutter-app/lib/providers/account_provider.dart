import 'dart:async' show unawaited;
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/app_log.dart';
import '../core/bahncard_art_cache.dart';
import '../core/bahncard_webview_cache.dart';
import '../models/db_account.dart';
import '../models/db_ticket.dart';
import '../models/journey.dart';
import '../models/library_models.dart' show SavedJourney;
import '../models/split_ticket.dart' show BahnCardType;
import '../models/station.dart';
import '../services/db_account_service.dart';
import 'library_provider.dart';
import 'service_providers.dart';
import 'settings_provider.dart';

/// On-disk persistence for the BahnCard list — including the bildSicht +
/// kontrollSicht PNGs that take ~100 KB total. Lets the BahnCard view (and
/// the Kontrollansicht) work offline and across cold starts, exactly like
/// the official DB Navigator caches it locally.
class _BahnCardCache {
  // v3: fields renamed from `Uint8List? bildSicht/kontrollSicht` (raw bytes
  // we wrongly tried to decode as PNG) to `String? bildSichtHtml /
  // kontrollSichtHtml` (the actual HTML payload DB serves). The persisted
  // JSON shape still mirrors the API (base64-encoded HTML), but v2 may have
  // half-baked entries — bump key + drop v2 to be safe.
  static const _kKey = 'db_bahncards_cache_v3';

  static Future<({List<DbBahnCard> cards, DateTime? fetchedAt})> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kKey);
      if (raw == null || raw.isEmpty) {
        return (cards: const <DbBahnCard>[], fetchedAt: null);
      }
      final data = json.decode(raw);
      if (data is Map<String, dynamic>) {
        final list = (data['cards'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(DbBahnCard.fromJson)
            .toList();
        final ts = data['fetchedAtMs'] as int?;
        return (
          cards: list,
          fetchedAt: ts != null
              ? DateTime.fromMillisecondsSinceEpoch(ts)
              : null
        );
      }
      // Migrate v1 (bare list) → v2 wrapper.
      if (data is List) {
        final list = data
            .whereType<Map<String, dynamic>>()
            .map(DbBahnCard.fromJson)
            .toList();
        return (cards: list, fetchedAt: null);
      }
      return (cards: const <DbBahnCard>[], fetchedAt: null);
    } catch (_) {
      return (cards: const <DbBahnCard>[], fetchedAt: null);
    }
  }

  static Future<void> save(List<DbBahnCard> cards) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _kKey,
        json.encode({
          'fetchedAtMs': DateTime.now().millisecondsSinceEpoch,
          'cards': cards.map((c) => c.toJson()).toList(),
        }),
      );
    } catch (_) {/* best effort */}
  }

  static Future<void> clear() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kKey);
      // Also drop legacy cache shapes if they linger.
      await prefs.remove('db_bahncards_cache_v1');
      await prefs.remove('db_bahncards_cache_v2');
    } catch (_) {}
  }
}

/// On-disk profile cache — survives cold start + offline so the Profil tab
/// and the Reisen header render real data the moment the app opens. Wiped
/// on logout (privacy: don't leak previous holder's name/address).
class _ProfileCache {
  static const _kKey = 'db_profile_v1';

  static Future<DbProfile?> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kKey);
      if (raw == null || raw.isEmpty) return null;
      final data = json.decode(raw);
      if (data is Map<String, dynamic>) return DbProfile.fromJson(data);
    } catch (_) {}
    return null;
  }

  static Future<void> save(DbProfile p) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kKey, json.encode(p.toJson()));
    } catch (_) {}
  }

  static Future<void> clear() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kKey);
    } catch (_) {}
  }
}

/// Auth state for the DB account login.
class DbAuthState {
  /// false until storage has been checked (initial splash).
  final bool initialized;
  final DbProfile? profile;
  final bool isLoading;
  final String? error;

  /// When the account data was last pulled from the server successfully.
  /// Surfaced in the Profil tab ("Zuletzt aktualisiert …") so a refresh that
  /// ran but changed nothing is distinguishable from one that never ran (#31),
  /// and used to throttle the automatic resume refresh.
  final DateTime? lastRefreshedAt;

  const DbAuthState({
    this.initialized = false,
    this.profile,
    this.isLoading = false,
    this.error,
    this.lastRefreshedAt,
  });

  bool get isLoggedIn => profile != null;

  DbAuthState copyWith({
    bool? initialized,
    DbProfile? profile,
    bool? isLoading,
    String? error,
    DateTime? lastRefreshedAt,
    bool clearProfile = false,
    bool clearError = false,
  }) {
    return DbAuthState(
      initialized: initialized ?? this.initialized,
      profile: clearProfile ? null : (profile ?? this.profile),
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : (error ?? this.error),
      lastRefreshedAt: lastRefreshedAt ?? this.lastRefreshedAt,
    );
  }
}

/// An automatic (resume-triggered) refresh that lands within this window of the
/// last successful one is skipped. Resume fires often — returning from the
/// login tab, from a share sheet, from the notification shade — and each
/// refresh is a whole set of requests the rate limiter counts (#31). A manual
/// pull is never throttled.
const _kAutoRefreshCooldown = Duration(seconds: 30);

class DbAuthNotifier extends Notifier<DbAuthState> {
  DbAccountService get _service => ref.read(dbAccountServiceProvider);

  @override
  DbAuthState build() {
    _restore();
    return const DbAuthState();
  }

  /// On startup: if a token exists, load the profile to validate the session.
  /// If the cached profile is on disk, surface it immediately so the Profil
  /// tab + Reisen header render real data offline and across cold starts —
  /// the live `profile()` call happens behind it and replaces the state once
  /// the network confirms (or quietly errors).
  Future<void> _restore() async {
    final cached = await _ProfileCache.load();
    if (cached != null) {
      // Optimistic: show last-known profile first, refresh in the background.
      state = state.copyWith(initialized: true, profile: cached);
    }
    try {
      final has = await _service.hasSession();
      AppLog.log('restore start · session=$has', tag: 'db-account');
      if (has) {
        final profile = await _service.profile();
        await _ProfileCache.save(profile);
        state = state.copyWith(
            initialized: true,
            profile: profile,
            lastRefreshedAt: DateTime.now());
        _seedSearchDefaults(profile);
        AppLog.log('restore ok · ${profile.kundennummer}', tag: 'db-account');
        return;
      }
    } on DbAccountException catch (e) {
      // Only a genuine auth failure (401) means the stored session is dead —
      // then drop the tokens. The service has already cleared them on a failed
      // refresh, but be explicit. A transient error (offline, timeout, missing
      // platform keyring) must NOT wipe a valid refresh token, or the user is
      // forced to log in again on every cold start.
      AppLog.log(
          'restore DbAccountException status=${e.status} msg=${e.message}',
          tag: 'db-account');
      if (e.status == 401) await _service.logout();
    } catch (e) {
      // Network/platform hiccup — keep tokens AND the cached profile so the
      // user still sees their data offline; next launch (or manual retry)
      // re-validates the session.
      AppLog.log('restore non-auth error: $e', tag: 'db-account');
      if (cached != null) {
        state = state.copyWith(initialized: true);
        return;
      }
    }
    if (state.profile == null) {
      state = state.copyWith(initialized: true, clearProfile: true);
    } else {
      state = state.copyWith(initialized: true);
    }
  }

  /// Runs the DB browser login.
  Future<void> login() async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final profile = await _service.login();
      await _ProfileCache.save(profile);
      state = state.copyWith(
          isLoading: false, profile: profile, lastRefreshedAt: DateTime.now());
      _invalidateData();
      _seedSearchDefaults(profile);
    } catch (e) {
      state = state.copyWith(
          isLoading: false, error: _message(e), clearProfile: true);
    }
  }

  /// Seed the journey-search defaults (age, BahnCard) from what the DB account
  /// already knows, so the user doesn't have to re-enter it. Best-effort and
  /// runs at most once per login — manual changes after this stick.
  Future<void> _seedSearchDefaults(DbProfile profile) async {
    int? age;
    final geb = profile.geburtsdatum;
    if (geb != null) {
      final dt = DateTime.tryParse(geb);
      if (dt != null) {
        final now = DateTime.now();
        age = now.year - dt.year -
            ((now.month < dt.month ||
                    (now.month == dt.month && now.day < dt.day))
                ? 1
                : 0);
      }
    }
    BahnCardType? card;
    try {
      // Go through the provider's future so the cached result is shared with
      // the Profile / Ticket / search-prefill paths — calling the service
      // directly here was firing a SECOND concurrent GET that DB 429'd, and
      // the user saw "BahnCard nicht ladbar · 429".
      final cards = await ref.read(bahncardsProvider.future);
      if (cards.isNotEmpty) card = _toBahnCardType(cards.first);
    } catch (_) {/* no cards / network — leave settings untouched */}
    ref.read(settingsProvider.notifier).applyFromDbAccount(
          age: age,
          card: card,
        );
    // Pull the DB account's Bahnhof-Favoriten into the local library so
    // they show up in the search Schnellauswahl without re-entering them.
    try {
      // Same shared-cache reasoning as bahncards above.
      final favs = await ref.read(dbStationFavoritesProvider.future);
      if (favs.isNotEmpty) {
        final stations = favs.map(_stationFromFavorite).toList();
        ref.read(libraryProvider.notifier).mergeServerFavorites(stations);
      }
    } catch (_) {/* offline / endpoint changed — local library untouched */}
  }

  Station _stationFromFavorite(DbStationFavorite f) => Station(
        id: f.evaNr ?? '',
        name: f.displayName,
        locationId:
            f.locationId.contains('@') ? f.locationId : null,
        latitude: f.lat,
        longitude: f.lng,
      );

  /// Maps a DB-account BahnCard (BC25/BC50/BC100 × KLASSE_1/2) to the local
  /// [BahnCardType] enum the search uses. BC100 isn't an enum value yet — it
  /// behaves like BC50 for discount-bound searches, so map it there.
  BahnCardType? _toBahnCardType(DbBahnCard c) {
    final t = c.typ.toUpperCase();
    final firstClass = c.firstClass;
    if (t.contains('25')) {
      return firstClass ? BahnCardType.bc25_1 : BahnCardType.bc25_2;
    }
    if (t.contains('50') || t.contains('100')) {
      return firstClass ? BahnCardType.bc50_1 : BahnCardType.bc50_2;
    }
    return null;
  }

  Future<void> logout() async {
    await _service.logout();
    state = const DbAuthState(initialized: true);
    _invalidateData();
    // Privacy: strip any Bahnhof-Favoriten that came from the server-side
    // sync and were never used locally — leftover would otherwise leak the
    // signed-out account's data into the Schnellauswahl.
    ref.read(libraryProvider.notifier).dropServerFavorites();
    // And drop every cache that carries personal data — BahnCards, the Meine-
    // Reisen overview, every individually-cached ticket, and the cached
    // profile — so a signed-out user can't read or open the previous
    // holder's data.
    await _BahnCardCache.clear();
    // The decoded card artwork + the parsed holder name/number that ride with
    // it, and any live WebView still holding the rendered card.
    await BahnCardArtCache.clear();
    BahnCardWebViewCache.clear();
    await _ReisenCache.clear();
    await _DbTicketCache.clearAll();
    await _ProfileCache.clear();
    await _BahnBonusCache.clear();
    // The key→rkUuid map points at the previous holder's saved trips.
    await ref.read(dbSavedReiseIdsProvider.notifier).clear();
  }

  /// Re-pull just the profile — name, e-mail, address. Always fresh: it's a
  /// POST, so no ETag applies. Never throws; a failed refresh belongs in
  /// [DbAuthState.error] where the Profil tab can show it. It used to be
  /// swallowed entirely, so a refresh that got rate-limited looked exactly like
  /// one that found no changes (#31).
  ///
  /// Refreshes the profile and nothing else — use [AccountRefresher.refresh]
  /// (`accountRefreshProvider`) to reload the whole account.
  Future<void> reloadProfile() async {
    if (!state.isLoggedIn) return;
    try {
      final profile = await _service.profile();
      await _ProfileCache.save(profile);
      state = state.copyWith(profile: profile, clearError: true);
    } catch (e) {
      state = state.copyWith(error: _refreshMessage(e));
    }
  }

  /// Stamps "Zuletzt aktualisiert" once a full account refresh has completed.
  void markRefreshed() =>
      state = state.copyWith(lastRefreshedAt: DateTime.now());

  /// Only for an identity change (login / logout) — every cached source has to
  /// be thrown away and rebuilt for the *new* account. Never for a refresh:
  /// invalidating there tears down the controllers mid-refresh, and their
  /// rebuild fires a second background copy of the very requests the refresh
  /// is already making.
  void _invalidateData() {
    ref.invalidate(bahnbonusProvider);
    ref.invalidate(bahncardsProvider);
    ref.invalidate(reisenuebersichtProvider);
    ref.invalidate(dbStationFavoritesProvider);
  }

  String _message(Object e) {
    final s = e.toString();
    if (s.contains('CANCELED') || s.contains('cancel')) {
      return 'Anmeldung abgebrochen';
    }
    return e is DbAccountException ? e.message : 'Anmeldung fehlgeschlagen';
  }

  String _refreshMessage(Object e) => e is DbAccountException
      ? 'Aktualisieren fehlgeschlagen: ${e.message}'
      : 'Aktualisieren fehlgeschlagen';
}

final dbAuthProvider =
    NotifierProvider<DbAuthNotifier, DbAuthState>(DbAuthNotifier.new);

/// Reloads **everything the Profil tab shows** in one coordinated pass:
/// profile (name, e-mail, address), BahnBonus, BahnCards, and the trip
/// overview that backs the ticket list. This is what pull-to-refresh runs (#31).
///
/// It lives above [dbAuthProvider] rather than inside it because the account
/// sources all watch the auth state — a notifier cannot read its own
/// dependents.
///
/// Two rules it exists to keep:
///
/// 1. **Everything, forced.** Each source is fetched without `If-None-Match`,
///    so the server can't answer "unchanged" and leave the user staring at the
///    address they just corrected on bahn.de.
/// 2. **One refresh = one set of requests.** The four fetches run concurrently
///    on purpose: the trip overview needs the profile too, and firing them
///    together lets the service's coalescer collapse both reads into a single
///    POST — sequentially they'd be two. A second pull while one runs joins it,
///    and [AccountRefresher.refresh] with `auto: true` (app resume) is
///    throttled. Duplicate concurrent requests are what make /mob answer 429
///    for minutes, after which every source silently serves its stale disk
///    cache — which is the bug.
class AccountRefresher {
  AccountRefresher(this._ref);

  final Ref _ref;
  Future<void>? _inFlight;

  Future<void> refresh({bool auto = false}) {
    final auth = _ref.read(dbAuthProvider);
    if (!auth.isLoggedIn) return Future.value();
    final running = _inFlight;
    if (running != null) return running;
    if (auto) {
      final last = auth.lastRefreshedAt;
      if (last != null &&
          DateTime.now().difference(last) < _kAutoRefreshCooldown) {
        return Future.value();
      }
    }
    final future = _run();
    _inFlight = future;
    return future.whenComplete(() => _inFlight = null);
  }

  /// Never throws: each source parks its own failure (the profile in
  /// [DbAuthState.error], the rest in their AsyncValue + disk-cache fallback),
  /// so one dead endpoint can't abort the others.
  Future<void> _run() async {
    await Future.wait([
      _ref.read(dbAuthProvider.notifier).reloadProfile(),
      _ref.read(bahnbonusProvider.notifier).refresh(),
      _ref.read(bahncardsProvider.notifier).refresh(),
      _ref.read(reisenuebersichtProvider.notifier).refresh(),
    ]);
    // The profile POST is the canary: if the client is rate-limited or the
    // session is dead, it failed too. Don't claim a refresh that didn't happen.
    if (_ref.read(dbAuthProvider).error == null) {
      _ref.read(dbAuthProvider.notifier).markRefreshed();
    }
  }
}

final accountRefreshProvider =
    Provider<AccountRefresher>((ref) => AccountRefresher(ref));

/// On-disk BahnBonus cache. Points don't change while you're standing on a
/// platform, so the last good value stays true enough to show — and showing
/// it beats blanking the card because a resume-triggered refresh is in
/// flight or got rate-limited. Wiped on logout with the other personal data.
class _BahnBonusCache {
  static const _kKey = 'db_bahnbonus_v1';

  static Future<DbBahnBonus?> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kKey);
      if (raw == null || raw.isEmpty) return null;
      final data = json.decode(raw);
      if (data is Map<String, dynamic>) return DbBahnBonus.fromJson(data);
    } catch (_) {}
    return null;
  }

  static Future<void> save(DbBahnBonus b) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kKey, json.encode(b.toJson()));
    } catch (_) {/* best effort */}
  }

  static Future<void> clear() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kKey);
    } catch (_) {}
  }
}

/// BahnBonus status — only fetched while logged in, stale-while-revalidate
/// like [bahncardsProvider]. The cache is what keeps the card on screen
/// across an app resume: the plain FutureProvider this replaced went to
/// AsyncLoading on every invalidate and to AsyncError on any hiccup, and the
/// UI rendered both as nothing, so the card silently vanished (#12).
class BahnbonusController extends AsyncNotifier<DbBahnBonus?> {
  @override
  Future<DbBahnBonus?> build() async {
    // Watch *whether* an account is signed in, not the profile object. Watching
    // the whole state meant every profile reload rebuilt this controller, and
    // the rebuild fired a background fetch racing the refresh that caused it —
    // two concurrent GETs of the same URL, which is how /mob gets talked into a
    // 429 (#31).
    final loggedIn = ref.watch(dbAuthProvider.select((s) => s.isLoggedIn));
    if (!loggedIn) return null;
    final cached = await _BahnBonusCache.load();
    if (cached != null) {
      _refreshInBackground();
      return cached;
    }
    return _fetchAndPersist();
  }

  /// Foreground refresh (pull-to-refresh) — forced, so an unchanged-looking
  /// ETag can't answer 304 and hand back the very cache we're replacing. Falls
  /// back to the cache rather than erroring out, so a transient failure can't
  /// empty the card.
  Future<void> refresh() async {
    try {
      final fresh = await _fetchAndPersist(forceFresh: true);
      if (fresh != null) state = AsyncData(fresh);
    } catch (e, st) {
      final cached = await _BahnBonusCache.load();
      state = cached != null ? AsyncData(cached) : AsyncError(e, st);
    }
  }

  Future<DbBahnBonus?> _fetchAndPersist({bool forceFresh = false}) async {
    final fresh = await ref
        .read(dbAccountServiceProvider)
        .bahnbonus(forceFresh: forceFresh);
    // null = no BahnBonus programme (404) or "unchanged" (304). Don't overwrite
    // a good cache with that; it's also what a rate-limited or half-broken
    // response looks like.
    if (fresh == null) return _BahnBonusCache.load();
    await _BahnBonusCache.save(fresh);
    return fresh;
  }

  /// Background revalidation stays conditional (ETag) — cheap 304s are exactly
  /// what DB Navigator does, and nobody is waiting on the answer.
  void _refreshInBackground() {
    Future.microtask(() async {
      try {
        final fresh = await _fetchAndPersist();
        if (fresh != null) state = AsyncData(fresh);
      } catch (e) {
        AppLog.log('bahnbonus background refresh failed: $e', tag: 'db-account');
      }
    });
  }
}

final bahnbonusProvider =
    AsyncNotifierProvider<BahnbonusController, DbBahnBonus?>(
        BahnbonusController.new);

/// The user's BahnCards — stale-while-revalidate. On startup the on-disk
/// cache returns instantly so the BahnCard / Kontrollansicht works offline;
/// a background refresh updates the cache if the network is reachable. The
/// "Aktualisieren" button calls [BahncardsController.refresh] for an
/// explicit foreground re-fetch (rate-limited by the service layer).
class BahncardsController extends AsyncNotifier<List<DbBahnCard>> {
  @override
  Future<List<DbBahnCard>> build() async {
    // Login state only — see BahnbonusController.build (#31).
    final loggedIn = ref.watch(dbAuthProvider.select((s) => s.isLoggedIn));
    if (!loggedIn) {
      // Don't surface a signed-out account's cache.
      return const [];
    }
    final entry = await _BahnCardCache.load();
    if (entry.cards.isNotEmpty) {
      // The BahnCard's Kontrollansicht carries its own server-side expiry
      // (kontrollSichtGueltigBis). Until then the cached HTML is valid for
      // an inspection — no point re-fetching. Only refresh when any card's
      // Kontrollsicht has actually expired (or the date is missing, which
      // means we don't know and should err on the side of fresh data).
      if (entry.cards.any(_kontrollSichtExpired)) {
        // Background revalidation = `auto` trigger (Navigator's wording).
        _refreshInBackground(trigger: 'auto');
      }
      return entry.cards;
    }
    // No cache yet — cold-start fetch, mirrors Navigator's `login` trigger.
    return _fetchAndPersist(trigger: 'login');
  }

  static bool _kontrollSichtExpired(DbBahnCard c) {
    final raw = c.kontrollSichtGueltigBis;
    if (raw == null || raw.isEmpty) return true;
    final until = DateTime.tryParse(raw);
    if (until == null) return true;
    return DateTime.now().isAfter(until);
  }

  /// Foreground refresh — the Profile "Aktualisieren" button and pull-to-
  /// refresh. Sends `call-trigger: manual` so the request looks like a
  /// user-initiated pull in DB Navigator's telemetry, not a background poll,
  /// and skips the conditional header so it comes back with real data instead
  /// of a 304 (#31).
  Future<void> refresh() async {
    // Deliberately no AsyncLoading: the pull's own spinner is the progress
    // indicator, and dropping to loading would blank the whole BahnCard
    // section for the length of the request. The state moves straight from the
    // old cards to the new ones.
    try {
      final fresh = await _fetchAndPersist(trigger: 'manual', forceFresh: true);
      state = AsyncData(fresh);
    } catch (e, st) {
      // Keep showing the cache on failure so the rider isn't stranded.
      final entry = await _BahnCardCache.load();
      if (entry.cards.isNotEmpty) {
        state = AsyncData(entry.cards);
      } else {
        state = AsyncError(e, st);
      }
    }
  }

  Future<List<DbBahnCard>> _fetchAndPersist(
      {required String trigger, bool forceFresh = false}) async {
    final fresh = await ref
        .read(dbAccountServiceProvider)
        .bahncards(trigger: trigger, forceFresh: forceFresh);
    // 304 Not Modified → server confirms our cache is still authoritative;
    // re-save isn't needed, just hand the cached entry back.
    if (fresh == null) {
      final entry = await _BahnCardCache.load();
      return _warmed(entry.cards);
    }
    await _BahnCardCache.save(fresh);
    return _warmed(fresh);
  }

  /// Decode each card's artwork into Flutter's image cache in the background,
  /// so the Profil tab paints a resident texture on its first frame instead of
  /// one blank beat while the PNG decodes. Fire-and-forget: nobody waits on the
  /// artwork to have the card *data*, and a failed decode is a slower card, not
  /// a missing one.
  List<DbBahnCard> _warmed(List<DbBahnCard> cards) {
    if (cards.isNotEmpty) unawaited(BahnCardArtCache.warm(cards));
    return cards;
  }

  /// Background revalidation stays conditional — see BahnbonusController.
  void _refreshInBackground({required String trigger}) {
    Future.microtask(() async {
      try {
        final fresh = await _fetchAndPersist(trigger: trigger);
        state = AsyncData(fresh);
      } catch (e) {
        AppLog.log('bahncards background refresh failed: $e',
            tag: 'db-account');
      }
    });
  }
}

final bahncardsProvider =
    AsyncNotifierProvider<BahncardsController, List<DbBahnCard>>(
        BahncardsController.new);

/// On-disk cache for the full Meine-Reisen overview. Restores the Reisen tab
/// instantly across cold starts + completely offline; a background refresh
/// replaces it once the network is back.
class _ReisenCache {
  static const _kKey = 'db_reisenuebersicht_v1';

  static Future<DbReisenUebersicht?> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kKey);
      if (raw == null || raw.isEmpty) return null;
      final data = json.decode(raw);
      if (data is Map<String, dynamic>) {
        return DbAccountService.parseReisenuebersicht(data);
      }
    } catch (_) {/* fall through */}
    return null;
  }

  static Future<void> save(Map<String, dynamic> data) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kKey, json.encode(data));
    } catch (_) {/* best effort */}
  }

  static Future<void> clear() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kKey);
    } catch (_) {}
  }
}

/// Full "Meine Reisen" overview — stale-while-revalidate. Cold start returns
/// the on-disk cache instantly so the Reisen tab renders the real tile design
/// from the first frame (no placeholder flicker) and works offline; a
/// background refresh updates it when the network is reachable. Pull-to-
/// refresh calls [ReisenUebersichtController.refresh] for an explicit
/// foreground re-fetch.
class ReisenUebersichtController extends AsyncNotifier<DbReisenUebersicht> {
  @override
  Future<DbReisenUebersicht> build() async {
    // Login state only — see BahnbonusController.build (#31).
    final loggedIn = ref.watch(dbAuthProvider.select((s) => s.isLoggedIn));
    if (!loggedIn) return const DbReisenUebersicht();
    final cached = await _ReisenCache.load();
    if (cached != null) {
      _refreshInBackground();
      return cached;
    }
    return _fetchAndPersist();
  }

  /// Foreground refresh — pull-to-refresh, and after we changed the account's
  /// trips ourselves. Forced: a conditional GET could answer 304 and hide the
  /// booking (or the "Reise merken") that prompted the refresh (#31).
  Future<void> refresh() async {
    // No AsyncLoading — see BahncardsController.refresh. It also mattered here:
    // the Reisen tab reads this through `asData`, which nulls out on loading,
    // so every pull briefly emptied the trip list.
    try {
      state = AsyncData(await _fetchAndPersist(forceFresh: true));
    } catch (e, st) {
      final cached = await _ReisenCache.load();
      if (cached != null) {
        state = AsyncData(cached);
      } else {
        state = AsyncError(e, st);
      }
    }
  }

  Future<DbReisenUebersicht> _fetchAndPersist({bool forceFresh = false}) async {
    final data = await ref
        .read(dbAccountServiceProvider)
        .reisenuebersichtJson(onlyCurrent: false, forceFresh: forceFresh);
    if (data == null) {
      // 304 — disk cache is still authoritative.
      return (await _ReisenCache.load()) ?? const DbReisenUebersicht();
    }
    await _ReisenCache.save(data);
    return DbAccountService.parseReisenuebersicht(data);
  }

  /// Background revalidation stays conditional — see BahnbonusController.
  void _refreshInBackground() {
    Future.microtask(() async {
      try {
        state = AsyncData(await _fetchAndPersist());
      } catch (e) {
        AppLog.log('reisenuebersicht bg refresh failed: $e',
            tag: 'db-account');
      }
    });
  }
}

final reisenuebersichtProvider = AsyncNotifierProvider<
    ReisenUebersichtController, DbReisenUebersicht>(
  ReisenUebersichtController.new,
);

/// Bought tickets only (auftragsIndizes), newest first.
final ticketIndicesProvider = FutureProvider<List<DbReiseIndex>>((ref) async {
  final uebersicht = await ref.watch(reisenuebersichtProvider.future);
  return uebersicht.orders;
});

/// A bought ticket with its trip resolved — the order index alone carries no
/// travel date (only `aenderungsDatum`, when the booking last changed), so
/// "is this trip over?" can only be answered once the ticket detail is in.
class DbTicketTrip {
  final DbReiseIndex index;

  /// `auftragsnummer/kundenwunschId` — the [ticketProvider] family key.
  final String ticketKey;
  final DbTicket? ticket;
  final Journey? journey;

  const DbTicketTrip({
    required this.index,
    required this.ticketKey,
    this.ticket,
    this.journey,
  });

  /// When the trip is over. The connection's arrival is the truth; `gueltigBis`
  /// is only a fallback for a ticket whose Verbindung won't parse — and a loose
  /// one (a Flexpreis stays valid all day).
  DateTime? get endTime =>
      journey?.arrival ?? journey?.plannedArrival ?? ticket?.gueltigBis;

  /// Past only when we actually know it is. A ticket we couldn't resolve stays
  /// upcoming: showing a live trip too low is worse than showing a stale one
  /// too high.
  bool get isPast {
    final end = endTime;
    return end != null && end.isBefore(DateTime.now());
  }

  /// The identity a local bookmark of this very trip would have, so the twin
  /// can be dropped instead of listed a second time (#23).
  String? get journeyKey => journey == null
      ? null
      : SavedJourney(journey: journey!, savedAtMs: 0).key;
}

/// Bought tickets WITH their trip resolved, upcoming first, then past — the
/// Reisen tab needs the date to file them, and the index doesn't have one.
///
/// Every ticket detail is disk-cached by [ticketProvider], so this is usually
/// instant after the first load. A ticket that fails to load or parse still
/// yields an entry (journey null) rather than dropping out of the list.
final ticketTripsProvider = FutureProvider<List<DbTicketTrip>>((ref) async {
  final indices = await ref.watch(ticketIndicesProvider.future);
  final vendo = ref.read(vendoServiceProvider);

  Future<DbTicketTrip?> resolve(DbReiseIndex i) async {
    final kwId = i.kundenwunschIds.isNotEmpty ? i.kundenwunschIds.first : '';
    if (kwId.isEmpty) return null;
    final key = '${i.auftragsnummer}/$kwId';
    final DbTicket t;
    try {
      t = await ref.watch(ticketProvider(key).future);
    } catch (e) {
      AppLog.log('ticket $key failed to load: $e', tag: 'db-account');
      return DbTicketTrip(index: i, ticketKey: key);
    }
    Journey? j;
    if (t.verbindungJson != null) {
      try {
        final parsed = vendo.parseConnection(t.verbindungJson!);
        if (parsed.legs.isNotEmpty) j = parsed;
      } catch (_) {/* keep the ticket, just without a trip */}
    }
    return DbTicketTrip(index: i, ticketKey: key, ticket: t, journey: j);
  }

  final trips = (await Future.wait(indices.map(resolve)))
      .whereType<DbTicketTrip>()
      .toList();
  // Upcoming first (soonest departure), then past (most recent first) — same
  // order the local saved trips use.
  int? depMs(DbTicketTrip t) =>
      (t.journey?.plannedDeparture ?? t.journey?.departure ?? t.ticket?.gueltigAb)
          ?.millisecondsSinceEpoch;
  final upcoming = trips.where((t) => !t.isPast).toList()
    ..sort((a, b) => (depMs(a) ?? 0).compareTo(depMs(b) ?? 0));
  final past = trips.where((t) => t.isPast).toList()
    ..sort((a, b) => (b.endTime ?? DateTime(0)).compareTo(a.endTime ?? DateTime(0)));
  return [...upcoming, ...past];
});

/// Tracked-but-unpaid trips (reiseIndizes, "Reise merken"), newest start first.
final savedReisenProvider =
    FutureProvider<List<DbSavedReiseIndex>>((ref) async {
  final uebersicht = await ref.watch(reisenuebersichtProvider.future);
  return uebersicht.saved;
});

/// The Journey parsed from one saved DB Reise (`/mob/reisen/{rkUuid}`), cached
/// per rkUuid. Feeds the Reisen tile's JourneyCard.
final savedReiseJourneyProvider =
    FutureProvider.family<Journey?, String>((ref, rkUuid) async {
  final wrap = await ref
      .read(dbAccountServiceProvider)
      .savedReiseVerbindung(rkUuid);
  if (wrap == null) return null;
  try {
    final journey = ref.read(vendoServiceProvider).parseConnection(wrap);
    // Reconcile: the trip overview lists rkUuid + startDatum but no stations,
    // so it alone can't be matched to a local journey key. This per-trip fetch
    // (which the Reisen tab already makes to render the tile) carries the full
    // Journey, so the key is derivable here — teaching the map about DB trips
    // this session didn't create: saved on another device, saved before the
    // map was persisted, or orphaned by an earlier local-only delete (#15).
    final key = SavedJourney(journey: journey, savedAtMs: 0).key;
    ref.read(dbSavedReiseIdsProvider.notifier).register(key, rkUuid);
    return journey;
  } catch (_) {
    return null;
  }
});

/// Server-side Bahnhof favorites — read-only sync on login.
final dbStationFavoritesProvider =
    FutureProvider<List<DbStationFavorite>>((ref) async {
  // Login state only — see BahnbonusController.build (#31). This one also
  // fetches the profile internally, so a whole-state watch re-fetched it on
  // every profile reload.
  final loggedIn = ref.watch(dbAuthProvider.select((s) => s.isLoggedIn));
  if (!loggedIn) return const [];
  return ref.read(dbAccountServiceProvider).stationFavorites();
});

/// On-disk per-ticket cache (raw `auftrag` JSON, byte-identical to the API
/// response, keyed by `auftragsnummer/kundenwunschId`). Lets a bought ticket
/// — barcode, route, embedded Handyticket HTML, Sitzplatzreservierungen —
/// open instantly and offline.
class _DbTicketCache {
  static String _k(String key) => 'db_ticket_raw_v1:$key';

  static Future<Map<String, dynamic>?> load(String key) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_k(key));
      if (raw == null || raw.isEmpty) return null;
      final data = json.decode(raw);
      if (data is Map<String, dynamic>) return data;
    } catch (_) {}
    return null;
  }

  static Future<void> save(String key, Map<String, dynamic> data) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_k(key), json.encode(data));
    } catch (_) {}
  }

  static Future<void> clearAll() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final hits =
          prefs.getKeys().where((k) => k.startsWith('db_ticket_raw_v1:'));
      for (final k in hits) {
        await prefs.remove(k);
      }
    } catch (_) {}
  }
}

/// Whether the raw payload for [ticketKey] (`auftragsnummer/kundenwunschId`) is
/// already on disk — barcode included, since the PNG rides along inside the
/// cached ticket HTML.
///
/// Exposed for the offline package (#29), which reports the ticket rather than
/// re-downloading it: tickets are cached by this layer the first time they're
/// opened, and a package should say so instead of duplicating them.
Future<bool> isTicketCachedOffline(String ticketKey) async =>
    await _DbTicketCache.load(ticketKey) != null;

/// A single booked ticket — stale-while-revalidate per
/// `auftragsnummer/kundenwunschId`. Cold start returns the cached parse
/// instantly so the Reisen tile renders as a real JourneyCard from the first
/// frame; a background fetch refreshes it when the network is reachable
/// (via `ref.invalidate(ticketProvider(key))` on tap / refresh).
///
/// Implemented as a FutureProvider.family because Riverpod 3 doesn't ship
/// `FamilyAsyncNotifier` — the cache-first logic is just the provider body.
final ticketProvider =
    FutureProvider.family<DbTicket, String>((ref, key) async {
  final cached = await _DbTicketCache.load(key);
  if (cached != null) {
    // Best-effort background revalidation so future opens reflect any
    // server-side change. Fire-and-forget; failure stays silent (we still
    // have the cache).
    Future.microtask(() async {
      try {
        final parts = key.split('/');
        final fresh = await ref
            .read(dbAccountServiceProvider)
            .ticketJson(parts[0], parts[1]);
        if (fresh != null) {
          await _DbTicketCache.save(key, fresh);
          ref.invalidateSelf();
        }
      } catch (e) {
        AppLog.log('ticket($key) bg refresh failed: $e', tag: 'db-account');
      }
    });
    return DbTicket.fromJson(cached);
  }
  final parts = key.split('/');
  final fresh = await ref
      .read(dbAccountServiceProvider)
      .ticketJson(parts[0], parts[1]);
  if (fresh == null) {
    final retry = await _DbTicketCache.load(key);
    if (retry != null) return DbTicket.fromJson(retry);
    throw const DbAccountException('Ticket nicht im Cache, 304 vom Server');
  }
  await _DbTicketCache.save(key, fresh);
  return DbTicket.fromJson(fresh);
});

/// Maps a locally-saved journey key → the `rkUuid` of the matching DB "Meine
/// Reisen" trip created when the user bookmarked it while logged in, so the
/// same bookmark can remove it from the DB account again. In-memory for the
/// session (cross-session removal reconciles via the trip overview).
class DbSavedReiseIds extends Notifier<Map<String, String>> {
  static const _kKey = 'db_saved_reise_ids_v1';

  /// Completes once the on-disk map has been merged into [state]. Every write
  /// waits on it: a put/register landing first would otherwise persist a map
  /// containing only that one entry, and _restore's read — arriving later —
  /// would find the file already overwritten, dropping every stored mapping.
  late final Future<void> _restored;

  @override
  Map<String, String> build() {
    _restored = _restore();
    return {};
  }

  /// The map used to live only in RAM, so after a restart un-bookmarking
  /// couldn't find the rkUuid and silently skipped deleting the DB Reise —
  /// leaving it stranded in "Meine Reisen" forever (#15). Persisting it is
  /// half the fix; [register] reconciles the other half (entries created on
  /// another device, or before this existed).
  Future<void> _restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kKey);
      if (raw == null || raw.isEmpty) return;
      final data = json.decode(raw);
      if (data is Map) {
        final restored = data.map((k, v) => MapEntry('$k', '$v'));
        // Don't clobber anything registered while the read was in flight.
        state = {...restored, ...state};
      }
    } catch (_) {/* best effort */}
  }

  Future<void> _persist() async {
    try {
      await _restored;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kKey, json.encode(state));
    } catch (_) {/* best effort */}
  }

  void put(String key, String rkUuid) {
    state = {...state, key: rkUuid};
    _persist();
  }

  /// Learn a key→rkUuid pair discovered by reading the DB's own saved trips.
  /// Unlike [put] this is idempotent and never overwrites a known mapping, so
  /// it's safe to call on every render of a saved-trip tile.
  void register(String key, String rkUuid) {
    if (state[key] == rkUuid) return;
    state = {...state, key: rkUuid};
    _persist();
  }

  String? lookup(String key) => state[key];

  /// Removes and returns the stored id for [key] (null if none).
  String? take(String key) {
    final id = state[key];
    if (id != null) {
      state = {...state}..remove(key);
      _persist();
    }
    return id;
  }

  Future<void> clear() async {
    // Wait out an in-flight restore first, or it would merge the signed-out
    // account's mappings back in right after we emptied them.
    try {
      await _restored;
    } catch (_) {}
    state = {};
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kKey);
    } catch (_) {}
  }
}

final dbSavedReiseIdsProvider =
    NotifierProvider<DbSavedReiseIds, Map<String, String>>(
        DbSavedReiseIds.new);
