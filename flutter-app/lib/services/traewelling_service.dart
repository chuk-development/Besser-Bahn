import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:http/http.dart' as http;

import '../core/constants.dart';
import '../models/traewelling_models.dart';

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
class TraewellingService {
  TraewellingService({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;
  final http.Client _client = http.Client();

  static const _kAccess = 'trwl_access_token';
  static const _kRefresh = 'trwl_refresh_token';
  static const _kExpiry = 'trwl_expires_at'; // ISO-8601

  String? _accessToken;
  DateTime? _expiresAt;

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
    } catch (_) {/* not persisted on this platform */}
  }

  Future<void> _delete(String key) async {
    try {
      await _storage.delete(key: key);
    } catch (_) {/* nothing to clear / unsupported */}
  }

  /// Whether a token exists (in memory or storage). Does not validate it.
  Future<bool> hasSession() async {
    _accessToken ??= await _read(_kAccess);
    return _accessToken != null;
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
    if (access == null) {
      throw const TraewellingException('Token-Antwort ohne access_token');
    }
    _accessToken = access;
    _expiresAt = expiresIn != null
        ? DateTime.now().add(Duration(seconds: expiresIn))
        : null;
    await _write(_kAccess, access);
    if (refresh != null) await _write(_kRefresh, refresh);
    if (_expiresAt != null) {
      await _write(_kExpiry, _expiresAt!.toIso8601String());
    }
  }

  Future<void> _clearTokens() async {
    _accessToken = null;
    _expiresAt = null;
    await _delete(_kAccess);
    await _delete(_kRefresh);
    await _delete(_kExpiry);
  }

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

    final result = await FlutterWebAuth2.authenticate(
      url: authUrl.toString(),
      callbackUrlScheme: TraewellingConstants.callbackScheme,
    );

    final returned = Uri.parse(result);
    final code = returned.queryParameters['code'];
    final returnedState = returned.queryParameters['state'];
    if (code == null) {
      final err = returned.queryParameters['error_description'] ??
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
      String code, String verifier) async {
    final res = await _client.post(
      Uri.parse(TraewellingConstants.tokenUrl),
      headers: {'Accept': 'application/json'},
      body: {
        'grant_type': 'authorization_code',
        'client_id': TraewellingConstants.clientId,
        'redirect_uri': TraewellingConstants.redirectUrl,
        'code_verifier': verifier,
        'code': code,
      },
    );
    if (res.statusCode != 200) {
      throw TraewellingException(
          'Token-Tausch fehlgeschlagen: ${res.body}', res.statusCode);
    }
    return json.decode(res.body) as Map<String, dynamic>;
  }

  /// Refreshes the access token. Returns false if no refresh token / it failed.
  Future<bool> _refresh() async {
    final refresh = await _read(_kRefresh);
    if (refresh == null) return false;
    final res = await _client.post(
      Uri.parse(TraewellingConstants.tokenUrl),
      headers: {'Accept': 'application/json'},
      body: {
        'grant_type': 'refresh_token',
        'refresh_token': refresh,
        'client_id': TraewellingConstants.clientId,
        'scope': TraewellingConstants.scopes,
      },
    );
    if (res.statusCode != 200) return false;
    await _storeTokens(json.decode(res.body) as Map<String, dynamic>);
    return true;
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

    final uri = Uri.parse('${TraewellingConstants.apiBaseUrl}$path')
        .replace(queryParameters: query);
    final headers = {
      'Authorization': 'Bearer $_accessToken',
      'Accept': 'application/json',
      if (body != null) 'Content-Type': 'application/json',
    };
    final encoded = body != null ? json.encode(body) : null;

    http.Response res;
    switch (method) {
      case 'GET':
        res = await _client.get(uri, headers: headers);
      case 'POST':
        res = await _client.post(uri, headers: headers, body: encoded);
      case 'PUT':
        res = await _client.put(uri, headers: headers, body: encoded);
      case 'DELETE':
        res = await _client.delete(uri, headers: headers, body: encoded);
      default:
        throw TraewellingException('Unbekannte Methode $method');
    }

    if (res.statusCode == 401 && retryOn401) {
      if (await _refresh()) {
        return _send(method, path,
            query: query, body: body, retryOn401: false);
      }
      await _clearTokens();
      throw const TraewellingException('Sitzung abgelaufen', 401);
    }
    return res;
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
    return data is Map<String, dynamic> ? TrwlUser.fromJson(data) : null;
  }

  Future<TrwlUser> userProfile(String username) async {
    final res = await _send('GET', '/user/$username');
    return TrwlUser.fromJson(_data(res) as Map<String, dynamic>);
  }

  Future<List<TrwlStatus>> userStatuses(String username, {int page = 1}) async {
    final res =
        await _send('GET', '/user/$username/statuses', query: {'page': '$page'});
    return _statusList(_data(res));
  }

  Future<List<TrwlUser>> searchUsers(String query) async {
    final res = await _send('GET', '/user/search/${Uri.encodeComponent(query)}');
    return _userList(_data(res));
  }

  // --- Feed -----------------------------------------------------------------

  Future<List<TrwlStatus>> dashboard({int page = 1}) async {
    final res = await _send('GET', '/dashboard', query: {'page': '$page'});
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
        'GET', '/trains/station/autocomplete/${Uri.encodeComponent(query)}');
    final data = _data(res);
    return (data as List<dynamic>? ?? [])
        .whereType<Map<String, dynamic>>()
        .map(TrwlStation.fromJson)
        .toList();
  }

  Future<List<TrwlDeparture>> departures(int stationId, {DateTime? when}) async {
    final res = await _send('GET', '/station/$stationId/departures',
        query: when != null ? {'when': when.toIso8601String()} : null);
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
    final res = await _send('GET', '/trains/trip', query: {
      'hafasTripId': hafasTripId,
      'lineName': lineName,
    });
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
    final res = await _send('POST', '/trains/checkin', body: {
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
    });
    if (res.statusCode == 409) {
      throw const CheckinCollisionException(
          'Du bist bereits für eine überlappende Fahrt eingecheckt.');
    }
    final data = _data(res);
    // CheckinSuccessResource nests the created status under `status`.
    final statusJson = (data is Map<String, dynamic>)
        ? (data['status'] ?? data) as Map<String, dynamic>
        : <String, dynamic>{};
    return TrwlStatus.fromJson(statusJson);
  }

  // --- Parsing helpers ------------------------------------------------------

  List<TrwlStatus> _statusList(dynamic data) =>
      (data as List<dynamic>? ?? [])
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
    return List.generate(length, (_) => _chars[rnd.nextInt(_chars.length)])
        .join();
  }

  String _codeChallenge(String verifier) {
    final digest = sha256.convert(utf8.encode(verifier));
    return base64UrlEncode(digest.bytes).replaceAll('=', '');
  }
}
