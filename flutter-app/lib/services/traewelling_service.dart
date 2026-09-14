import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import '../core/constants.dart';
import '../core/user_agent_client.dart';
import '../models/traewelling_models.dart';
import 'oauth_browser.dart';

/// Raised when an API call fails. [status] carries the HTTP code so callers can
/// special-case 401 (re-login) and 409 (check-in collision).
class TraewellingException implements Exception {
  final String message;
  final int? status;
  const TraewellingException(this.message, [this.status]);
  @override
  String toString() => 'TraewellingException($status): $message';
}

/// Thrown on a check-in collision (HTTP 409) — the user is already checked in
/// to an overlapping trip. Pass `force: true` to override.
class CheckinCollisionException extends TraewellingException {
  const CheckinCollisionException(String message) : super(message, 409);
}

/// Träwelling client: OAuth2 (Authorization Code + PKCE, public client — no
/// secret) plus the REST endpoints the app uses. Tokens live in the platform
/// secure store; a 401 triggers a single transparent refresh + retry.
///
/// Every request leaves through a [UserAgentClient]: Träwelling gates its whole
/// surface — OAuth token exchange, refresh and the REST API alike — on an
/// identifiable `User-Agent` and answers 403 without one (#34).
class TraewellingService {
  TraewellingService({FlutterSecureStorage? storage, http.Client? client})
    : _storage =
          storage ??
          const FlutterSecureStorage(
            // iOS: allow reads after first unlock since boot. Android 10.x
            // uses its own ciphers by default; no extra options needed.
            iOptions: IOSOptions(
              accessibility: KeychainAccessibility.first_unlock,
            ),
          ),
      _client = UserAgentClient(client ?? http.Client(), _userAgent);

  /// Identifies this app to Träwelling. Kept as a named constant so the tests
  /// assert the very string the service ships.
  static const _userAgent = AppConstants.userAgent;

  final FlutterSecureStorage _storage;
  final http.Client _client;

  static const _kAccess = 'trwl_access_token';
  static const _kRefresh = 'trwl_refresh_token';
  static const _kExpiry = 'trwl_expires_at'; // ISO-8601
  static const _kUser = 'trwl_user'; // cached profile JSON
  static const _kScopes = 'trwl_scopes'; // space-separated granted scopes

  /// Hard cap per request. Without this a stalled socket spins the loading
  /// spinner forever (the feed / "letzte Fahrten" bug) — with it a hung call
  /// surfaces as a clean error + retry instead of an endless wait.
  static const _kTimeout = Duration(seconds: 12);

  String? _accessToken;
  DateTime? _expiresAt;

  /// Fired whenever the stored session is thrown away from inside the service
  /// (a rejected refresh, or a grant without scopes — #101). The auth notifier
  /// hooks this so the Träwelling card flips back to "verbinden" right away
  /// instead of looking connected until the next app start.
  void Function()? onSessionCleared;

  // --- Session state --------------------------------------------------------
  //
  // All secure-storage access is wrapped: on platforms without a registered
  // implementation (e.g. Linux desktop without libsecret) the plugin throws
  // MissingPluginException. We must never let that crash the app — the token
  // simply isn't persisted there and the integration behaves as logged-out.

  Future<String?> _read(String key) async {
    try {
      return await _storage.read(key: key);
    } catch (_) {
      return null;
    }
  }

  Future<void> _write(String key, String value) async {
    try {
      await _storage.write(key: key, value: value);
    } catch (_) {
      /* not persisted on this platform */
    }
  }

  Future<void> _delete(String key) async {
    try {
      await _storage.delete(key: key);
    } catch (_) {
      /* nothing to clear / unsupported */
    }
  }

  /// Whether a token exists (in memory or storage). Does not validate it.
  Future<bool> hasSession() async {
    _accessToken ??= await _read(_kAccess);
    return _accessToken != null;
  }

  /// The scopes the server granted the stored session, or null when we never
  /// recorded any — which is every session created before #101, since those
  /// asked for `*`.
  Future<List<String>?> grantedScopes() async {
    final raw = await _read(_kScopes);
    if (raw == null || raw.trim().isEmpty) return null;
    return raw.split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList();
  }

