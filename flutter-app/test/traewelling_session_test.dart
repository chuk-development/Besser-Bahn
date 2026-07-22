import 'dart:convert';

import 'package:besser_bahn/services/traewelling_service.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response _json(Object body, [int status = 200]) =>
    http.Response(json.encode(body), status,
        headers: {'content-type': 'application/json'});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => FlutterSecureStorage.setMockInitialValues({
        'trwl_access_token': 'access-token',
        'trwl_refresh_token': 'refresh-token',
      }));

  group('#42 — the Feed asks for a route that exists', () {
    test('the global feed reads /statuses, not the gone /dashboard/global',
        () async {
      // Träwelling answers /api/v1/dashboard/global with 404 "route could not
      // be found" — the Feed tab could never load anything.
      final paths = <String>[];
      final svc = TraewellingService(client: MockClient((req) async {
        paths.add(req.url.path);
        if (req.url.path.endsWith('/dashboard/global')) {
          return _json({'message': 'route could not be found'}, 404);
        }
        return _json({'data': <dynamic>[]});
      }));

      await svc.globalDashboard();

      expect(paths.single, '/api/v1/statuses');
    });
  });

  group('#39 — a flaky network does not sign the rider out', () {
    test('a refresh that times out keeps the session', () async {
      var tokenCalls = 0;
      final svc = TraewellingService(client: MockClient((req) async {
        if (req.url.path.contains('/oauth/token')) {
          tokenCalls++;
          throw http.ClientException('connection reset');
        }
        return _json({'message': 'Unauthenticated.'}, 401);
      }));

      await expectLater(svc.dashboard(), throwsA(isA<TraewellingException>()));

      expect(tokenCalls, 1, reason: 'the refresh was attempted');
      expect(await svc.hasSession(), isTrue,
          reason: 'a network blip is not proof the session is over');
    });

    test('a 5xx from the token endpoint keeps the session', () async {
      final svc = TraewellingService(client: MockClient((req) async {
        if (req.url.path.contains('/oauth/token')) {
          return http.Response('bad gateway', 502);
        }
        return _json({'message': 'Unauthenticated.'}, 401);
      }));

      await expectLater(svc.dashboard(), throwsA(isA<TraewellingException>()));
      expect(await svc.hasSession(), isTrue);
    });

    test('a rejected refresh token really does sign out', () async {
      final svc = TraewellingService(client: MockClient((req) async {
        if (req.url.path.contains('/oauth/token')) {
          return _json({'error': 'invalid_grant'}, 400);
        }
        return _json({'message': 'Unauthenticated.'}, 401);
      }));

      await expectLater(
        svc.dashboard(),
        throwsA(isA<TraewellingException>()
            .having((e) => e.status, 'status', 401)),
      );
      expect(await svc.hasSession(), isFalse,
          reason: 'a revoked token is the one case where the session is gone');
    });

    test('a successful refresh retries the original request', () async {
      final paths = <String>[];
      var refreshed = false;
      final svc = TraewellingService(client: MockClient((req) async {
        if (req.url.path.contains('/oauth/token')) {
          refreshed = true;
          return _json({'access_token': 'fresh', 'expires_in': 3600});
        }
        paths.add(req.url.path);
        if (!refreshed) return _json({'message': 'Unauthenticated.'}, 401);
        return _json({'data': <dynamic>[]});
      }));

      await svc.dashboard();

      expect(paths, ['/api/v1/dashboard', '/api/v1/dashboard']);
      expect(await svc.hasSession(), isTrue);
    });
  });
}
