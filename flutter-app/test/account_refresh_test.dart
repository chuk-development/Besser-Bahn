import 'dart:convert';

import 'package:besser_bahn/providers/account_provider.dart';
import 'package:besser_bahn/providers/service_providers.dart';
import 'package:besser_bahn/services/db_account_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// End-to-end cover for #31: "changes in the DB account don't show up, and
/// pull-to-refresh doesn't reliably reload them".
///
/// These drive the REAL [DbAccountService] and the REAL providers against a
/// mock transport, because the bug lived precisely in how those two layers
/// combined: the profile reload rebuilt every dependent controller, each
/// rebuild fired a background revalidation racing the explicit refresh, and the
/// resulting duplicate concurrent GETs are what earns a per-client 429 — after
/// which every source silently answers from its stale disk cache.

const _konto = 'K1';

/// A record of one request the app made.
class _Req {
  final String method;
  final Uri url;
  final Map<String, String> headers;
  _Req(this.method, this.url, this.headers);

  /// Path without the query — the query carries ids we don't assert on.
  String get path => url.path;
}

class _Backend {
  final List<_Req> requests = [];

  /// Flipped by a test to simulate the user editing their address on bahn.de.
  String strasse = 'Alte Straße 1';
  int bonusPoints = 100;

  /// Every GET answers with an ETag, like the real backend — the app stores it
  /// and sends it back as If-None-Match on conditional reads.
  static const _etag = 'W/"v1"';

  /// When true, conditional GETs (those carrying If-None-Match) are answered
  /// 304 — i.e. the server insists nothing changed. A forced refresh must not
  /// be answerable this way, or it hands back the cache it meant to replace.
  bool etag304 = true;

  /// Answer everything 429, as the per-client rate limiter does for minutes
  /// once a burst of duplicate requests trips it.
  bool rateLimited = false;

  List<_Req> of(String path) =>
      requests.where((r) => r.path == path).toList();

  int count(String path) => of(path).length;

  http.Client client() => MockClient((req) async {
        requests.add(_Req(req.method, req.url, req.headers));
        final path = req.url.path;

        if (rateLimited) {
          return http.Response(
              json.encode({'domain': 'MOB', 'code': 'RETRY', 'status': 'ERROR'}),
              429,
              headers: {'retry-after': '1'});
        }

        if (path == '/mob/kundenkonten/$_konto') {
          return _json({
            'kundenkontoId': _konto,
            'kundennummer': '1234567890',
            'vorname': 'Max',
            'nachname': 'Mustermann',
            'anrede': 'HR',
            'geburtsdatum': '1990-01-01',
            'kundendatensatzId': 'KD1',
            'hauptadresse': {
              'strasse': strasse,
              'plz': '12345',
              'ort': 'Musterstadt',
              'land': 'DE',
            },
            'kundenprofile': [
              {
                'id': 'KP1',
                'kontaktmailadresse': {'email': 'max@example.org'},
              }
            ],
          });
        }

        // Conditional GET → 304 unless the caller deliberately skipped the
        // If-None-Match header.
        if (req.method == 'GET' &&
            etag304 &&
            req.headers.containsKey('If-None-Match')) {
          return http.Response('', 304);
        }

        if (path == '/mob/kundenkonten/$_konto/bbStatus') {
          return _json({
            'activeBonusPoints': bonusPoints,
            'activeStatusPoints': 50,
            'statusLevel': '1',
            'bbSubscription': false,
          });
        }
        if (path == '/mob/emobilebahncards') return _json([]);
        if (path == '/mob/reisenuebersicht') {
          return _json({'auftragsIndizes': [], 'reiseIndizes': []});
        }
        if (path == '/mob/kundendatensatz/KD1/favoriten') return _json([]);
        return http.Response('unexpected ${req.method} $path', 404);
      });

  static http.Response _json(Object body) => http.Response.bytes(
        utf8.encode(json.encode(body)),
        200,
        headers: {'content-type': 'application/json', 'etag': _etag},
      );
}

/// A JWT whose payload carries the kundenkontoid claim the service decodes.
String _jwt() {
  String seg(Map<String, dynamic> m) =>
      base64Url.encode(utf8.encode(json.encode(m))).replaceAll('=', '');
  return '${seg({'alg': 'none'})}.${seg({'kundenkontoid': _konto})}.sig';
}

