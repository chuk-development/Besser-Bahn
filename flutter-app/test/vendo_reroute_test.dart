import 'dart:convert';

import 'package:besser_bahn/services/vendo_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Shapes below mirror live `/mob/zuglauf/{id}` responses: realtime notes carry
/// only `text` (no `typ`), `istZusatzhalt` sits on every halt, and a dropped
/// stop is an `ersatzhaltNotiz` of typ GECANCELT.
Map<String, dynamic> _halt(
  String name, {
  bool zusatz = false,
  bool cancelled = false,
  List<Map<String, String>>? echtzeitNotizen,
}) =>
    {
      'ort': {'evaNr': name, 'name': name},
      'ankunftsDatum': '2026-07-14T11:38:00+02:00',
      'abgangsDatum': '2026-07-14T11:40:00+02:00',
      'gleis': '7',
      'istZusatzhalt': zusatz,
      if (cancelled)
        'ersatzhaltNotiz': {'text': 'Halt entfällt', 'typ': 'GECANCELT'},
      if (echtzeitNotizen != null) 'echtzeitNotizen': echtzeitNotizen,
    };

Future<dynamic> _trip(Map<String, dynamic> body) {
  final svc = VendoService(client: MockClient((_) async =>
      http.Response.bytes(utf8.encode(json.encode(body)), 200)));
  return svc.getTrip('2|#VN#1#ST#1');
}

void main() {
  group('zuglauf diversion parsing (#17)', () {
    test('himNotizen and echtzeitNotizen land in disruptions', () async {
      final trip = await _trip({
        'mitteltext': 'ICE 844',
        'himNotizen': [
          {'text': 'Die Strecke ist zwischen Berlin-Spandau und Wolfsburg '
              'gesperrt.'}
        ],
        'echtzeitNotizen': [
          {'text': 'Verspätung aus vorheriger Fahrt'}
        ],
        'halte': [_halt('Berlin Hbf'), _halt('Hannover Hbf')],
      });

      expect(trip.disruptions, hasLength(2));
      expect(trip.disruptions.first, contains('gesperrt'));
      expect(trip.disruptions, contains('Verspätung aus vorheriger Fahrt'));
    });

    test('attributNotizen stay out of disruptions (amenities, not faults)',
        () async {
      final trip = await _trip({
        'mitteltext': 'ICE 844',
        'attributNotizen': [
          {'key': 'WLAN', 'text': 'WLAN verfügbar'}
        ],
        'halte': [_halt('Berlin Hbf'), _halt('Hannover Hbf')],
      });

      expect(trip.disruptions, isEmpty);
      expect(trip.attributes, isNotEmpty);
    });

    test('a note naming an Umleitung marks the run rerouted', () async {
      final trip = await _trip({
        'mitteltext': 'ICE 844',
        'echtzeitNotizen': [
          {'text': 'Umleitung über Magdeburg'}
        ],
        'halte': [_halt('Berlin Hbf'), _halt('Hannover Hbf')],
      });

      expect(trip.isRerouted, isTrue);
    });

    test('an added stop marks the run rerouted even with no note', () async {
      final trip = await _trip({
        'mitteltext': 'ICE 844',
        'halte': [
          _halt('Berlin Hbf'),
          _halt('Magdeburg Hbf', zusatz: true),
          _halt('Hannover Hbf'),
        ],
      });

      expect(trip.isRerouted, isTrue);
      expect(trip.additionalStops.map((s) => s.stop.name), ['Magdeburg Hbf']);
    });

    test('added and dropped stops are reported separately', () async {
      final trip = await _trip({
        'mitteltext': 'ICE 844',
        'halte': [
          _halt('Berlin Hbf'),
          _halt('Magdeburg Hbf', zusatz: true),
          _halt('Wolfsburg Hbf', cancelled: true),
          _halt('Hannover Hbf'),
        ],
      });

      expect(trip.additionalStops.map((s) => s.stop.name), ['Magdeburg Hbf']);
      expect(trip.cancelledStops.map((s) => s.stop.name), ['Wolfsburg Hbf']);
    });

    test('a plain delay is NOT a diversion', () async {
      final trip = await _trip({
        'mitteltext': 'ICE 844',
        'echtzeitNotizen': [
          {'text': 'Verspätung aus vorheriger Fahrt'}
        ],
        'halte': [_halt('Berlin Hbf'), _halt('Hannover Hbf')],
      });

      expect(trip.isRerouted, isFalse,
          reason: 'delay notes must not trigger the Umleitung banner');
      expect(trip.disruptions, isNotEmpty);
    });

    test('an ordinary on-time run is neither disrupted nor rerouted', () async {
      final trip = await _trip({
        'mitteltext': 'ICE 844',
        'halte': [_halt('Berlin Hbf'), _halt('Hannover Hbf')],
      });

      expect(trip.isRerouted, isFalse);
      expect(trip.disruptions, isEmpty);
      expect(trip.additionalStops, isEmpty);
    });
  });
}
