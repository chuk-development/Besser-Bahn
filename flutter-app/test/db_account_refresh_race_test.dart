import 'dart:convert';

import 'package:besser_bahn/models/db_account.dart';
import 'package:besser_bahn/services/db_account_service.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// #52 — "Account-Refresh geht nicht": a few hours after every login the whole
/// session dies (BahnCard exception, "Kundenkonto-ID unbekannt", BahnBonus link
/// lost) and only a full logout + login + re-link fixes it.
///
/// Root cause: a full account refresh reads four endpoints at once. Once the
/// 5-minute access token has expired, each independently triggers a token
/// refresh. DB's Keycloak ROTATES the refresh token on every use and treats a
/// reused older token as an attack, invalidating the whole family. Two
/// concurrent refreshes race — the first rotates T0→T1, the second still holds
/// T0, Keycloak kills the session, the service reads that as an auth rejection
/// and signs the user out, wiping the just-minted T1 and BahnBonus with it.
///
/// The fix single-flights `_refresh()`: concurrent callers share one POST, so
/// the rotating token is used exactly once.

const _konto = 'K1';

/// A JWT carrying the kundenkontoid claim the service decodes for the profile
/// path. [n] makes each rotation's access token distinct.
String _jwt(int n) {
  String seg(Map<String, dynamic> m) =>
      base64Url.encode(utf8.encode(json.encode(m))).replaceAll('=', '');
  return '${seg({'alg': 'none'})}.'
      '${seg({'kundenkontoid': _konto, 'v': n})}.sig';
}

/// A Keycloak that rotates the refresh token on every use and rejects any
/// token other than the current one — reuse detection, exactly as DB's does.
class _RotatingIdp {
  _RotatingIdp() : _validRefresh = 'refresh-0';

  String _validRefresh;
  int _rotation = 0;

  /// Token POSTs seen — the whole point of the fix is that a concurrent refresh
  /// makes exactly one of these, not four.
  int tokenPosts = 0;

  /// Set once a *reused* (already-rotated) refresh token is presented — the
  /// event that, in production, invalidates the session family.
  bool reuseDetected = false;

  /// The access token currently accepted by the mob endpoints.
  String accessToken = _jwt(0);

  http.Client client() => MockClient((req) async {
        final path = req.url.path;

        if (path.endsWith('/openid-connect/token')) {
          tokenPosts++;
          final body = Uri.splitQueryString(req.body);
          final presented = body['refresh_token'];
          if (presented != _validRefresh) {
            // Reuse of a rotated token → Keycloak kills the family.
            reuseDetected = true;
            return http.Response(
                json.encode({'error': 'invalid_grant'}), 400);
          }
          _rotation++;
          _validRefresh = 'refresh-$_rotation';
          accessToken = _jwt(_rotation);
          return http.Response(
            json.encode({
              'access_token': accessToken,
              'refresh_token': _validRefresh,
              'expires_in': 300,
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }

        // Every mob endpoint requires the *current* access token.
        if (req.headers['Authorization'] != 'Bearer $accessToken') {
          return http.Response('', 401);
        }

        if (path == '/mob/kundenkonten/$_konto') {
          return _json({
            'kundenkontoId': _konto,
            'kundennummer': '1234567890',
            'vorname': 'Max',
            'nachname': 'Mustermann',
            'kundenprofile': [
              {
                'id': 'KP1',
                'kontaktmailadresse': {'email': 'max@example.org'},
              }
            ],
          });
        }
        if (path == '/mob/kundenkonten/$_konto/bbStatus') {
          return _json({
            'activeBonusPoints': 100,
            'activeStatusPoints': 50,
            'statusLevel': '1',
            'bbSubscription': false,
          });
        }
        if (path == '/mob/emobilebahncards') return _json([]);
        if (path == '/mob/reisenuebersicht') {
          return _json({'auftragsIndizes': [], 'reiseIndizes': []});
        }
        return http.Response('unexpected $path', 404);
      });

  static http.Response _json(Object body) => http.Response.bytes(
        utf8.encode(json.encode(body)),
        200,
        headers: {'content-type': 'application/json'},
      );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // Signed in, but the access token expired an hour ago — the state the app
    // is in when the user opens it a few hours after logging in.
    FlutterSecureStorage.setMockInitialValues({
      'db_access_token': _jwt(0),
      'db_refresh_token': 'refresh-0',
      'db_kundenkonto_id': _konto,
      'db_expires_at':
          DateTime.now().subtract(const Duration(hours: 1)).toIso8601String(),
    });
  });

  test('four concurrent reads after expiry refresh the token exactly once',
      () async {
    final idp = _RotatingIdp();
    final service = DbAccountService(client: idp.client());

    // The four fetches a full account refresh fires together.
    final results = await Future.wait([
      service.profile(),
      service.bahnbonus(),
      service.bahncards(),
      service.reisenuebersichtJson(),
    ]);

    expect(idp.tokenPosts, 1,
        reason: 'a single-flight refresh must collapse the concurrent expiry '
            'discoveries into one token rotation');
    expect(idp.reuseDetected, isFalse,
        reason: 'no caller may present an already-rotated refresh token');
    // All four actually returned data — the session survived.
    expect((results[0] as DbProfile).kundennummer, '1234567890');
    expect(await service.hasSession(), isTrue);
  });

  test('the rotated refresh token is persisted for the next run', () async {
    final idp = _RotatingIdp();
    final service = DbAccountService(client: idp.client());

    await Future.wait([service.profile(), service.bahncards()]);

    // A fresh service instance (next app launch) reads what was persisted and
    // can still refresh — proving the family was not killed.
    final next = DbAccountService(client: idp.client());
    final profile = await next.profile();
    expect(profile.kundennummer, '1234567890');
  });
}
