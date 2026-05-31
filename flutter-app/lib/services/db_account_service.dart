import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:http/http.dart' as http;

import '../core/app_log.dart';
import '../core/constants.dart';
import '../models/db_account.dart';
import '../models/db_ticket.dart';

/// Raised when a DB account call fails. [status] carries the HTTP code so
/// callers can special-case 401 (re-login).
class DbAccountException implements Exception {
  final String message;
  final int? status;
  const DbAccountException(this.message, [this.status]);
  @override
  String toString() => 'DbAccountException($status): $message';
}

/// Authenticated client for the signed-in user's DB account: profile,
/// BahnBonus, BahnCards and booked tickets — read from the same DB Navigator
/// backend (`app.services-bahn.de/mob`) the official app uses, authenticated
/// with a real DB login (OAuth2 Authorization Code + PKCE).
///
/// The DB password is **never** seen by this app: login happens entirely on
/// DB's own page (`accounts.bahn.de`) inside the system auth tab; we only ever
/// receive the OAuth `code` and exchange it for tokens. The long-lived refresh
/// token is the only thing persisted (platform secure store); the 5-minute
/// access token is refreshed transparently on a 401.
class DbAccountService {
  DbAccountService({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;
  final http.Client _client = http.Client();
  final _rng = Random();

  static const _kAccess = 'db_access_token';
  static const _kRefresh = 'db_refresh_token';
  static const _kExpiry = 'db_expires_at'; // ISO-8601
  static const _kKontoId = 'db_kundenkonto_id';

  static const _timeout = Duration(seconds: 15);

  String? _accessToken;
  DateTime? _expiresAt;
  String? _kundenkontoId;

  // --- Secure-storage wrappers (never crash on a missing platform impl) -----

  Future<String?> _read(String key) async {
    try {
      return await _storage.read(key: key);
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeKey(String key, String value) async {
    try {
      await _storage.write(key: key, value: value);
    } catch (_) {/* not persisted on this platform */}
  }

  Future<void> _delete(String key) async {
    try {
      await _storage.delete(key: key);
    } catch (_) {}
  }

  /// Whether a session token exists. Does not validate it.
  Future<bool> hasSession() async {
    _accessToken ??= await _read(_kAccess);
    if (_accessToken == null) {
      // A refresh token alone is enough to restore a session.
      return (await _read(_kRefresh)) != null;
    }
    return true;
  }

  // --- OAuth (PKCE) ---------------------------------------------------------

  /// Runs the full DB browser login. Returns the loaded profile on success.
  Future<DbProfile> login() async {
    final verifier = _randomString(64);
    final challenge = _codeChallenge(verifier);
    final state = 'dbnav-${_randomString(10)}';

    final authUrl = Uri.parse(DbAccountConstants.authorizeUrl).replace(
      queryParameters: {
        'response_type': 'code',
        'client_id': DbAccountConstants.clientId,
        'state': state,
        'code_challenge': challenge,
        'code_challenge_method': 'S256',
        'prompt': 'login',
        'scope': DbAccountConstants.scope,
        'redirect_uri': DbAccountConstants.redirectUrl,
        'cancel_uri': DbAccountConstants.cancelUrl,
      },
    );

    AppLog.log('login → ${DbAccountConstants.authorizeUrl}', tag: 'db-account');
    final result = await FlutterWebAuth2.authenticate(
      url: authUrl.toString(),
      callbackUrlScheme: DbAccountConstants.callbackScheme,
    );

    final returned = Uri.parse(result);
    final code = returned.queryParameters['code'];
    final returnedState = returned.queryParameters['state'];
    if (code == null) {
      final err = returned.queryParameters['error_description'] ??
          returned.queryParameters['error'] ??
          'Kein Autorisierungscode erhalten';
      throw DbAccountException(err);
    }
    if (returnedState != state) {
      throw const DbAccountException('State stimmt nicht überein (Abbruch)');
    }

    final token = await _exchangeCode(code, verifier);
    await _storeTokens(token);
    return profile();
  }

  Future<Map<String, dynamic>> _exchangeCode(
      String code, String verifier) async {
    final res = await _client.post(
      Uri.parse(DbAccountConstants.tokenUrl),
      headers: {'Accept': 'application/json'},
      body: {
        'grant_type': 'authorization_code',
        'client_id': DbAccountConstants.clientId,
        'redirect_uri': DbAccountConstants.redirectUrl,
        'code_verifier': verifier,
        'code': code,
      },
    ).timeout(_timeout);
    if (res.statusCode != 200) {
      throw DbAccountException(
          'Anmeldung fehlgeschlagen: ${res.body}', res.statusCode);
    }
    return json.decode(res.body) as Map<String, dynamic>;
  }

  Future<bool> _refresh() async {
    final refresh = await _read(_kRefresh);
    if (refresh == null) return false;
    final http.Response res;
    try {
      res = await _client.post(
        Uri.parse(DbAccountConstants.tokenUrl),
        headers: {'Accept': 'application/json'},
        body: {
          'grant_type': 'refresh_token',
          'refresh_token': refresh,
          'client_id': DbAccountConstants.clientId,
        },
      ).timeout(_timeout);
    } on TimeoutException {
      return false;
    }
    if (res.statusCode != 200) return false;
    await _storeTokens(json.decode(res.body) as Map<String, dynamic>);
    return true;
  }

  Future<void> _storeTokens(Map<String, dynamic> token) async {
    final access = token['access_token'] as String?;
    final refresh = token['refresh_token'] as String?;
    final expiresIn = (token['expires_in'] as num?)?.toInt();
    if (access == null) {
      throw const DbAccountException('Token-Antwort ohne access_token');
    }
    _accessToken = access;
    _expiresAt = expiresIn != null
        ? DateTime.now().add(Duration(seconds: expiresIn))
        : null;
    _kundenkontoId = _kontoIdFromJwt(access) ?? _kundenkontoId;

    await _writeKey(_kAccess, access);
    if (refresh != null) await _writeKey(_kRefresh, refresh);
    if (_expiresAt != null) {
      await _writeKey(_kExpiry, _expiresAt!.toIso8601String());
    }
    if (_kundenkontoId != null) await _writeKey(_kKontoId, _kundenkontoId!);
  }

  Future<void> logout() async {
    _accessToken = null;
    _expiresAt = null;
    _kundenkontoId = null;
    await _delete(_kAccess);
    await _delete(_kRefresh);
    await _delete(_kExpiry);
    await _delete(_kKontoId);
  }

  /// The `kundenkontoid` claim carried in the access-token JWT — the id used in
  /// the profile path. Decoded locally, no network call.
  String? _kontoIdFromJwt(String jwt) {
    try {
      final parts = jwt.split('.');
      if (parts.length < 2) return null;
      final payload = parts[1];
      final normalized = base64Url.normalize(payload);
      final map = json.decode(utf8.decode(base64Url.decode(normalized)))
          as Map<String, dynamic>;
      return map['kundenkontoid'] as String? ?? map['kundenkontoId'] as String?;
    } catch (_) {
      return null;
    }
  }

  Future<String?> _kontoId() async {
    _kundenkontoId ??= await _read(_kKontoId);
    if (_kundenkontoId == null && _accessToken != null) {
      _kundenkontoId = _kontoIdFromJwt(_accessToken!);
    }
    return _kundenkontoId;
  }

  // --- Authenticated HTTP core ----------------------------------------------

  Map<String, String> _headers(String media) => {
        'Authorization': 'Bearer $_accessToken',
        'Accept': media,
        'Accept-Language': 'de',
        'User-Agent': 'DBNavigator/Android/26.9.0',
        'X-App-Version': '26.9.0',
        'X-Correlation-ID': '${_uuid()}_${_uuid()}',
      };

  /// Sends an authenticated request, transparently refreshing the access token
  /// once on a 401. [media] is the exact vendo media type for the endpoint
  /// (sent as both Accept and, for bodied requests, Content-Type).
  Future<http.Response> _send(
    String method,
    String url, {
    required String media,
    List<int>? body,
    bool retryOn401 = true,
  }) async {
    if (_accessToken == null) {
      await _loadTokens();
      // No access token but maybe a refresh token survived — mint one.
      if (_accessToken == null && !await _refresh()) {
        throw const DbAccountException('Nicht angemeldet', 401);
      }
    }
    // Pre-emptive refresh: the access token only lives 5 minutes.
    if (_expiresAt != null &&
        DateTime.now().isAfter(_expiresAt!.subtract(const Duration(seconds: 20)))) {
      await _refresh();
    }

    final uri = Uri.parse(url);
    final headers = _headers(media);
    if (body != null) headers['Content-Type'] = media;

    http.Response res;
    try {
      switch (method) {
        case 'GET':
          res = await _client.get(uri, headers: headers).timeout(_timeout);
        case 'POST':
          res = await _client
              .post(uri, headers: headers, body: body)
              .timeout(_timeout);
        default:
          throw DbAccountException('Unbekannte Methode $method');
      }
    } on TimeoutException {
      throw const DbAccountException(
          'Zeitüberschreitung – die Bahn antwortet nicht.');
    }

    if (res.statusCode == 401 && retryOn401) {
      if (await _refresh()) {
        return _send(method, url, media: media, body: body, retryOn401: false);
      }
      await logout();
      throw const DbAccountException('Sitzung abgelaufen', 401);
    }
    return res;
  }

  Future<void> _loadTokens() async {
    _accessToken = await _read(_kAccess);
    final exp = await _read(_kExpiry);
    _expiresAt = exp != null ? DateTime.tryParse(exp) : null;
    _kundenkontoId = await _read(_kKontoId);
  }

  Map<String, dynamic> _decode(http.Response res, String what) {
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw DbAccountException('$what HTTP ${res.statusCode}', res.statusCode);
    }
    return json.decode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
  }

  // --- Account data ---------------------------------------------------------

  /// The signed-in profile. `POST` with an empty body (the DB app does the
  /// same), path keyed by the JWT's `kundenkontoid`.
  Future<DbProfile> profile() async {
    final id = await _kontoId();
    if (id == null) {
      throw const DbAccountException('Kundenkonto-ID unbekannt', 401);
    }
    final res = await _send('POST', '${DbAccountConstants.mobBase}/kundenkonten/$id',
        media: DbAccountConstants.profileMedia, body: const []);
    final profile = DbProfile.fromJson(_decode(res, 'kundenkonto'));
    AppLog.log('profile ${profile.kundennummer}', tag: 'db-account');
    return profile;
  }

  Future<DbBahnBonus?> bahnbonus() async {
    final id = await _kontoId();
    if (id == null) return null;
    final res = await _send(
        'GET', '${DbAccountConstants.mobBase}/kundenkonten/$id/bbStatus',
        media: DbAccountConstants.bahnbonusMedia);
    if (res.statusCode == 404) return null;
    return DbBahnBonus.fromJson(_decode(res, 'bbStatus'));
  }

  Future<List<DbBahnCard>> bahncards() async {
    final res = await _send(
        'GET', '${DbAccountConstants.mobBase}/emobilebahncards',
        media: DbAccountConstants.bahncardsMedia);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw DbAccountException('bahncards HTTP ${res.statusCode}',
          res.statusCode);
    }
    final data = json.decode(utf8.decode(res.bodyBytes));
    if (data is! List) return const [];
    final cards = data
        .whereType<Map<String, dynamic>>()
        .map(DbBahnCard.fromJson)
        .toList();
    AppLog.log('${cards.length} BahnCard(s)', tag: 'db-account');
    return cards;
  }

  /// The trip/ticket overview. [onlyCurrent] false returns past trips too.
  Future<List<DbReiseIndex>> reisenuebersicht({bool onlyCurrent = false}) async {
    final id = await _kontoId();
    // We need the kundenprofilId (not kundenkontoId) for this call. Pull it
    // from the profile (cheap, cached upstream by the provider layer).
    final p = await profile();
    final profilId = p.kundenprofilId;
    if (profilId == null) {
      throw const DbAccountException('Kundenprofil-ID unbekannt');
    }
    final uri = Uri.parse('${DbAccountConstants.mobBase}/reisenuebersicht')
        .replace(queryParameters: {
      'kundenprofilId': profilId,
      'nurAktuelleAuftraege': onlyCurrent.toString(),
    });
    final res = await _send('GET', uri.toString(),
        media: DbAccountConstants.reisenMedia);
    final data = _decode(res, 'reisenuebersicht');
    final indices = <DbReiseIndex>[];
    for (final key in const ['auftragsIndizes', 'reiseIndizes']) {
      for (final e in (data[key] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()) {
        indices.add(DbReiseIndex.fromJson(e));
      }
    }
    // Newest change first.
    indices.sort((a, b) => (b.aenderungsDatum ?? DateTime(0))
        .compareTo(a.aenderungsDatum ?? DateTime(0)));
    AppLog.log('${indices.length} Reise(n) (konto ${id ?? '?'})',
        tag: 'db-account');
    return indices;
  }

  /// A single booked ticket with its barcode.
  Future<DbTicket> ticket(String auftragsnummer, String kundenwunschId) async {
    final url = '${DbAccountConstants.mobBase}/auftrag/$auftragsnummer'
        '/kundenwunsch/$kundenwunschId';
    final res =
        await _send('GET', url, media: DbAccountConstants.auftragMedia);
    return DbTicket.fromJson(_decode(res, 'auftrag'));
  }

  // --- PKCE / utils ---------------------------------------------------------

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

  String _uuid() {
    final b = List<int>.generate(16, (_) => _rng.nextInt(256));
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    String hex(int x) => x.toRadixString(16).padLeft(2, '0');
    final s = b.map(hex).join();
    return '${s.substring(0, 8)}-${s.substring(8, 12)}-${s.substring(12, 16)}'
        '-${s.substring(16, 20)}-${s.substring(20)}';
  }

  void dispose() => _client.close();
}
