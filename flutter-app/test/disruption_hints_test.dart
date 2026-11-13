import 'package:besser_bahn/models/departure.dart' show TransitLine;
import 'package:besser_bahn/models/journey.dart';
import 'package:besser_bahn/models/station.dart';
import 'package:besser_bahn/screens/connection_search/connection_detail_screen.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('replacement bus from DB notes (2026-11-13, RE2)', () {
    test('per-train note', () {
      final s = replacementBusSection([
        'Für 82835 verkehrt Ersatzfahrt Bus RE2 zwischen Banteln und Alfeld(Leine)',
      ]);
      expect(s?.from, 'Banteln');
      expect(s?.to, 'Alfeld (Leine)');
    });
    test('line note', () {
      final s = replacementBusSection([
        'Aufgrund einer Streckensperrung zwischen Alfeld (Leine) und Banteln '
            'ist zur Zeit kein Zugverkehr möglich. Ein Ersatzverkehr mit '
            'Bussen ist für Sie zwischen Alfeld (Leine) und Banteln '
            'eingerichtet. Bitte prüfen Sie regelmäßig Ihre Reiseverbindung.',
      ]);
      expect(s?.from, 'Alfeld (Leine)');
      expect(s?.to, 'Banteln');
    });
    test('no replacement → null', () {
      expect(replacementBusSection(['Halt entfällt']), isNull);
    });
  });

  test('following an alternative keeps the legs already ridden', () {
    const kiel = Station(id: '1', name: 'Kiel Hbf', locationId: 'A=1@L=1@');
    const han = Station(id: '2', name: 'Hannover Hbf', locationId: 'A=1@L=2@');
    const goe = Station(id: '3', name: 'Göttingen', locationId: 'A=1@L=3@');
    const ein = Station(id: '4', name: 'Einbeck', locationId: 'A=1@L=4@');
    DateTime at(int h, int m) => DateTime(2026, 11, 13, h, m);
    JourneyLeg leg(Station a, Station b, DateTime d, DateTime r, String l) =>
        JourneyLeg(
          origin: a,
          destination: b,
          departure: d,
          plannedDeparture: d,
          arrival: r,
          plannedArrival: r,
          line: TransitLine(
            name: l,
            fahrtNr: '1',
            productName: l,
            product: 'x',
          ),
        );
    final old = Journey(
      legs: [
        leg(kiel, han, at(16, 16), at(18, 48), 'ICE 775'),
        leg(han, ein, at(19, 36), at(20, 30), 'RE2'),
      ],
    );
    final alt = Journey(
      legs: [
        leg(han, goe, at(19, 53), at(20, 25), 'ICE 77'),
        leg(goe, ein, at(21, 4), at(21, 24), 'RE2'),
      ],
    );
    final merged = mergeAlternative(old, alt);
    expect(merged.legs.map((l) => l.line!.name), ['ICE 775', 'ICE 77', 'RE2']);
  });
}
