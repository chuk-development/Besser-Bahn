import 'dart:convert';

import 'package:besser_bahn/services/traewelling_service.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response _json(Object body, [int status = 200]) => http.Response(
  json.encode(body),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(
    () => FlutterSecureStorage.setMockInitialValues({
      'trwl_access_token': 'access-token',
      'trwl_refresh_token': 'refresh-token',
    }),
  );

  group('#109 — check-in finds the train at a split station', () {
    // München Hbf platforms 27–36 are their own stop at DB and at Träwelling
    // ("München Hbf Gl.27-36"). The RB16 from Gl. 32 is only on that board.
    final dep = DateTime.utc(2026, 11, 15, 23, 30); // 00:30 Berlin

    MockClient server(List<int> boardsAsked, Map<String, dynamic> checkin) =>
        MockClient((req) async {
          final p = req.url.path;
          if (p.contains('/trains/station/autocomplete/')) {
            return _json({
              'data': [
                {'id': 1, 'name': 'München Hbf'},
                {'id': 2, 'name': 'München Hbf Gl.27-36'},
                {'id': 3, 'name': 'München Ost'},
              ],
            });
          }
          final board = RegExp(r'/station/(\d+)/departures').firstMatch(p);
          if (board != null) {
            final id = int.parse(board.group(1)!);
            boardsAsked.add(id);
            return _json({
              'data': [
                if (id == 1)
                  {
                    'tripId': 'ice',
                    'line': {'name': 'ICE 1000'},
                    'plannedWhen': dep.toIso8601String(),
                  },
                if (id == 2)
                  {
                    'tripId': 'rb16',
                    'line': {'name': 'RB 16'},
                    'plannedWhen': dep.toIso8601String(),
                  },
              ],
            });
          }
          if (p.endsWith('/trains/trip')) {
            return _json({
              'data': {
                'id': 9,
                'tripId': 'rb16',
                'lineName': 'RB 16',
                'stopovers': [
                  {
                    'id': 2,
                    'name': 'München Hbf Gl.27-36',
                    'departurePlanned': dep.toIso8601String(),
                  },
                  {
                    'id': 7,
                    'name': 'Ingolstadt Hbf',
                    'arrivalPlanned': dep
                        .add(const Duration(minutes: 57))
                        .toIso8601String(),
                  },
                ],
              },
            });
          }
          if (p.endsWith('/trains/checkin')) {
            checkin.addAll(json.decode(req.body) as Map<String, dynamic>);
            return _json({
              'data': {
                'status': {'id': 1},
              },
            });
          }
          return _json({'message': 'unexpected $p'}, 404);
        });

    test(
      'falls through to the split stop when the main board lacks the train',
      () async {
        final asked = <int>[];
        final body = <String, dynamic>{};
        final svc = TraewellingService(client: server(asked, body));

        await svc.checkinFromTrip(
          lineName: 'RB16',
          boardingName: 'München Hbf',
          boardingDeparture: dep,
          alightingName: 'Ingolstadt Hbf',
        );

        expect(asked, [1, 2], reason: 'exact name first, then the split stop');
        expect(body['tripId'], 'rb16');
        expect(body['start'], 2);
        expect(body['destination'], 7);
      },
    );
  });
}