  /// False only when we *know* the session is powerless: the server told us
  /// which scopes it granted and one the app needs is missing. An unrecorded
  /// grant (pre-#101 session) stays true — a `*` token issued before
  /// Träwelling's Passport 13 upgrade still works, and the first 403 cleans up
  /// the ones that don't.
  Future<bool> hasRequiredScopes() async {
    final granted = await grantedScopes();
    if (granted == null) return true;
    if (granted.contains('*')) return true;
    return TraewellingConstants.scopeList.every(granted.contains);
  }

  Future<void> _loadTokens() async {
    _accessToken = await _read(_kAccess);
    final exp = await _read(_kExpiry);
    _expiresAt = exp != null ? DateTime.tryParse(exp) : null;
  }

  Future<void> _storeTokens(Map<String, dynamic> token) async {
    final access = token['access_token'] as String?;
    final refresh = token['refresh_token'] as String?;
    final expiresIn = (token['expires_in'] as num?)?.toInt();
    // What the server actually granted — not what we asked for. Passport
    // silently drops anything it doesn't recognise (that is how the `*` token
    // of #101 ended up with an empty scope list), so we keep the server's own
    // answer to tell a healthy session from a powerless one.
    final granted = (token['scope'] as String?)?.trim();
    if (access == null) {
      throw const TraewellingException('Token-Antwort ohne access_token');
    }
    _accessToken = access;
    _expiresAt = expiresIn != null
        ? DateTime.now().add(Duration(seconds: expiresIn))
        : null;
    await _write(_kAccess, access);
    if (refresh != null) await _write(_kRefresh, refresh);
    if (granted != null && granted.isNotEmpty) await _write(_kScopes, granted);
    if (_expiresAt != null) {
      await _write(_kExpiry, _expiresAt!.toIso8601String());
    }
  }

  Future<void> _clearTokens() async {
    _accessToken = null;
    _expiresAt = null;
    onSessionCleared?.call();
    await _delete(_kAccess);
    await _delete(_kRefresh);
    await _delete(_kExpiry);
    await _delete(_kUser);
    await _delete(_kScopes);
  }