/// Lets the async provider/SharedPreferences plumbing settle.
Future<void> _settle() async {
  for (var i = 0; i < 12; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Backend backend;
  late ProviderContainer container;

  /// A container in the state the Profil tab creates: signed in, cold start
  /// done, every source on the screen built and listened to.
  Future<void> boot() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({
      'db_access_token': _jwt(),
      'db_refresh_token': 'refresh',
      'db_kundenkonto_id': _konto,
    });
    backend = _Backend();
    container = ProviderContainer(overrides: [
      dbAccountServiceProvider
          .overrideWithValue(DbAccountService(client: backend.client())),
    ]);
    // The Profil tab watches all of these; they must be alive, or a refresh
    // would be building them for the first time rather than refreshing them.
    container.listen(dbAuthProvider, (_, _) {});
    container.listen(bahnbonusProvider, (_, _) {});
    container.listen(bahncardsProvider, (_, _) {});
    container.listen(reisenuebersichtProvider, (_, _) {});
    await _settle();
  }

  tearDown(() => container.dispose());

  group('pull-to-refresh reloads the whole account (#31)', () {
    test('a profile change made outside the app shows up after one refresh',
        () async {
      await boot();
      expect(container.read(dbAuthProvider).profile?.adresse?.strasse,
          'Alte Straße 1');

      // The user corrects their address on bahn.de, then pulls to refresh.
      backend.strasse = 'Neue Straße 2';
      await container.read(accountRefreshProvider).refresh();

      expect(container.read(dbAuthProvider).profile?.adresse?.strasse,
          'Neue Straße 2',
          reason: 'the refresh must replace the profile, not keep the cache');
      expect(container.read(dbAuthProvider).error, isNull);
      expect(container.read(dbAuthProvider).lastRefreshedAt, isNotNull,
          reason: '"Zuletzt aktualisiert" proves the refresh actually ran');
    });

    test('BahnBonus updates without a logout/login round-trip', () async {
      await boot();
      expect(container.read(bahnbonusProvider).value?.activeBonusPoints, 100);

      backend.bonusPoints = 250;
      await container.read(accountRefreshProvider).refresh();

      expect(container.read(bahnbonusProvider).value?.activeBonusPoints, 250,
          reason: 'this is the report: points only moved after re-login, '
              'because the forced refresh was answered 304 / rate-limited '
              'and fell back to the disk cache');
    });

    test('one refresh = exactly one request per source', () async {
      await boot();
      backend.requests.clear();

      await container.read(accountRefreshProvider).refresh();
      await _settle();

      // The profile is requested by the refresh itself AND, indirectly, by the
      // trip overview (which needs kundenprofilId) — the service's coalescer
      // must collapse those into one POST.
      expect(backend.count('/mob/kundenkonten/$_konto'), 1,
          reason: 'duplicate concurrent requests are what trip the 429 that '
              'makes a refresh silently serve the stale cache');
      expect(backend.count('/mob/kundenkonten/$_konto/bbStatus'), 1);
      expect(backend.count('/mob/emobilebahncards'), 1);
      expect(backend.count('/mob/reisenuebersicht'), 1);
    });

    test('a forced refresh skips If-None-Match, so it cannot be told 304',
        () async {
      await boot();
      // The cold start stored an ETag for every GET.
      expect(
        backend
            .of('/mob/kundenkonten/$_konto/bbStatus')
            .every((r) => !r.headers.containsKey('If-None-Match')),
        isTrue,
        reason: 'nothing was cached yet on the very first read',
      );
      backend.requests.clear();

      await container.read(accountRefreshProvider).refresh();
      await _settle();

      for (final path in [
        '/mob/kundenkonten/$_konto/bbStatus',
        '/mob/emobilebahncards',
        '/mob/reisenuebersicht',
      ]) {
        expect(backend.of(path).single.headers.containsKey('If-None-Match'),
            isFalse,
            reason: '$path was fetched conditionally — the server answers 304 '
                'and the user keeps staring at the old value');
      }
    });

    test('a second pull while one runs joins it instead of doubling everything',
        () async {
      await boot();
      backend.requests.clear();

      final refresher = container.read(accountRefreshProvider);
      await Future.wait([refresher.refresh(), refresher.refresh()]);
      await _settle();

      expect(backend.count('/mob/kundenkonten/$_konto'), 1);
      expect(backend.count('/mob/kundenkonten/$_konto/bbStatus'), 1);
      expect(backend.count('/mob/reisenuebersicht'), 1);
    });

    test('the automatic resume refresh is throttled, the manual pull is not',
        () async {
      await boot();
      backend.requests.clear();

      // Resume right after the cold start already refreshed → skipped.
      await container.read(accountRefreshProvider).refresh(auto: true);
      expect(backend.requests, isEmpty,
          reason: 'resume fires far more often than the account changes');

      // A user-pulled refresh is never throttled.
      await container.read(accountRefreshProvider).refresh();
      expect(backend.count('/mob/kundenkonten/$_konto'), 1);
    });

    test('a failed refresh surfaces as an error instead of a silent no-op',
        () async {
      await boot();
      expect(container.read(dbAuthProvider).isLoggedIn, isTrue);

      // Every endpoint 429s from here on — the state the rate limiter leaves
      // the app in, and the reason a pull used to change nothing at all.
      backend.rateLimited = true;
      await container.read(accountRefreshProvider).refresh();

      final auth = container.read(dbAuthProvider);
      expect(auth.error, contains('Aktualisieren fehlgeschlagen'),
          reason: 'a refresh that could not run must say so — silently '
              'showing the old data is what made this look broken');
      expect(auth.profile, isNotNull,
          reason: 'a failed refresh must not sign the user out');
    });
  });
}
