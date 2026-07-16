import 'dart:convert';

import 'package:besser_bahn/models/departure.dart';
import 'package:besser_bahn/models/journey.dart';
import 'package:besser_bahn/models/station.dart';
import 'package:besser_bahn/models/transfer_profile.dart';
import 'package:besser_bahn/services/earlier_alight_service.dart';
import 'package:besser_bahn/services/vendo_service.dart';
import 'package:besser_bahn/utils/earlier_alight.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// The search-load half of rescue option B (#26).
///
/// The issue's own warning: "pro früherem Halt eine Suche. Halte sinnvoll
/// begrenzen … und Ergebnisse cachen." The /mob backend answers a burst with
/// ~4 minutes of 429s (project_vendo_rate_limit), so the request budget is a
/// correctness property, not an optimisation — these tests count the requests.

Station _st(String id, String name) =>
    Station(id: id, name: name, locationId: 'A=1@L=$id@');

DateTime _at(int h, int m) => DateTime(2026, 7, 16, h, m);

String _iso(DateTime t) => t.toIso8601String();

/// One vendo `/angebote/fahrplan` answer: a single direct RE to Berlin.
String _searchBody({required DateTime dep, required DateTime arr}) =>
    json.encode({
      'verbindungen': [
        {
          'verbindung': {
            'verbindungsAbschnitte': [
              {
                'typ': 'FAHRZEUG',
                'zuglaufId': 'rescue-trip',
                'abgangsOrt': {'evaNr': '8000085', 'name': 'Fulda'},
                'ankunftsOrt': {'evaNr': '8011160', 'name': 'Berlin Hbf'},
                'abgangsDatum': _iso(dep),
                'ankunftsDatum': _iso(arr),
                'mitteltext': 'RE 50',
                'kurztext': 'RE',
                'zugNummer': '50',
                'produktGattung': 'REGIONALZUG',
                'halte': [
                  {
                    'ort': {'evaNr': '8000085', 'name': 'Fulda'},
                    'abgangsDatum': _iso(dep),
                  },
                  {
                    'ort': {'evaNr': '8011160', 'name': 'Berlin Hbf'},
                    'ankunftsDatum': _iso(arr),
                  },
                ],
              }
            ]
          }
        }
      ]
    });

JourneyLeg _leg({
  required Station from,
  required Station to,
  required DateTime dep,
  required DateTime arr,
  String tripId = 'ridden',
  List<LegStopover> stops = const [],
}) =>
    JourneyLeg(
      tripId: tripId,
      origin: from,
      destination: to,
      departure: dep,
      plannedDeparture: dep,
      arrival: arr,
      plannedArrival: arr,
      line: const TransitLine(
          name: 'ICE 599',
          fahrtNr: '599',
          productName: 'ICE',
          product: 'nationalExpress'),
      stopovers: stops,
    );