  /// Last profile we successfully fetched, if any. Lets a valid session show
  /// the user immediately on startup — even when `/auth/user` is momentarily
  /// unreachable — instead of appearing logged out (#39).
  Future<TrwlUser?> cachedUser() async {
    final raw = await _read(_kUser);
    if (raw == null) return null;
    try {
      return TrwlUser.fromJson(json.decode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<void> _cacheUser(TrwlUser user) async =>
      _write(_kUser, json.encode(user.toJson()));

  // --- OAuth (PKCE) ---------------------------------------------------------

  /// Runs the full browser login. Returns the authenticated user on success.
  Future<TrwlUser> login() async {
    final verifier = _randomString(64);
    final challenge = _codeChallenge(verifier);
    final state = _randomString(32);

    final authUrl = Uri.parse(TraewellingConstants.authorizeUrl).replace(
      queryParameters: {
        'client_id': TraewellingConstants.clientId,
        'redirect_uri': TraewellingConstants.redirectUrl,
        'response_type': 'code',
        'scope': TraewellingConstants.scopes,
        'state': state,
        'code_challenge': challenge,
        'code_challenge_method': 'S256',
      },
    );

    final result = await OAuthBrowser.authenticate(
      url: authUrl.toString(),
      callbackUrlScheme: TraewellingConstants.callbackScheme,
      title: 'Träwelling',
    );

    final returned = Uri.parse(result);
    final code = returned.queryParameters['code'];
    final returnedState = returned.queryParameters['state'];
    if (code == null) {
      final err =
          returned.queryParameters['error_description'] ??
          returned.queryParameters['error'] ??
          'Kein Autorisierungscode erhalten';
      throw TraewellingException(err);
    }
    if (returnedState != state) {
      throw const TraewellingException('State stimmt nicht überein (Abbruch)');
    }

    final token = await _exchangeCode(code, verifier);
    await _storeTokens(token);
    final user = await currentUser();
    if (user == null) {
      throw const TraewellingException('Profil konnte nicht geladen werden');
    }
    return user;
  }

  Future<Map<String, dynamic>> _exchangeCode(
    String code,
    String verifier,
  ) async {
    final res = await _client
        .post(
          Uri.parse(TraewellingConstants.tokenUrl),
          headers: {'Accept': 'application/json'},
          body: {
            'grant_type': 'authorization_code',
            'client_id': TraewellingConstants.clientId,
            'redirect_uri': TraewellingConstants.redirectUrl,
            'code_verifier': verifier,
            'code': code,
          },
        )
        .timeout(_kTimeout);
    if (res.statusCode != 200) {
      throw TraewellingException(
        'Token-Tausch fehlgeschlagen: ${res.body}',
        res.statusCode,
      );
    }
    return json.decode(res.body) as Map<String, dynamic>;
  }

  /// Refreshes the access token.
  ///
  /// The distinction matters: only a server that *rejects* the refresh token
  /// (400/401 — revoked, expired, reused) means the session is gone. A
  /// timeout, a socket error or a 5xx says nothing about the session, and
  /// throwing the tokens away for one of those is how a rider ends up signed
  /// out of Träwelling after a tunnel (#39).
  Future<_TrwlRefresh> _refresh() async {
    final refresh = await _read(_kRefresh);
    if (refresh == null) return _TrwlRefresh.rejected;
    final http.Response res;
    try {
      res = await _client
          .post(
            Uri.parse(TraewellingConstants.tokenUrl),
            headers: {'Accept': 'application/json'},
            body: {
              'grant_type': 'refresh_token',
              'refresh_token': refresh,
              'client_id': TraewellingConstants.clientId,
              // No `scope` here on purpose: a refresh can only ever narrow the
              // grant, never widen it. Sending the full list would make the
              // server reject the refresh of an older, narrower token.
            },
          )
          .timeout(_kTimeout);
    } catch (_) {
      // Timeout, DNS, socket, TLS — the network, not the session.
      return _TrwlRefresh.transient;
    }
    if (res.statusCode == 400 || res.statusCode == 401) {
      return _TrwlRefresh.rejected;
    }
    if (res.statusCode != 200) return _TrwlRefresh.transient;
    try {
      await _storeTokens(json.decode(res.body) as Map<String, dynamic>);
    } catch (_) {
      return _TrwlRefresh.transient;
    }
    return _TrwlRefresh.ok;
  }

  Future<void> logout() async {
    try {
      await _send('POST', '/auth/logout');
    } catch (_) {
      // Best effort — clear local tokens regardless.
    }
    await _clearTokens();
  }

  // --- HTTP core ------------------------------------------------------------

  Future<http.Response> _send(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
    bool retryOn401 = true,
  }) async {
    if (_accessToken == null) await _loadTokens();
    if (_accessToken == null) {
      throw const TraewellingException('Nicht angemeldet', 401);
    }

    final uri = Uri.parse(
      '${TraewellingConstants.apiBaseUrl}$path',
    ).replace(queryParameters: query);
    final headers = {
      'Authorization': 'Bearer $_accessToken',
      'Accept': 'application/json',
      if (body != null) 'Content-Type': 'application/json',
    };
    final encoded = body != null ? json.encode(body) : null;

    http.Response res;
    try {
      switch (method) {
        case 'GET':
          res = await _client.get(uri, headers: headers).timeout(_kTimeout);
        case 'POST':
          res = await _client
              .post(uri, headers: headers, body: encoded)
              .timeout(_kTimeout);
        case 'PUT':
          res = await _client
              .put(uri, headers: headers, body: encoded)
              .timeout(_kTimeout);
        case 'DELETE':
          res = await _client
              .delete(uri, headers: headers, body: encoded)
              .timeout(_kTimeout);
        default:
          throw TraewellingException('Unbekannte Methode $method');
      }
    } on TimeoutException {
      throw const TraewellingException(
        'Zeitüberschreitung – Träwelling antwortet nicht. Erneut versuchen.',
      );
    }

    if (res.statusCode == 401 && retryOn401) {
      switch (await _refresh()) {
        case _TrwlRefresh.ok:
          return _send(
            method,
            path,
            query: query,
            body: body,
            retryOn401: false,
          );
        case _TrwlRefresh.transient:
          // Keep the session: we don't know it's dead, only that we couldn't
          // ask right now (#39).
          throw const TraewellingException(
            'Träwelling ist gerade nicht erreichbar. Erneut versuchen.',
          );
        case _TrwlRefresh.rejected:
          await _clearTokens();
          throw const TraewellingException('Sitzung abgelaufen', 401);
      }
    }
    if (res.statusCode == 403 && _isMissingScope(res)) {
      // The token authenticates but carries no (or not enough) permission —
      // every older session asked for `scope=*`, which Passport 13 strips, so
      // the grant is empty and cannot be repaired by refreshing it (#101).
      // Drop it: the Träwelling card falls back to "verbinden" and the next
      // login asks for the explicit scopes.
      await _clearTokens();
      throw const TraewellingException(
        'Träwelling hat der App keine Berechtigungen erteilt. '
        'Bitte in den Einstellungen neu mit Träwelling verbinden.',
        403,
      );
    }
    return res;
  }

  /// Whether a 403 is Passport's `MissingScopeException` ("Invalid scope(s)
  /// provided.") rather than one of Träwelling's other 403s (a blocked user, a
  /// missing User-Agent — #34).
  static bool _isMissingScope(http.Response res) {
    final body = res.body.toLowerCase();
    return body.contains('invalid scope');
  }

  /// Decodes a `{data: ...}`-wrapped response, throwing on non-2xx.
  dynamic _data(http.Response res) {
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw TraewellingException(_errorMessage(res), res.statusCode);
    }
    if (res.body.isEmpty) return null;
    final decoded = json.decode(res.body);
    return decoded is Map<String, dynamic> && decoded.containsKey('data')
        ? decoded['data']
        : decoded;
  }

  String _errorMessage(http.Response res) {
    try {
      final j = json.decode(res.body);
      if (j is Map && j['message'] is String) return j['message'] as String;
    } catch (_) {}
    return 'Fehler ${res.statusCode}';
  }

  // --- User / profile -------------------------------------------------------

  Future<TrwlUser?> currentUser() async {
    final res = await _send('GET', '/auth/user');
    final data = _data(res);
    if (data is! Map<String, dynamic>) return null;
    final user = TrwlUser.fromJson(data);
    await _cacheUser(user);
    return user;
  }

  Future<TrwlUser> userProfile(String username) async {
    final res = await _send('GET', '/user/$username');
    return TrwlUser.fromJson(_data(res) as Map<String, dynamic>);
  }

  Future<List<TrwlStatus>> userStatuses(String username, {int page = 1}) async {
    final res = await _send(
      'GET',
      '/user/$username/statuses',
      query: {'page': '$page'},
    );
    return _statusList(_data(res));
  }

  Future<List<TrwlUser>> searchUsers(String query) async {
    final res = await _send(
      'GET',
      '/user/search/${Uri.encodeComponent(query)}',
    );
    return _userList(_data(res));
  }

  // --- Feed -----------------------------------------------------------------

  Future<List<TrwlStatus>> dashboard({int page = 1}) async {
    final res = await _send('GET', '/dashboard', query: {'page': '$page'});
    return _statusList(_data(res));
  }

  /// The public/global feed — recent check-ins from everyone, so the Feed tab
  /// isn't empty when you follow no one yet.
  ///
  /// `/dashboard/global` is gone (404, "route could not be found"), which is
  /// why the Feed never loaded (#42). The public timeline lives at `/statuses`.
  Future<List<TrwlStatus>> globalDashboard({int page = 1}) async {
    final res = await _send('GET', '/statuses', query: {'page': '$page'});
    return _statusList(_data(res));
  }

  Future<void> like(int statusId) async =>
      _data(await _send('POST', '/status/$statusId/like'));

  Future<void> unlike(int statusId) async =>
      _data(await _send('DELETE', '/status/$statusId/like'));

  // --- Social ---------------------------------------------------------------

  Future<List<TrwlUser>> followers() async =>
      _userList(_data(await _send('GET', '/user/self/followers')));

  Future<List<TrwlUser>> followings() async =>
      _userList(_data(await _send('GET', '/user/self/followings')));

  Future<List<TrwlUser>> followRequests() async =>
      _userList(_data(await _send('GET', '/user/self/follow-requests')));

  Future<void> follow(int userId) async =>
      _data(await _send('POST', '/user/$userId/follow'));

  Future<void> unfollow(int userId) async =>
      _data(await _send('DELETE', '/user/$userId/follow'));

  Future<void> removeFollower(int userId) async =>
      _data(await _send('DELETE', '/user/self/followers/$userId'));

  Future<void> approveFollowRequest(int userId) async =>
      _data(await _send('PUT', '/user/self/follow-requests/$userId'));

  Future<void> rejectFollowRequest(int userId) async =>
      _data(await _send('DELETE', '/user/self/follow-requests/$userId'));

  // --- Check-in flow --------------------------------------------------------

  Future<List<TrwlStation>> searchStations(String query) async {
    final res = await _send(
      'GET',
      '/trains/station/autocomplete/${Uri.encodeComponent(query)}',
    );
    final data = _data(res);
    return (data as List<dynamic>? ?? [])
        .whereType<Map<String, dynamic>>()
        .map(TrwlStation.fromJson)
        .toList();
  }

  Future<List<TrwlDeparture>> departures(
    int stationId, {
    DateTime? when,
  }) async {
    final res = await _send(
      'GET',
      '/station/$stationId/departures',
      query: when != null ? {'when': when.toIso8601String()} : null,
    );
    final data = _data(res);
    return (data as List<dynamic>? ?? [])
        .whereType<Map<String, dynamic>>()
        .map(TrwlDeparture.fromJson)
        .toList();
  }

  Future<TrwlTrip> trip({
    required String hafasTripId,
    required String lineName,
  }) async {
    final res = await _send(
      'GET',
      '/trains/trip',
      query: {'hafasTripId': hafasTripId, 'lineName': lineName},
    );
    return TrwlTrip.fromJson(_data(res) as Map<String, dynamic>);
  }

  /// Performs a check-in. [start]/[destination] are Träwelling station ids;
  /// [departure]/[arrival] are the times at those stops.
  Future<TrwlStatus> checkin({
    required String tripId,
    required String lineName,
    required int start,
    required int destination,
    required DateTime departure,
    required DateTime arrival,
    String body = '',
    int visibility = 0,
    int business = 0,
    bool force = false,
  }) async {
    final res = await _send(
      'POST',
      '/trains/checkin',
      body: {
        'tripId': tripId,
        'lineName': lineName,
        'start': start,
        'destination': destination,
        'departure': departure.toIso8601String(),
        'arrival': arrival.toIso8601String(),
        if (body.isNotEmpty) 'body': body,
        'visibility': visibility,
        'business': business,
        'force': force,
      },
    );
    if (res.statusCode == 409) {
      throw const CheckinCollisionException(
        'Du bist bereits für eine überlappende Fahrt eingecheckt.',
      );
    }
    final data = _data(res);
    // CheckinSuccessResource nests the created status under `status`.
    final statusJson = (data is Map<String, dynamic>)
        ? (data['status'] ?? data) as Map<String, dynamic>
        : <String, dynamic>{};
    return TrwlStatus.fromJson(statusJson);
  }

  /// One-shot check-in driven straight from a train the user is already looking
  /// at (a vendo [Trip]) — no manual station search. Resolves the Träwelling
  /// trip by searching departures at [boardingName] around [boardingDeparture]
  /// and matching [lineName], then checks in from boarding → [alightingName].
  ///
  /// Throws a [TraewellingException] with a human message at any step that can't
  /// be matched, so callers can fall back to the manual flow.
  Future<TrwlStatus> checkinFromTrip({
    required String lineName,
    required String boardingName,
    required DateTime boardingDeparture,
    required String alightingName,
    String body = '',
    int visibility = 0,
    bool force = false,
  }) async {
    final stations = await searchStations(boardingName);
    if (stations.isEmpty) {
      throw TraewellingException(
        'Bahnhof „$boardingName" bei Träwelling nicht gefunden.',
      );
    }
    // Prefer an exact-ish name match, else the first hit.
    final station = stations.firstWhere(
      (s) => _nameEq(s.name, boardingName),
      orElse: () => stations.first,
    );

    final deps = await departures(
      station.id,
      when: boardingDeparture.subtract(const Duration(minutes: 6)),
    );
    final dep = _matchDeparture(deps, lineName, boardingDeparture);
    if (dep == null) {
      throw TraewellingException(
        'Abfahrt „$lineName" um diese Zeit nicht gefunden.',
      );
    }

    final t = await trip(hafasTripId: dep.tripId, lineName: dep.lineName);
    final boardIdx = t.stopovers.indexWhere(
      (s) => s.stationId == station.id || _nameEq(s.name, boardingName),
    );
    final after = boardIdx >= 0
        ? t.stopovers.sublist(boardIdx + 1)
        : t.stopovers;
    final dest = after.firstWhere(
      (s) => _nameEq(s.name, alightingName),
      orElse: () => after.isNotEmpty
          ? after.last
          : (throw TraewellingException(
              'Ziel „$alightingName" nicht im Laufweg.',
            )),
    );

    final depTime =
        (boardIdx >= 0 ? t.stopovers[boardIdx].departurePlanned : null) ??
        dep.plannedWhen ??
        dep.when ??
        boardingDeparture;
    final arrTime =
        dest.arrivalPlanned ?? dest.arrivalReal ?? dest.departurePlanned;
    if (arrTime == null) {
      throw const TraewellingException('Ankunftszeit am Ziel fehlt.');
    }

    return checkin(
      tripId: dep.tripId,
      lineName: dep.lineName,
      start: station.id,
      destination: dest.stationId,
      departure: depTime,
      arrival: arrTime,
      body: body,
      visibility: visibility,
      force: force,
    );
  }

  /// Pick the departure whose line matches [lineName] and whose time is closest
  /// to [target] (within ~40 min). Returns null when nothing reasonable matches.
  TrwlDeparture? _matchDeparture(
    List<TrwlDeparture> deps,
    String lineName,
    DateTime target,
  ) {
    final want = _normLine(lineName);
    TrwlDeparture? best;
    Duration bestDiff = const Duration(minutes: 40);
    for (final d in deps) {
      final got = _normLine(d.lineName);
      if (got != want && !got.endsWith(want) && !want.endsWith(got)) continue;
      final when = d.plannedWhen ?? d.when;
      if (when == null) continue;
      final diff = (when.difference(target)).abs();
      if (diff <= bestDiff) {
        bestDiff = diff;
        best = d;
      }
    }
    return best;
  }

  /// Line-name comparison key: drop spaces/case so "ICE 148" == "ICE148".
  String _normLine(String s) =>
      s.toLowerCase().replaceAll(RegExp(r'\s+'), '').trim();

  /// Loose station-name equality: case-insensitive, ignoring "Hbf", bracketed
  /// suffixes and punctuation so vendo and Träwelling names line up.
  bool _nameEq(String a, String b) => _normStation(a) == _normStation(b);

  String _normStation(String s) => s
      .toLowerCase()
      .replaceAll(RegExp(r'\(.*?\)'), '')
      .replaceAll(RegExp(r'\bhbf\b|\bhauptbahnhof\b'), '')
      .replaceAll(RegExp(r'[^a-zäöüß0-9]'), '')
      .trim();

  // --- Parsing helpers ------------------------------------------------------

  List<TrwlStatus> _statusList(dynamic data) => (data as List<dynamic>? ?? [])
      .whereType<Map<String, dynamic>>()
      .map(TrwlStatus.fromJson)
      .toList();

  List<TrwlUser> _userList(dynamic data) => (data as List<dynamic>? ?? [])
      .whereType<Map<String, dynamic>>()
      .map(TrwlUser.fromJson)
      .toList();

  // --- PKCE -----------------------------------------------------------------

  static const _chars =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';

  String _randomString(int length) {
    final rnd = Random.secure();
    return List.generate(
      length,
      (_) => _chars[rnd.nextInt(_chars.length)],
    ).join();
  }

  String _codeChallenge(String verifier) {
    final digest = sha256.convert(utf8.encode(verifier));
    return base64UrlEncode(digest.bytes).replaceAll('=', '');
  }
}

/// Outcome of a token refresh — see [TraewellingService._refresh]. Only
/// [rejected] is proof the session is over.
enum _TrwlRefresh { ok, rejected, transient }
