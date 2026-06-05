import 'package:besser_bahn/services/vendo_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// A train leg of a vendo `verbindung`, with [halte] passed through verbatim so
/// each test can drop an `ersatzhaltNotiz` onto whichever stop it wants.
Map<String, dynamic> _leg(List<Map<String, dynamic>> halte) => {
      'typ': 'FAHRZEUG',
      'mitteltext': 'RE 7',
      'zugNummer': '11281',
      'produktGattung': 'RB',
      'abgangsOrt': {'evaNr': '8000199', 'name': 'Kiel Hbf'},
      'ankunftsOrt': {'evaNr': '8002549', 'name': 'Hamburg Hbf'},
      'abgangsDatum': '2026-06-05T15:37:00+02:00',
      'ankunftsDatum': '2026-06-05T16:51:00+02:00',
      'halte': halte,
    };

Map<String, dynamic> _halt(String name, {bool cancelled = false}) => {
      'ort': {'evaNr': name, 'name': name},
      'ankunftsDatum': '2026-06-05T15:40:00+02:00',
      'abgangsDatum': '2026-06-05T15:42:00+02:00',
      if (cancelled)
        'ersatzhaltNotiz': {'text': 'Halt entfällt', 'typ': 'GECANCELT'},
    };

Map<String, dynamic> _conn(Map<String, dynamic> leg) => {
      'verbindung': {
        'verbindungsAbschnitte': [leg],
      },
    };

void main() {
  final svc = VendoService();

  test('no ersatzhaltNotiz → nothing cancelled', () {
    final j = svc.parseConnection(_conn(_leg([
      _halt('Kiel Hbf'),
      _halt('Bordesholm'),
      _halt('Hamburg Hbf'),
    ])));
    expect(j.legs.single.cancelled, isFalse);
    expect(j.legs.single.partiallyCancelled, isFalse);
    expect(j.hasCancelledLeg, isFalse);
    expect(j.hasPartialCancellation, isFalse);
  });

  test('boarding stop GECANCELT → whole leg cancelled', () {
    final j = svc.parseConnection(_conn(_leg([
      _halt('Kiel Hbf', cancelled: true),
      _halt('Bordesholm'),
      _halt('Hamburg Hbf'),
    ])));
    expect(j.legs.single.cancelled, isTrue);
    expect(j.legs.single.stopovers.first.cancelled, isTrue);
    expect(j.hasCancelledLeg, isTrue);
    expect(j.hasPartialCancellation, isFalse);
  });

  test('alighting stop GECANCELT → whole leg cancelled', () {
    final j = svc.parseConnection(_conn(_leg([
      _halt('Kiel Hbf'),
      _halt('Bordesholm'),
      _halt('Hamburg Hbf', cancelled: true),
    ])));
    expect(j.legs.single.cancelled, isTrue);
    expect(j.hasCancelledLeg, isTrue);
  });

  test('intermediate stop GECANCELT → Teilausfall, leg still usable', () {
    final j = svc.parseConnection(_conn(_leg([
      _halt('Kiel Hbf'),
      _halt('Bordesholm', cancelled: true),
      _halt('Hamburg Hbf'),
    ])));
    expect(j.legs.single.cancelled, isFalse);
    expect(j.legs.single.partiallyCancelled, isTrue);
    expect(j.hasCancelledLeg, isFalse);
    expect(j.hasPartialCancellation, isTrue);
  });
}
