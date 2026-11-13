import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:besser_bahn/models/db_ticket.dart';
import 'package:besser_bahn/services/db_account_service.dart';

/// One entry of `POST /mob/auftrag/{nr}/manuellLaden` →
/// `auftragsbezogeneReisen[]`. Same shape as `GET …/kundenwunsch/{id}`.
Map<String, dynamic> _entry() => {
  'reise': {
    'standardInfos': {
      'kundenwunschId': '00000000-0000-4000-8000-000000000001',
      'auftragsnummer': '990000000001',
      'status': 'GUELTIG',
      'zeitlicheGueltigkeit': {
        'ersterGeltungszeitpunkt': '2026-11-13T00:00:00+01:00',
        'letzterGeltungszeitpunkt': '2026-11-15T03:00:00+01:00',
      },
      'privaterKundenkontobezug': true,
    },
    'reiseInfos': {
      'angebotsname': 'Flexpreis Young',
      'klasse': 'KLASSE_2',
      'ticketStatus': 'GUELTIG',
      'kciTicketRefId': 'ABCDEF12',
      'ticket': {
        'ticket': base64Encode(utf8.encode('<html><body>t</body></html>')),
        'mediaTyp': 'text/html',
      },
    },
  },
};

http.Response _err(int status, Map<String, dynamic> body) => http.Response(
  json.encode(body),
  status,
  headers: {'content-type': 'application/json'},
);

void main() {
  test('a manuellLaden entry parses as a ticket', () {
    final t = DbTicket.fromJson(_entry());
    expect(t.auftragsnummer, '990000000001');
    expect(t.kundenwunschId, '00000000-0000-4000-8000-000000000001');
    expect(t.angebotsname, 'Flexpreis Young');
    expect(t.kciTicketRefId, 'ABCDEF12');
  });

  test('a manual order round-trips and lists as a manual index', () {
    final o = DbManualOrder(
      auftragsnummer: '990000000001',
      nachname: 'Muster',
      kundenwunschIds: const ['a', 'b'],
      addedAt: DateTime.utc(2026, 11, 13, 14),
    );
    final back = DbManualOrder.fromJson(
      json.decode(json.encode(o.toJson())) as Map<String, dynamic>,
    );
    expect(back.auftragsnummer, o.auftragsnummer);
    expect(back.nachname, 'Muster');
    expect(back.kundenwunschIds, ['a', 'b']);
    expect(back.addedAt, o.addedAt);
    final i = back.toIndex();
    expect(i.manual, isTrue);
    expect(i.kundenwunschIds, ['a', 'b']);
  });

  test('backend errors become user text', () {
    final notFound = DbManualOrderException.fromResponse(
      _err(404, {
        'domain': 'BUE',
        'code': 'FACHLICH',
        'details': {'typ': 'AUFTRAG_NICHT_GEFUNDEN'},
        'status': 'ERROR',
      }),
    );
    expect(notFound.typ, 'AUFTRAG_NICHT_GEFUNDEN');
    expect(notFound.message, contains('Kein Ticket gefunden'));

    final invalid = DbManualOrderException.fromResponse(
      _err(400, {'domain': 'MOB', 'code': 'VALIDIERUNG', 'status': 'ERROR'}),
    );
    expect(invalid.message, contains('ungültig'));

    final login = DbManualOrderException.fromResponse(
      _err(403, {
        'details': {'typ': 'AUFTRAG_LOGIN_REQUIRED'},
      }),
    );
    expect(login.message, contains('DB-Konto'));
  });
}
