import 'package:besser_bahn/models/journey.dart';
import 'package:besser_bahn/services/vendo_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Shapes mirror live `/mob/angebote/fahrplan` connections.
Map<String, dynamic> _conn({
  Map<String, dynamic>? topNotiz,
  List<Map<String, dynamic>>? echtzeitNotizen,
  List<Map<String, dynamic>>? himNotizen,
}) =>
    {
      'verbindung': {
        'kontext': 'ctx-1',
        if (topNotiz != null) 'topNotiz': topNotiz,
        if (echtzeitNotizen != null) 'echtzeitNotizen': echtzeitNotizen,
        if (himNotizen != null) 'himNotizen': himNotizen,
        'verbindungsAbschnitte': [
          {
            'typ': 'FAHRZEUG',
            'mitteltext': 'ICE 947',
            'kurztext': 'ICE',
            'produktGattung': 'ICE',
            'abgangsOrt': {'evaNr': '8000207', 'name': 'Köln Hbf'},
            'ankunftsOrt': {'evaNr': '8011160', 'name': 'Berlin Hbf'},
            'abgangsDatum': '2026-07-15T20:44:00+02:00',
            'ankunftsDatum': '2026-07-16T00:17:00+02:00',
            'halte': [],
          }
        ],
      }
    };

void main() {
  group('connection-level notes (#20)', () {
    final svc = VendoService();

    test('the connection note reaches the journey', () {
      // The live case: the leg carries no notes at all, and this is the only
      // place that says the train stops short of Berlin Hbf.
      final j = svc.parseConnection(_conn(echtzeitNotizen: [
        {
          'prio': 'HOCH',
          'text': 'Der Zielhalt Berlin Hbf entfällt. '
              'Ausstieg in Berlin-Spandau möglich.'
        }
      ]));

      expect(j.disruptions, hasLength(1));
      expect(j.disruptions.first, contains('Berlin-Spandau'));
      expect(j.legs.first.disruptions, isEmpty,
          reason: 'proves the leg was not the source');
    });

    test('the "textDefault" placeholder never reaches the UI', () {
      // 11 of 15 live connections carry exactly this as topNotiz.
      final j = svc.parseConnection(_conn(
        topNotiz: {'prio': 'NORMAL', 'text': 'textDefault'},
        echtzeitNotizen: [
          {'prio': 'NORMAL', 'text': 'textDefault'}
        ],
      ));
      expect(j.disruptions, isEmpty);
    });

    test('him and realtime notes are merged, deduped', () {
      final j = svc.parseConnection(_conn(
        himNotizen: [
          {'text': 'Bauarbeiten'}
        ],
        echtzeitNotizen: [
          {'text': 'Bauarbeiten'},
          {'text': 'Verbindung fällt aus'},
        ],
      ));
      expect(j.disruptions, ['Bauarbeiten', 'Verbindung fällt aus']);
    });

    test('an undisturbed connection has none', () {
      expect(svc.parseConnection(_conn()).disruptions, isEmpty);
    });
  });

  group('ersatzAnkunftsHalt — train ends early (#20)', () {
    final svc = VendoService();

    /// The live ICE 947 shape: ankunftsOrt still says Berlin Hbf 00:17 while
    /// the run really terminates at Berlin-Spandau 00:04 on platform 5.
    Map<String, dynamic> connEndingEarly() {
      final c = _conn();
      final leg = (c['verbindung']
          as Map<String, dynamic>)['verbindungsAbschnitte'] as List;
      (leg.first as Map<String, dynamic>)['ersatzZielhaltIndex'] = 4;
      (leg.first as Map<String, dynamic>)['ersatzAnkunftsHalt'] = {
        'ankunftsDatum': '2026-07-16T00:04:00+02:00',
        'abgangsDatum': '2026-07-16T00:06:00+02:00',
        'gleis': '5',
        'ort': {'evaNr': '8010404', 'name': 'Berlin-Spandau'},
      };
      return c;
    }

    test('the real terminus is parsed out', () {
      final leg = svc.parseConnection(connEndingEarly()).legs.first;

      expect(leg.endsEarly, isTrue);
      expect(leg.replacementDestination?.name, 'Berlin-Spandau');
      expect(leg.replacementArrival?.hour, 0);
      expect(leg.replacementArrival?.minute, 4);
      expect(leg.replacementArrivalPlatform, '5');
    });

    test('the planned destination is kept, not overwritten', () {
      // The rider searched for Berlin Hbf — they need to see that the train
      // changed, not their search.
      final leg = svc.parseConnection(connEndingEarly()).legs.first;

      expect(leg.destination.name, 'Berlin Hbf');
      expect(leg.arrival?.hour, 0);
      expect(leg.arrival?.minute, 17);
    });

    test('an ordinary leg ends nowhere early', () {
      final leg = svc.parseConnection(_conn()).legs.first;
      expect(leg.endsEarly, isFalse);
      expect(leg.replacementDestination, isNull);
    });

    test('survives a save/load round trip', () {
      // Saved journeys go through toJson/fromJson — dropping the field there
      // would lose the warning on exactly the trip the rider bookmarked.
      final leg = svc.parseConnection(connEndingEarly()).legs.first;
      final back = JourneyLeg.fromJson(leg.toJson());

      expect(back.replacementDestination?.name, 'Berlin-Spandau');
      expect(back.replacementArrivalPlatform, '5');
      expect(back.endsEarly, isTrue);
    });
  });

  group('occupancy per class (#20)', () {
    final svc = VendoService();

    /// Live shape: both classes are always present.
    Map<String, dynamic> connWithLoad(
        {int? first = 2, int? second = 3}) {
      final c = _conn();
      final legs = (c['verbindung']
          as Map<String, dynamic>)['verbindungsAbschnitte'] as List;
      (legs.first as Map<String, dynamic>)['auslastungsInfos'] = [
        if (first != null)
          {
            'klasse': 'KLASSE_1',
            'stufe': first,
            'anzeigeTextKurz': 'Mittlere Auslastung erwartet'
          },
        if (second != null) {'klasse': 'KLASSE_2', 'stufe': second},
      ];
      return c;
    }

    test('a first-class search reads the first-class load', () {
      // This read KLASSE_2 unconditionally, so a first-class rider never saw
      // any occupancy — despite KLASSE_1 being present on every entry probed.
      final leg =
          svc.parseConnection(connWithLoad(), firstClass: true).legs.first;
      expect(leg.occupancy?.level, OccupancyLevel.medium);
    });

    test('a second-class search is unchanged', () {
      final leg = svc.parseConnection(connWithLoad()).legs.first;
      expect(leg.occupancy?.level, OccupancyLevel.high);
    });

    test('falls back to the other class rather than showing nothing', () {
      final leg = svc
          .parseConnection(connWithLoad(first: null), firstClass: true)
          .legs
          .first;
      expect(leg.occupancy?.level, OccupancyLevel.high);
    });

    test('no occupancy at all stays null', () {
      expect(svc.parseConnection(_conn()).legs.first.occupancy, isNull);
    });
  });
}
