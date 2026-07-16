import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../core/app_log.dart';
import '../core/constants.dart';
import '../core/request_coalescer.dart';
import '../models/db_account.dart';
import '../models/db_ticket.dart';

/// Result of a refresh-token call.
enum _RefreshOutcome { success, transient, rejected }

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
  /// [client] is injectable so tests can drive the real request path
  /// (coalescing, ETags, retries) against a mock transport.
  DbAccountService({FlutterSecureStorage? storage, http.Client? client})
      : _client = client ?? http.Client(),
        _storage = storage ??
            const FlutterSecureStorage(
              // On iOS, allow reads after the device has been unlocked once
              // since boot — required so a token refresh fired by the app's
              // resume path doesn't fail with "data is locked". On Android,
              // flutter_secure_storage 10.x uses its own ciphers by default
              // (the legacy EncryptedSharedPreferences flag is deprecated and
              // ignored), so no aOptions needed.
              iOptions:
                  IOSOptions(accessibility: KeychainAccessibility.first_unlock),
            );

  final FlutterSecureStorage _storage;
  final http.Client _client;
  final _rng = Random();

  /// Guarantees "one refresh = one set of requests": concurrent reads of the
  /// same resource share a single call instead of racing each other into a 429
  /// that then answers everything from the stale cache (#31).
  final _coalescer = RequestCoalescer();

  static const _kAccess = 'db_access_token';
  static const _kRefresh = 'db_refresh_token';
  static const _kExpiry = 'db_expires_at'; // ISO-8601
  static const _kKontoId = 'db_kundenkonto_id';
  /// Stable per-install pair of UUIDs DB Navigator stamps on every request as
  /// `x-correlation-id` — same value for the whole session/install life. Stored
  /// in secure storage so it survives reinstall-less updates; regenerated only
  /// after a full logout.
  static const _kCorrelationId = 'db_correlation_id';

  /// Prefs key for ETag-Cache (URL → server etag). Sent back as
  /// `if-none-match`, identical to DB Navigator's caching behaviour. Cheap
  /// bytes saved on the wire + makes our traffic shape match.
  static const _kEtagPrefix = 'db_etag:';

  static const _timeout = Duration(seconds: 15);

  String? _accessToken;
  DateTime? _expiresAt;
  String? _kundenkontoId;
  String? _correlationId;
  // Lazy-loaded device descriptors. We never lie about the device — sending
  // the real model + Android SDK level is exactly what DB Navigator does, so
  // our request shape sits inside the natural distribution of real installs
  // and isn't statistically distinguishable.
  String? _deviceOsName;
  String? _deviceOsVersion;
  String? _deviceModel;
  Future<void>? _deviceInfoFuture;

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
    } catch (e) {
      // Surface to the in-app debug log so a missing keystore (no EncryptedSP
      // support, locked profile, broken libsecret on desktop) doesn't silently
      // amount to "the user is forced to log in every time" without diagnosis.
      AppLog.log('secure-storage write failed [$key]: $e', tag: 'db-account');
    }
  }

  Future<void> _delete(String key) async {
    try {
      await _storage.delete(key: key);
    } catch (_) {}
  }

  /// Whether a session token exists. Does not validate it. Eagerly primes
  /// all four token fields (access / refresh / expiry / kontoId) so the next
  /// `_send` can decide pre-emptively whether to refresh — without this,
  /// `_expiresAt` stayed null on cold start and every first request paid an
  /// extra 401/403 round-trip before the refresh actually fired.
  Future<bool> hasSession() async {
    await _loadTokens();
    if (_accessToken != null) return true;
    // A refresh token alone is enough to restore a session.
    return (await _read(_kRefresh)) != null;
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

  /// Outcome of a refresh attempt. `transient` means the request itself
  /// didn't reach the server / answered 5xx — tokens stay on disk so the
  /// next try (next launch / reconnect) can recover. `rejected` means
  /// Keycloak explicitly refused (400/401, usually invalid_grant) — the
  /// refresh token is dead and tokens should be cleared.
  Future<_RefreshOutcome> _refresh() async {
    final refresh = await _read(_kRefresh);
    if (refresh == null) {
      AppLog.log('refresh: no refresh_token on disk', tag: 'db-account');
      return _RefreshOutcome.rejected; // no token at all = nothing to retry
    }
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
      AppLog.log('refresh: timeout (transient)', tag: 'db-account');
      return _RefreshOutcome.transient;
    } catch (e) {
      AppLog.log('refresh: network error $e (transient)', tag: 'db-account');
      return _RefreshOutcome.transient;
    }
    AppLog.log(
        'refresh HTTP ${res.statusCode} (refresh ttl=${refresh.length}B)',
        tag: 'db-account');
    if (res.statusCode == 200) {
      // fall through to _storeTokens below
    } else if (res.statusCode == 400 || res.statusCode == 401) {
      // Keycloak explicitly rejected the refresh token — it's dead.
      AppLog.log(
          'refresh rejected · body: ${res.body.substring(0, res.body.length.clamp(0, 200))}',
          tag: 'db-account');
      return _RefreshOutcome.rejected;
    } else {
      // 5xx / unexpected — keep tokens, next try recovers.
      AppLog.log(
          'refresh non-200 (transient) · body: ${res.body.substring(0, res.body.length.clamp(0, 200))}',
          tag: 'db-account');
      return _RefreshOutcome.transient;
    }
    await _storeTokens(json.decode(res.body) as Map<String, dynamic>);
    return _RefreshOutcome.success;
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
    // Confirm what actually landed in storage so we can diagnose any
    // "logged out on relaunch" report from a real device.
    final persisted = await _read(_kRefresh);
    AppLog.log(
        'storeTokens ok · refresh persisted: ${persisted != null}',
        tag: 'db-account');
  }

  Future<void> logout() async {
    _accessToken = null;
    _expiresAt = null;
    _kundenkontoId = null;
    _correlationId = null;
    await _delete(_kAccess);
    await _delete(_kRefresh);
    await _delete(_kExpiry);
    await _delete(_kKontoId);
    // Drop the per-install correlation-id and every cached ETag so the next
    // login looks like a fresh install — no cross-account leak of the prior
    // user's id or cache state.
    await _delete(_kCorrelationId);
    try {
      final prefs = await SharedPreferences.getInstance();
      final keys = prefs.getKeys()
          .where((k) => k.startsWith(_kEtagPrefix))
          .toList();
      for (final k in keys) {
        await prefs.remove(k);
      }
    } catch (_) {/* best effort */}
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

  /// Headers that mirror the official DB Navigator app exactly — same set,
  /// same casing, same semantics (correlation-id stable per install,
  /// `x-instana-android` UUID fresh per request, real Android model + SDK
  /// level). Anything we leave off would mark our traffic as non-Navigator
  /// at the edge.
  Map<String, String> _headers(String media) => {
        'Authorization': 'Bearer $_accessToken',
        'Accept': media,
        'Accept-Language': 'de',
        'User-Agent': 'DBNavigator/Android/26.9.0',
        'X-App-Version': '26.9.0',
        'X-Correlation-ID': _correlationId ?? _uuid(),
        // ignore: use_null_aware_elements — null-aware map entries don't
        // allow nullable values yet (Dart 3.10), so keep the explicit if.
        if (_deviceOsName != null) 'X-Device-OS-Name': _deviceOsName!,
        if (_deviceOsVersion != null) 'X-Device-OS-Version': _deviceOsVersion!,
        if (_deviceModel != null) 'X-Device-Model': _deviceModel!,
        'X-Instana-Android': _uuid(),
      };

  /// Lazily reads the real device model + Android SDK level once per process
  /// and reuses the result. iOS/desktop/web fall through with `Android` /
  /// `33` / `samsung SM-A705FN` — a plausible mid-range Navigator install
  /// that won't stand out.
  Future<void> _ensureDeviceInfo() async {
    if (_deviceOsName != null) return;
    _deviceInfoFuture ??= _loadDeviceInfo();
    await _deviceInfoFuture;
  }

  Future<void> _loadDeviceInfo() async {
    try {
      if (!kIsWeb && Platform.isAndroid) {
        final info = await DeviceInfoPlugin().androidInfo;
        _deviceOsName = 'Android';
        _deviceOsVersion = info.version.sdkInt.toString();
        // DB Navigator sends "samsung SM-A705FN" — manufacturer + space + the
        // marketing model. Match exactly.
        _deviceModel = '${info.manufacturer} ${info.model}'.trim();
        return;
      }
    } catch (_) {/* fall through to safe defaults */}
    _deviceOsName = 'Android';
    _deviceOsVersion = '33';
    _deviceModel = 'samsung SM-A705FN';
  }

  /// Ensures a stable installation correlation-id exists. Generated once,
  /// persisted in secure storage, reused for every subsequent request — same
  /// header behaviour as the official app's per-install id. Regenerated only
  /// on explicit [logout].
  Future<void> _ensureCorrelationId() async {
    _correlationId ??= await _read(_kCorrelationId);
    if (_correlationId == null) {
      _correlationId = '${_uuid()}_${_uuid()}';
      await _writeKey(_kCorrelationId, _correlationId!);
    }
  }

  // --- ETag cache (per-URL, persisted in shared_preferences) ----------------

  Future<String?> _readEtag(String url) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString('$_kEtagPrefix$url');
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeEtag(String url, String etag) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('$_kEtagPrefix$url', etag);
    } catch (_) {/* best effort */}
  }

  /// Sends an authenticated request, transparently refreshing the access token
  /// once on a 401. [media] is the exact vendo media type for the endpoint
  /// (sent as both Accept and, for bodied requests, Content-Type).
  /// [extraHeaders] are merged on top of the default ones — used for the
  /// `call-trigger: login` header some endpoints require.
  ///
  /// [bypassEtag] drops the conditional `If-None-Match` for this one call, so a
  /// user-pulled refresh can't be answered 304 and handed back the cache it was
  /// meant to replace (#31). Navigator parity holds: a request without
  /// `if-none-match` is exactly what the official app sends whenever it has no
  /// cached ETag for the URL (every first launch), so the shape stays inside
  /// the natural distribution.
  ///
  /// GETs are coalesced by URL: they're idempotent reads, so two callers asking
  /// at once share one round-trip rather than racing into a per-client 429.
  /// Mutations (POST/DELETE bodies) always dispatch on their own — collapsing
  /// two deliberate writes into one would lose a write.
  Future<http.Response> _send(
    String method,
    String url, {
    required String media,
    List<int>? body,
    bool retryOn401 = true,
    Map<String, String> extraHeaders = const {},
    bool bypassEtag = false,
  }) {
    if (method != 'GET') {
      return _dispatch(method, url,
          media: media,
          body: body,
          retryOn401: retryOn401,
          extraHeaders: extraHeaders,
          bypassEtag: bypassEtag);
    }
    // Forced and conditional reads must not share: joining a conditional call
    // could answer a forced refresh with a 304.
    return _coalescer.run(
      'GET $url${bypassEtag ? ' !etag' : ''}',
      () => _dispatch(method, url,
          media: media,
          body: body,
          retryOn401: retryOn401,
          extraHeaders: extraHeaders,
          bypassEtag: bypassEtag),
    );
  }

  /// The actual round-trip behind [_send] — never coalesced, because its own
  /// 401/429 retries recurse into it and would otherwise wait on themselves.
  Future<http.Response> _dispatch(
    String method,
    String url, {
    required String media,
    List<int>? body,
    bool retryOn401 = true,
    Map<String, String> extraHeaders = const {},
    bool bypassEtag = false,
  }) async {
    // First-touch wiring: device info + per-install correlation-id. Cheap
    // (cached after first call) and required so the first request already
    // carries the full Navigator header set.
    await _ensureDeviceInfo();
    await _ensureCorrelationId();
    if (_accessToken == null) {
      await _loadTokens();
      // No access token but maybe a refresh token survived — mint one.
      if (_accessToken == null) {
        final r = await _refresh();
        if (r == _RefreshOutcome.rejected) {
          await logout();
          throw const DbAccountException('Sitzung abgelaufen', 401);
        }
        if (r == _RefreshOutcome.transient) {
          throw const DbAccountException(
              'Anmeldung temporär nicht erreichbar', null);
        }
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
    headers.addAll(extraHeaders);
    // ETag conditional GET — matches DB Navigator (the captured trace shows
    // `if-none-match` on every cached endpoint). Server replies 304 + empty
    // body when nothing changed; the caller layer above then re-uses the
    // stored cache instead of re-parsing. A forced refresh skips it: the whole
    // point of the pull is to not be told "unchanged" (#31).
    if (method == 'GET' && !bypassEtag) {
      final etag = await _readEtag(url);
      if (etag != null) headers['If-None-Match'] = etag;
    }

    http.Response res;
    try {
      switch (method) {
        case 'GET':
          res = await _client.get(uri, headers: headers).timeout(_timeout);
        case 'POST':
          res = await _client
              .post(uri, headers: headers, body: body)
              .timeout(_timeout);
        case 'DELETE':
          res = await _client
              .delete(uri, headers: headers, body: body)
              .timeout(_timeout);
        default:
          throw DbAccountException('Unbekannte Methode $method');
      }
    } on TimeoutException {
      throw const DbAccountException(
          'Zeitüberschreitung – die Bahn antwortet nicht.');
    }

    // 429: caller spammed the endpoint (multiple concurrent fetches of the
    // same resource). Honour Retry-After if set, otherwise back off briefly
    // and try once more — the BahnCard endpoint hit this when restore and
    // the profile-screen provider both fired in parallel.
    if (res.statusCode == 429 && retryOn401) {
      final retryAfterSec =
          int.tryParse(res.headers['retry-after'] ?? '') ?? 2;
      final delay = Duration(seconds: retryAfterSec.clamp(1, 5));
      AppLog.log('429 on ${Uri.parse(url).path} → backoff ${delay.inSeconds}s',
          tag: 'db-account');
      await Future.delayed(delay);
      return _dispatch(method, url,
          media: media, body: body, retryOn401: false,
          extraHeaders: extraHeaders, bypassEtag: bypassEtag);
    }

    // DB's mob backend returns **403** (not 401) when the access token has
    // expired — found in a real device cold-start trace where kundenkonto
    // answered 403 immediately while a refresh-able session sat on disk.
    // Treat 401 and 403 identically: refresh + retry once.
    if ((res.statusCode == 401 || res.statusCode == 403) && retryOn401) {
      AppLog.log('${res.statusCode} on ${Uri.parse(url).path} → refreshing',
          tag: 'db-account');
      final r = await _refresh();
      if (r == _RefreshOutcome.success) {
        return _dispatch(method, url,
            media: media, body: body, retryOn401: false,
            extraHeaders: extraHeaders, bypassEtag: bypassEtag);
      }
      // Only wipe the stored tokens when Keycloak EXPLICITLY rejected the
      // refresh — the previous behaviour wiped them on any failure (incl. a
      // transient timeout / 5xx) and forced the user to re-log on every cold
      // start. Now transient errors keep the tokens for the next try.
      if (r == _RefreshOutcome.rejected) {
        await logout();
        throw const DbAccountException('Sitzung abgelaufen', 401);
      }
      throw const DbAccountException(
          'Sitzung temporär nicht erreichbar — bitte erneut versuchen', null);
    }
    // 2xx with a fresh ETag → remember it for the next conditional GET.
    if (method == 'GET' && res.statusCode >= 200 && res.statusCode < 300) {
      final etag = res.headers['etag'];
      if (etag != null && etag.isNotEmpty) {
        await _writeEtag(url, etag);
      }
    }
    return res;
  }

  Future<void> _loadTokens() async {
    _accessToken = await _read(_kAccess);
    final exp = await _read(_kExpiry);
    _expiresAt = exp != null ? DateTime.tryParse(exp) : null;
    _kundenkontoId = await _read(_kKontoId);
    final hasRefresh = (await _read(_kRefresh)) != null;
    AppLog.log(
        'loadTokens access=${_accessToken != null} '
        'refresh=$hasRefresh exp=${_expiresAt?.toIso8601String() ?? '?'} '
        'konto=${_kundenkontoId != null}',
        tag: 'db-account');
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
  ///
  /// Always fresh — a POST never carries `If-None-Match`, so there's no
  /// `forceFresh` to ask for. It *is* coalesced: this endpoint is the hub of
  /// the account (the trip overview and the favorites both look up their id
  /// through it), so a refresh used to fire it three or four times at once and
  /// rate-limit itself (#31).
  Future<DbProfile> profile() async {
    final id = await _kontoId();
    if (id == null) {
      throw const DbAccountException('Kundenkonto-ID unbekannt', 401);
    }
    final url = '${DbAccountConstants.mobBase}/kundenkonten/$id';
    return _coalescer.run('PROFILE $url', () async {
      final res = await _dispatch('POST', url,
          media: DbAccountConstants.profileMedia, body: const []);
      final profile = DbProfile.fromJson(_decode(res, 'kundenkonto'));
      AppLog.log('profile ${profile.kundennummer}', tag: 'db-account');
      return profile;
    });
  }

  /// BahnBonus status. Returns null when the account has no BahnBonus (404) or
  /// when the server says our cache is still current (304) — either way the
  /// caller keeps what it has. [forceFresh] drops the conditional header so a
  /// user-pulled refresh gets the real current points.
  Future<DbBahnBonus?> bahnbonus({bool forceFresh = false}) async {
    final id = await _kontoId();
    if (id == null) return null;
    final res = await _send(
        'GET', '${DbAccountConstants.mobBase}/kundenkonten/$id/bbStatus',
        media: DbAccountConstants.bahnbonusMedia, bypassEtag: forceFresh);
    if (res.statusCode == 404) return null;
    // 304 used to fall into _decode and throw "bbStatus HTTP 304" — an error
    // the UI then had to paper over with the cache. It's not an error.
    if (res.statusCode == 304) return null;
    return DbBahnBonus.fromJson(_decode(res, 'bbStatus'));
  }

  /// Fetch BahnCards. Returns null when the server replies 304 Not Modified
  /// (the on-disk cache is still authoritative — caller keeps using it).
  /// [trigger] is sent as `call-trigger` and mirrors DB Navigator's per-
  /// context value: `login` on cold-start restore, `manual` on user-pulled
  /// refresh, `auto` on background revalidation. [forceFresh] skips the
  /// conditional header so a `manual` pull can't be answered 304.
  Future<List<DbBahnCard>?> bahncards(
      {String trigger = 'login', bool forceFresh = false}) async {
    AppLog.log('bahncards: GET emobilebahncards trigger=$trigger…',
        tag: 'db-account');
    final res = await _send(
        'GET', '${DbAccountConstants.mobBase}/emobilebahncards',
        media: DbAccountConstants.bahncardsMedia,
        extraHeaders: {'call-trigger': trigger},
        bypassEtag: forceFresh);
    AppLog.log(
        'bahncards HTTP ${res.statusCode} (${res.bodyBytes.length}B)',
        tag: 'db-account');
    if (res.statusCode == 304) return null;
    if (res.statusCode < 200 || res.statusCode >= 300) {
      // Log first ~200 chars of error body so the user sees the actual reason
      // (e.g. missing header / wrong version) in the in-app debug log.
      try {
        final body = utf8.decode(res.bodyBytes);
        AppLog.log(
            'bahncards body: ${body.substring(0, body.length.clamp(0, 200))}',
            tag: 'db-account');
      } catch (_) {}
      throw DbAccountException('bahncards HTTP ${res.statusCode}',
          res.statusCode);
    }
    final data = json.decode(utf8.decode(res.bodyBytes));
    if (data is! List) return const [];
    final cards = data
        .whereType<Map<String, dynamic>>()
        .map(DbBahnCard.fromJson)
        .toList();
    AppLog.log('${cards.length} BahnCard(s) parsed', tag: 'db-account');
    return cards;
  }

  /// The combined "Meine Reisen" overview: paid orders (`auftragsIndizes` —
  /// real tickets) PLUS tracked-but-unpaid trips (`reiseIndizes` — the user
  /// hit "Reise merken" on a search result). Both kinds are returned together
  /// so the Reisen tab can render them side by side. [onlyCurrent] false also
  /// includes past entries.
  /// Raw `reisenuebersicht` JSON — exposed so callers can persist it
  /// byte-identically to disk (offline-friendly Reisen tab) and re-parse with
  /// [parseReisenuebersicht]. Returns null on 304 Not Modified. [forceFresh]
  /// skips the conditional header — used by pull-to-refresh, and after we
  /// ourselves changed the account's trips (a 304 would hide our own write).
  Future<Map<String, dynamic>?> reisenuebersichtJson(
      {bool onlyCurrent = false, bool forceFresh = false}) async {
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
        media: DbAccountConstants.reisenMedia, bypassEtag: forceFresh);
    if (res.statusCode == 304) return null;
    return _decode(res, 'reisenuebersicht');
  }

  /// Same parsing the live `reisenuebersicht()` method does, but on a JSON
  /// that may have come from disk-cache instead of a fresh response.
  static DbReisenUebersicht parseReisenuebersicht(Map<String, dynamic> data) {
    final orders = (data['auftragsIndizes'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(DbReiseIndex.fromJson)
        .toList()
      ..sort((a, b) => (b.aenderungsDatum ?? DateTime(0))
          .compareTo(a.aenderungsDatum ?? DateTime(0)));
    final saved = (data['reiseIndizes'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(DbSavedReiseIndex.fromJson)
        .toList()
      ..sort((a, b) => (b.startDatum ?? b.aenderungsDatum ?? DateTime(0))
          .compareTo(a.startDatum ?? a.aenderungsDatum ?? DateTime(0)));
    return DbReisenUebersicht(orders: orders, saved: saved);
  }

  Future<DbReisenUebersicht> reisenuebersicht({bool onlyCurrent = false}) async {
    final data = await reisenuebersichtJson(onlyCurrent: onlyCurrent);
    if (data == null) return const DbReisenUebersicht();
    final parsed = parseReisenuebersicht(data);
    AppLog.log(
        '${parsed.orders.length} Auftrag/Aufträge, ${parsed.saved.length} gemerkte Reise(n)',
        tag: 'db-account');
    return parsed;
  }

  /// Fetch ONE tracked Reise's full verbindung by `rkUuid` (the id returned
  /// from [saveReise] / `reiseIndizes`). The body shape matches a search
  /// result's `verbindung`, so the result is fed to
  /// `VendoService.parseConnection` to render the same Reiseplan view.
  Future<Map<String, dynamic>?> savedReiseVerbindung(String rkUuid) async {
    final uri =
        Uri.parse('${DbAccountConstants.mobBase}/reisen/$rkUuid').replace(
      queryParameters: {'alternativeHalteBerechnung': 'true'},
    );
    final res = await _send('GET', uri.toString(),
        media: DbAccountConstants.freieReisenMedia);
    if (res.statusCode != 200) return null;
    final data = _decode(res, 'reise/$rkUuid');
    final details = data['reiseDetails'] as Map<String, dynamic>?;
    final verbindung = details?['verbindung'] as Map<String, dynamic>?;
    if (verbindung == null) return null;
    // Wrap so VendoService._parseConnection's "c['verbindung'] ?? c" logic
    // picks it up cleanly.
    return {'verbindung': verbindung};
  }

  /// Server-side Bahnhof favorites (Kiel Hbf etc.) with optional custom aliases.
  Future<List<DbStationFavorite>> stationFavorites() async {
    final p = await profile();
    final kdId = p.kundendatensatzId;
    if (kdId == null) return const [];
    final url =
        '${DbAccountConstants.mobBase}/kundendatensatz/$kdId/favoriten';
    final res = await _send('GET', url,
        media: DbAccountConstants.favoritenMedia);
    if (res.statusCode < 200 || res.statusCode >= 300) return const [];
    final data = json.decode(utf8.decode(res.bodyBytes));
    if (data is! List) return const [];
    return data
        .whereType<Map<String, dynamic>>()
        .map(DbStationFavorite.fromJson)
        .toList();
  }

  /// Raw `kundenkontingente` list — likely the Deutschland-Ticket / abo carrier.
  /// Returns the raw maps for now (the populated shape is only observable when
  /// the user actually owns an abo); the caller decides how to interpret them.
  Future<List<Map<String, dynamic>>> kundenkontingente() async {
    final res = await _send(
        'GET', '${DbAccountConstants.mobBase}/kundenkontingente',
        media: DbAccountConstants.kundenkontingenteMedia);
    if (res.statusCode < 200 || res.statusCode >= 300) return const [];
    final data = json.decode(utf8.decode(res.bodyBytes));
    if (data is! List) return const [];
    return data.whereType<Map<String, dynamic>>().toList();
  }

  /// A single booked ticket — raw `auftrag` JSON (kept raw so the caller can
  /// persist it byte-identically to disk and re-parse offline, which is how
  /// the Reisen tab keeps showing real ticket cards across cold starts and
  /// no-network). Parse with [DbTicket.fromJson]. Returns null on 304.
  Future<Map<String, dynamic>?> ticketJson(
      String auftragsnummer, String kundenwunschId) async {
    final url = '${DbAccountConstants.mobBase}/auftrag/$auftragsnummer'
        '/kundenwunsch/$kundenwunschId';
    final res =
        await _send('GET', url, media: DbAccountConstants.auftragMedia);
    if (res.statusCode == 304) return null;
    return _decode(res, 'auftrag');
  }

  // --- Saved trips ("Meine Reisen") -----------------------------------------

  /// Save a journey to the user's official DB account as a tracked "Reise"
  /// (the same as DB Navigator's "merken" — it appears in Meine Reisen and the
  /// app tracks it for delays). [kontext] is the HAFAS recon string of the
  /// connection (a [Journey]'s refreshToken). Returns the created trip's
  /// `rkUuid` (needed to remove it again), or null on failure.
  Future<String?> saveReise({
    required String kontext,
    required String fromLocationId,
    required String toLocationId,
    required DateTime departure,
    bool firstClass = false,
  }) async {
    final body = {
      'kontext': kontext,
      'leistungsklasse': firstClass ? 'KLASSE_1' : 'KLASSE_2',
      'ueberwachung': {
        'alarmeinstellungen': {'abweichungsAlarm': true, 'regelAlarm': true},
      },
      'verbindungswunsch': {
        'abgangsLocationId': fromLocationId,
        'alternativeHalteBerechnung': true,
        'verkehrsmittel': ['ALL'],
        'zeitWunsch': {
          'reiseDatum': _isoWithOffset(departure),
          'zeitPunktArt': 'ABFAHRT',
        },
        'zielLocationId': toLocationId,
      },
    };
    final res = await _send('POST', '${DbAccountConstants.mobBase}/reisen',
        media: DbAccountConstants.freieReisenMedia,
        body: utf8.encode(json.encode(body)));
    if (res.statusCode != 201 && res.statusCode != 200) {
      AppLog.log('saveReise HTTP ${res.statusCode}', tag: 'db-account');
      return null;
    }
    final data = json.decode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    final details = data['reiseDetails'] as Map<String, dynamic>?;
    return details?['rkUuid'] as String?;
  }

  /// Remove a saved trip from the DB account by its `rkUuid`.
  Future<bool> deleteReise(String rkUuid) async {
    final res = await _send(
        'DELETE', '${DbAccountConstants.mobBase}/reisen/$rkUuid',
        media: DbAccountConstants.freieReisenMedia);
    return res.statusCode == 204 || res.statusCode == 200;
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

  /// ISO-8601 with the local UTC offset, as the DB Navigator app sends.
  String _isoWithOffset(DateTime dt) {
    final l = dt.toLocal();
    final off = l.timeZoneOffset;
    final sign = off.isNegative ? '-' : '+';
    final h = off.inHours.abs().toString().padLeft(2, '0');
    final m = (off.inMinutes.abs() % 60).toString().padLeft(2, '0');
    final base = l.toIso8601String().split('.').first;
    return '$base$sign$h:$m';
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
