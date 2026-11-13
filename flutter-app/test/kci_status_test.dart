import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:besser_bahn/models/db_ticket.dart';

/// Shape of `GET /mob/kcistatus/ticketreferenz/{ref}/verbindung/{trip}` as DB
/// returned it on 2026-11-13 (ids replaced). Note the key typo
/// `verbindnungsabschnittsNummer` — it is DB's, not ours.
const _status = '''
{"kciTicketRefId":"ABCDEF12","kciVerbindungsAbschnittListe":[
 {"kciFaehig":false,"kontrollStatus":"nicht_kontrolliert","plaetze":[],"reserviertePlaetze":[],"umcheckenMoeglich":false,"umplatziert":false,"verbindnungsabschnittsNummer":0},
 {"kciFaehig":true,"kontrollStatus":"nicht_kontrolliert","plaetze":[],"reserviertePlaetze":[{"platznummer":"76","wagennummer":"5"}],"umcheckenMoeglich":false,"umplatziert":false,"verbindnungsabschnittsNummer":1,"moeglichAb":"2026-11-13T15:13:00Z"},
 {"kciFaehig":false,"kontrollStatus":"eingecheckt","plaetze":[{"platznummer":"12","wagennummer":"7"}],"reserviertePlaetze":[],"umcheckenMoeglich":true,"umplatziert":false,"verbindnungsabschnittsNummer":2,"checkinId":"c-1"}
],"stichprobe":false,"tripUUID":"00000000-0000-4000-8000-000000000002"}
''';

void main() {
  final s = DbKciStatus.fromJson(json.decode(_status) as Map<String, dynamic>);

  test('a checked-in section stays listed although DB says kciFaehig false', () {
    expect(s.abschnitte[2].kciFaehig, isFalse);
    expect(s.faehig.map((a) => a.nummer), contains(2));
  });

  test('parses sections, seats and the typo key', () {
    expect(s.kciTicketRefId, 'ABCDEF12');
    expect(s.abschnitte.map((a) => a.nummer), [0, 1, 2]);
    expect(s.faehig.map((a) => a.nummer), [1, 2]);
    expect(s.abschnitte[1].reserviertePlaetze.single.label, 'Wagen 5, Platz 76');
    expect(s.abschnitte[2].checkinId, 'c-1');
  });

  test('check-in opens at moeglichAb and not when already in', () {
    final a = s.abschnitte[1];
    expect(a.canCheckIn(DateTime.utc(2026, 11, 13, 15, 12)), isFalse);
    expect(a.canCheckIn(DateTime.utc(2026, 11, 13, 15, 13)), isTrue);
    expect(s.abschnitte[2].eingecheckt, isTrue);
    expect(s.abschnitte[2].canCheckIn(DateTime.utc(2026, 11, 13, 16)), isFalse);
    expect(s.abschnitte[0].canCheckIn(DateTime.utc(2026, 11, 13, 16)), isFalse);
  });

  test('a seat serialises with DB key names', () {
    expect(
      const DbKciPlatz(wagennummer: '5', platznummer: '76').toJson(),
      {'wagennummer': '5', 'platznummer': '76'},
    );
  });
}
