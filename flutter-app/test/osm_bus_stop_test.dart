import 'package:besser_bahn/services/osm_bus_stop_service.dart';
import 'package:besser_bahn/services/transit_stop_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

/// Real Overpass shape for Gravelottestraße, Kiel (#55): four poles, two of
/// them signed A and B. Note OSM spells the stop "Gravelottestraße" while the
/// timetable says "Gravelottestraße, Kiel".
Map<String, dynamic> _gravelotte() => {
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
        // Another stop 400 m down the road — outside the radius, must not show.
        {
          'type': 'node',
          'id': 999,
          'lat': 54.3285,
          'lon': 10.1180,
          'tags': {'highway': 'bus_stop', 'name': 'Wilhelmplatz'},
        },
        {
          'type': 'relation',
          'id': 1,
          'tags': {
            'type': 'route',
            'route': 'bus',
            'ref': '14',
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

/// The timetable coordinate of the stop, i.e. what DB hands us.
const _center = LatLng(54.325005, 10.113323);

void main() {
  group('#55 — OSM poles (the signed bay codes)', () {
    test('every pole of the stop is found, the next stop is not', () {
      final poles = OsmBusStopService.parseResponse(_gravelotte(), _center);
      expect(poles, hasLength(3));
      expect(poles.map((p) => p.name).toSet(), {'Gravelottestraße'});
    });

    test('poles are selected by distance, not by name', () {
      // The name was the first implementation and it does not survive contact
      // with reality: DB says "ZOB, Kiel" where OSM says "Kiel ZOB", and
      // "Wittenberger Passau B202, Martensrade" where OSM says "Wittenberger
      // Passau, B202" — both matched nothing and those stops got no map at all.
      final renamed = _gravelotte();
      for (final e in renamed['elements'] as List) {
        final tags = (e as Map)['tags'] as Map?;
        if (tags != null && tags['name'] == 'Gravelottestraße') {
          tags['name'] = 'Kiel Gravelottestr.';
        }
      }
      expect(OsmBusStopService.parseResponse(renamed, _center), hasLength(3));
    });

    test('bay codes come through in order — they are DB\'s Gleis', () {
      final poles = OsmBusStopService.parseResponse(_gravelotte(), _center);
      expect(poles.map((p) => p.bay).toList(), ['A', 'B', null]);
      expect(poles.first.label, 'A');
    });

    test('each pole gets the directions of the routes calling THERE', () {
      final poles = OsmBusStopService.parseResponse(_gravelotte(), _center);
      final a = poles.firstWhere((p) => p.bay == 'A');
      final b = poles.firstWhere((p) => p.bay == 'B');
      expect(a.directions, ['14 → Laboe, Hafen'],
          reason: 'the opposite direction belongs to the other pole');
      expect(b.directions, ['14 → Roskilder Weg']);
      expect(a.directionLabel, 'Richtung 14 → Laboe, Hafen');
    });

    test('a pole no route names stays direction-less rather than guessing', () {
      final poles = OsmBusStopService.parseResponse(_gravelotte(), _center);
      final plain = poles.firstWhere((p) => p.bay == null);
      expect(plain.directions, isEmpty);
      expect(plain.directionLabel, isNull);
      expect(plain.label, 'Gravelottestraße');
    });

    test('junk in, empty list out', () {
      expect(OsmBusStopService.parseResponse('nope', _center), isEmpty);
      expect(
          OsmBusStopService.parseResponse({'elements': 'nope'}, _center),
          isEmpty);
    });
  });

  group('#55 — DELFI poles (the complete set + directions)', () {
    test('the bay code is read out of the DELFI stop id', () {
      expect(TransitStopService.trackOf('de-DELFI_de:01002:49076::D2'), 'D2');
      expect(TransitStopService.trackOf('de-DELFI_de:01002:49079'), isNull);
    });

    test('departures are grouped per pole, line and destination together', () {
      final directions = TransitStopService.parseStopTimes({
        'stopTimes': [
          {
            'place': {'stopId': 'x::1', 'name': 'Kiel Gravelottestraße'},
            'routeShortName': '14',
            'headsign': 'Laboe',
          },
          {
            'place': {'stopId': 'x::1', 'name': 'Kiel Gravelottestraße'},
            'routeShortName': '15',
            'headsign': 'Heikendorf',
          },
          // Same line and direction again — one entry, not two.
          {
            'place': {'stopId': 'x::1', 'name': 'Kiel Gravelottestraße'},
            'routeShortName': '14',
            'headsign': 'Laboe',
          },
          {
            'place': {'stopId': 'x::2', 'name': 'Kiel Gravelottestraße'},
            'routeShortName': '14',
            'headsign': 'Mettenhof',
          },
          // No headsign — nothing to say, skipped.
          {
            'place': {'stopId': 'x::2', 'name': 'Kiel Gravelottestraße'},
            'routeShortName': '99',
          },
        ],
      });
      expect(directions['x::1'], ['14 → Laboe', '15 → Heikendorf']);
      expect(directions['x::2'], ['14 → Mettenhof']);
    });

    test('junk in, empty map out', () {
      expect(TransitStopService.parseStopTimes(null), isEmpty);
      expect(TransitStopService.parseStopTimes({'stopTimes': 5}), isEmpty);
    });
  });
}