void main() {
  final hamburg = _st('8002549', 'Hamburg Hbf');
  final kassel = _st('8003200', 'Kassel-Wilhelmshöhe');
  final fulda = _st('8000085', 'Fulda');
  final hannover = _st('8000152', 'Hannover Hbf');
  final frankfurt = _st('8000105', 'Frankfurt(Main)Hbf');
  final berlin = _st('8011160', 'Berlin Hbf');

  /// Ridden train: Hamburg → Frankfurt, change there. Three earlier stops are
  /// still ahead of the rider at 10:00.
  List<AlightStop> stops() => [
        AlightStop(station: hamburg, arrival: _at(9, 0)),
        AlightStop(station: hannover, arrival: _at(10, 30)),
        AlightStop(station: kassel, arrival: _at(11, 0)),
        AlightStop(station: fulda, arrival: _at(11, 40)),
        AlightStop(station: frankfurt, arrival: _at(12, 30)),
      ];

  final ridden = _leg(from: hamburg, to: frankfurt, dep: _at(9, 0), arr: _at(12, 30));
  final onward = _leg(
      from: frankfurt,
      to: berlin,
      dep: _at(12, 35),
      arr: _at(16, 0),
      tripId: 'planned-onward');
  final booked = Journey(legs: [ridden, onward]);

  Future<EarlierAlightResult> run(
    EarlierAlightService svc, {
    DateTime? now,
  }) =>
      svc.findOptions(
        currentLeg: ridden,
        onwardLeg: onward,
        original: booked,
        destination: berlin,
        stops: stops(),
        readyAt: _at(12, 30),
        profile: TransferProfile.normal,
        hasDeutschlandTicket: false,
        reisende: const [],
        firstClass: false,
        apiDelayMs: 0,
        now: now ?? _at(10, 0),
      );

  test('one search per candidate stop, plus one for the baseline', () async {
    var calls = 0;
    final svc = EarlierAlightService(VendoService(client: MockClient((_) async {
      calls++;
      return http.Response.bytes(
          utf8.encode(_searchBody(dep: _at(13, 0), arr: _at(15, 0))), 200);
    })));

    await run(svc);

    // 3 reachable earlier stops (Hannover, Kassel, Fulda) + the fallback.
    expect(calls, 4);
  });

  test('the fan-out is capped even on a train with many stops', () async {
    var calls = 0;
    final svc = EarlierAlightService(VendoService(client: MockClient((_) async {
      calls++;
      return http.Response.bytes(
          utf8.encode(_searchBody(dep: _at(13, 0), arr: _at(15, 0))), 200);
    })));

    await svc.findOptions(
      currentLeg: ridden,
      onwardLeg: onward,
      original: booked,
      destination: berlin,
      stops: [
        AlightStop(station: hamburg, arrival: _at(9, 0)),
        for (var i = 0; i < 20; i++)
          AlightStop(station: _st('s$i', 'Halt $i'), arrival: _at(10, i * 3)),
        AlightStop(station: frankfurt, arrival: _at(12, 30)),
      ],
      readyAt: _at(12, 30),
      profile: TransferProfile.normal,
      hasDeutschlandTicket: false,
      reisende: const [],
      firstClass: false,
      apiDelayMs: 0,
      now: _at(9, 30),
    );

    expect(calls, lessThanOrEqualTo(EarlierAlightService.maxCandidates + 1),
        reason: '20 stops must not become 21 requests');
  });

  test('a second run is served from the cache — a live refresh costs nothing',
      () async {
    var calls = 0;
    final svc = EarlierAlightService(VendoService(client: MockClient((_) async {
      calls++;
      return http.Response.bytes(
          utf8.encode(_searchBody(dep: _at(13, 0), arr: _at(15, 0))), 200);
    })));

    await run(svc);
    final first = calls;
    await run(svc);

    expect(calls, first, reason: 'the connection screen rebuilds this on every '
        'live refresh; it must not re-run the fan-out');
  });

  test('nothing reachable to get off at → not even the baseline is spent',
      () async {
    var calls = 0;
    final svc = EarlierAlightService(VendoService(client: MockClient((_) async {
      calls++;
      return http.Response.bytes(
          utf8.encode(_searchBody(dep: _at(13, 0), arr: _at(15, 0))), 200);
    })));

    // 12:29 — every earlier stop is behind the train already.
    final res = await run(svc, now: _at(12, 29));

    expect(calls, 0);
    expect(res.options, isEmpty);
  });

  test('a rescue that beats the fallback surfaces, with its ticket note',
      () async {
    // Fallback from Frankfurt arrives 15:00; from Fulda you'd be there 14:00.
    final svc = EarlierAlightService(VendoService(client: MockClient((req) async {
      final body = json.decode(req.body) as Map<String, dynamic>;
      final from = (body['reiseHin']['wunsch']['abgangsLocationId']) as String;
      final fromFrankfurt = from.contains('8000105');
      return http.Response.bytes(
          utf8.encode(_searchBody(
            dep: fromFrankfurt ? _at(12, 45) : _at(11, 55),
            arr: fromFrankfurt ? _at(15, 0) : _at(14, 0),
          )),
          200);
    })));

    final res = await run(svc);

    expect(res.fallback?.arrival, _at(15, 0));
    expect(res.options, isNotEmpty);
    final best = res.options.first;
    expect(best.arrival, _at(14, 0));
    expect(best.gainMinutes, 60);
    // Never silently omitted: the rider may hold a train-bound Sparpreis.
    expect(best.ticketNote, AlightTicketNote.mayBeTrainBound);
  });

  test('a 429 aborts the fan-out instead of hammering a limited backend',
      () async {
    var calls = 0;
    final svc = EarlierAlightService(VendoService(client: MockClient((_) async {
      calls++;
      // The baseline lands, then the backend cuts us off.
      if (calls == 1) {
        return http.Response.bytes(
            utf8.encode(_searchBody(dep: _at(12, 45), arr: _at(15, 0))), 200);
      }
      return http.Response(
          json.encode({'domain': 'MOB', 'code': 'RETRY'}), 429);
    })));

    final res = await run(svc);

    // Baseline + the one rejected search, then stop. Asking the other two
    // stops anyway would extend the block for the whole app.
    expect(calls, 2);
    expect(res.fallback, isNotNull);
    expect(res.options, isEmpty);
    // …and it must not pass that off as "we looked, nothing helps".
    expect(res.complete, isFalse);
  });

  test('an empty answer only means "nothing helps" when we really looked',
      () async {
    // Everything searched, nothing beats the fallback → a real, complete "no".
    final svc = EarlierAlightService(VendoService(client: MockClient((_) async {
      return http.Response.bytes(
          utf8.encode(_searchBody(dep: _at(12, 45), arr: _at(15, 0))), 200);
    })));

    final res = await run(svc);

    expect(res.options, isEmpty);
    expect(res.complete, isTrue);
  });

  test('a failed baseline is not cached — a later retry may still work',
      () async {
    var calls = 0;
    final svc = EarlierAlightService(VendoService(client: MockClient((req) async {
      calls++;
      if (calls == 1) {
        return http.Response(
            json.encode({'domain': 'MOB', 'code': 'RETRY'}), 429);
      }
      final body = json.decode(req.body) as Map<String, dynamic>;
      final from = (body['reiseHin']['wunsch']['abgangsLocationId']) as String;
      final fromFrankfurt = from.contains('8000105');
      return http.Response.bytes(
          utf8.encode(_searchBody(
            dep: fromFrankfurt ? _at(12, 45) : _at(11, 55),
            arr: fromFrankfurt ? _at(15, 0) : _at(14, 0),
          )),
          200);
    })));

    expect((await run(svc)).options, isEmpty);
    // Second attempt gets through and finds the rescue.
    expect((await run(svc)).options, isNotEmpty);
  });

  test('no fallback to compare against → no suggestions invented', () async {
    final svc = EarlierAlightService(VendoService(client: MockClient((_) async {
      return http.Response.bytes(
          utf8.encode(json.encode({'verbindungen': []})), 200);
    })));

    final res = await run(svc);

    expect(res.fallback, isNull);
    expect(res.options, isEmpty);
  });
}
