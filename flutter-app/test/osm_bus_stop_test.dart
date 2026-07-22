import 'package:besser_bahn/services/osm_bus_stop_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Shaped exactly like a live Overpass answer for Gravelottestraße, Kiel —
/// the stop from #55: four poles, two of them lettered A and B.
Map<String, dynamic> _overpass() => {
      'elements': [
        {
          'type': 'node',
          'id': 398958539,
          'lat': 54.32508,
          'lon': 10.11283,
          'tags': {
            'highway': 'bus_stop',
            'name': 'Gravelottestraße',
            'local_ref': 'A',
            'shelter': 'yes',
          },
        },
        {
          'type': 'node',
          'id': 5901578831,
          'lat': 54.32525,
          'lon': 10.11307,
          'tags': {
            'highway': 'bus_stop',
            'name': 'Gravelottestraße',
            'local_ref': 'B',
            'shelter': 'no',
          },
        },
        {
          'type': 'node',
          'id': 412264225,
          'lat': 54.32463,
          'lon': 10.11316,
          'tags': {'highway': 'bus_stop', 'name': 'Gravelottestraße'},
        },
        // A different stop caught by the radius — must not show up.
        {
          'type': 'node',
          'id': 999,
          'lat': 54.3251,
          'lon': 10.115,
          'tags': {'highway': 'bus_stop', 'name': 'Wilhelmplatz'},
        },
        {
          'type': 'relation',
          'id': 1,
          'tags': {
            'type': 'route',
            'route': 'bus',
            'ref': '14',
            'from': 'Roskilder Weg',
            'to': 'Laboe, Hafen',
          },
          'members': [
            {'type': 'node', 'ref': 398958539, 'role': 'platform'},
            {'type': 'way', 'ref': 555, 'role': ''},
          ],
        },
        {
          'type': 'relation',
          'id': 2,
          'tags': {
            'type': 'route',
            'route': 'bus',
            'ref': '14',
            'from': 'Laboe, Hafen',
            'to': 'Roskilder Weg',
          },
          'members': [
            {'type': 'node', 'ref': 5901578831, 'role': 'platform'},
          ],
        },
        // No `to` — nothing to say about direction, must be skipped.
        {
          'type': 'relation',
          'id': 3,
          'tags': {'type': 'route', 'route': 'bus', 'ref': '81'},
          'members': [
            {'type': 'node', 'ref': 398958539, 'role': 'platform'},
          ],
        },
      ],
    };

void main() {
  group('#55 — which side of the street the bus leaves from', () {
    test('every pole of the stop is found, other stops are not', () {
      final bays =
          OsmBusStopService.parseResponse(_overpass(), 'Gravelottestraße');
      expect(bays, hasLength(3));
      expect(bays.map((b) => b.name).toSet(), {'Gravelottestraße'});
    });

    test('the timetable spelling with a town suffix still matches', () {
      // vendo calls it "Gravelottestraße, Kiel"; OSM tags only the street.
      final bays = OsmBusStopService.parseResponse(
          _overpass(), 'Gravelottestraße, Kiel');
      expect(bays, hasLength(3));
    });

    test('bay letters come through in order — they are vendo\'s "Gleis"', () {
      final bays =
          OsmBusStopService.parseResponse(_overpass(), 'Gravelottestraße');
      expect(bays.map((b) => b.bay).toList(), ['A', 'B', null]);
      expect(bays.first.label, 'A');
    });

    test('each pole gets the directions of the routes calling THERE', () {
      final bays =
          OsmBusStopService.parseResponse(_overpass(), 'Gravelottestraße');
      final a = bays.firstWhere((b) => b.bay == 'A');
      final b = bays.firstWhere((b) => b.bay == 'B');
      expect(a.directions, ['14 → Laboe, Hafen'],
          reason: 'the opposite direction belongs to the other pole');
      expect(b.directions, ['14 → Roskilder Weg']);
      expect(a.directionLabel, 'Richtung 14 → Laboe, Hafen');
    });

    test('a pole no route names stays direction-less rather than guessing', () {
      final bays =
          OsmBusStopService.parseResponse(_overpass(), 'Gravelottestraße');
      final plain = bays.firstWhere((b) => b.bay == null);
      expect(plain.directions, isEmpty);
      expect(plain.directionLabel, isNull);
      expect(plain.label, 'Gravelottestraße');
    });

    test('junk in, empty list out', () {
      expect(OsmBusStopService.parseResponse('nope', 'X'), isEmpty);
      expect(OsmBusStopService.parseResponse({'elements': 'nope'}, 'X'),
          isEmpty);
      expect(OsmBusStopService.parseResponse(_overpass(), 'Anderswo'), isEmpty);
    });
  });
}
