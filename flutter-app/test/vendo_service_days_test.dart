import 'dart:convert';

import 'package:besser_bahn/models/journey.dart';
import 'package:besser_bahn/services/vendo_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// serviceDays shapes captured live from /mob/angebote/fahrplan (#20, point 8).
String _body(Map<String, dynamic>? serviceDay) => json.encode({
      'verbindungen': [
        {
          'verbindung': {
            'kontext': 'ctx',
            if (serviceDay != null) 'serviceDays': [serviceDay],
            'verbindungsAbschnitte': [
              {
                'typ': 'FAHRZEUG',
                'kurztext': 'ICE',
                'abgangsOrt': {'name': 'Köln Hbf', 'evaNr': '8000207'},
                'ankunftsOrt': {'name': 'München Hbf', 'evaNr': '8000261'},
                'abgangsDatum': '2026-07-18T09:00:00+02:00',
                'ankunftsDatum': '2026-07-18T13:30:00+02:00',
                'halte': const [],
              }
            ],
          }
        }
      ]
    });

Future<Journey> _parse(Map<String, dynamic>? serviceDay) async {
  final svc = VendoService(client: MockClient((_) async =>
      http.Response.bytes(utf8.encode(_body(serviceDay)), 200)));
  final res = await svc.searchJourneys(
      fromLocationId: 'A=1@L=8000207@', toLocationId: 'A=1@L=8000261@');
  return res.journeys.single;
}

void main() {
  group('serviceDays (#20, point 8)', () {
    test('reads the irregular text DB actually sends', () async {
      final j = await _parse(const {
        'irregular': 'nicht 20. Jul bis 11. Sep 2026',
        'regular': 'täglich',
        'wochentage': ['SA', 'SO'],
        'planungsZeitraumAnfang': '2025-12-14',
        'planungsZeitraumEnde': '2026-12-12',
      });
      expect(j.serviceDaysNote, 'nicht 20. Jul bis 11. Sep 2026');
    });

    test('keeps a period-with-exceptions string whole', () async {
      // Mixed display string — passed through, never parsed into dates.
      const text = '16. Jul bis 30. Okt 2026; nicht 22. Aug bis 4. Sep 2026, '
          '26. bis 28. Sep 2026';
      final j = await _parse(const {'irregular': text, 'regular': 'nicht täglich'});
      expect(j.serviceDaysNote, text);
    });

    test('ignores regular/wochentage, which contradict each other', () async {
      // Live: regular "täglich" sitting next to wochentage [SA, SO] on one
      // object. Rendering either would state something DB doesn't mean.
      final j = await _parse(const {
        'regular': 'täglich',
        'wochentage': ['SA', 'SO'],
      });
      expect(j.serviceDaysNote, isNull);
    });

    test('no serviceDays, empty text and the textDefault placeholder', () async {
      expect((await _parse(null)).serviceDaysNote, isNull);
      expect((await _parse(const {'irregular': '  '})).serviceDaysNote, isNull);
      expect((await _parse(const {'irregular': 'textDefault'})).serviceDaysNote,
          isNull);
    });

    test('survives a round-trip through JSON', () async {
      final j = await _parse(const {'irregular': 'nicht 2. Aug'});
      expect(Journey.fromJson(j.toJson()).serviceDaysNote, 'nicht 2. Aug');
    });
  });
}
