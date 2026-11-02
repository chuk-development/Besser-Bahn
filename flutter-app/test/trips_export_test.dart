import 'package:besser_bahn/models/db_ticket.dart';
import 'package:besser_bahn/models/departure.dart' show TransitLine;
import 'package:besser_bahn/models/journey.dart';
import 'package:besser_bahn/models/library_models.dart';
import 'package:besser_bahn/models/station.dart';
import 'package:besser_bahn/providers/account_provider.dart';
import 'package:besser_bahn/screens/journeys/journeys_screen.dart';
import 'package:besser_bahn/utils/data_export.dart';
import 'package:flutter_test/flutter_test.dart';

Station _st(String name) => Station(id: name, name: name);

JourneyLeg _leg(
  String from,
  String to,
  DateTime dep,
  DateTime arr, {
  String line = 'ICE 584',
  String nr = '584',
}) => JourneyLeg(
  origin: _st(from),
  destination: _st(to),
  departure: dep,
  plannedDeparture: dep,
  arrival: arr,
  plannedArrival: arr,
  line: TransitLine(
    name: line,
    fahrtNr: nr,
    productName: 'ICE',
    product: 'nationalExpress',
  ),
);

// UTC instants: 07:00Z is 09:00 in Berlin (CEST) — the CSV must print 09:00
// whatever the test machine's zone is (#106).
final _a = Journey(
  legs: [
    _leg(
      'Kiel Hbf',
      'Hamburg Hbf',
      DateTime.utc(2026, 8, 1, 7),
      DateTime.utc(2026, 8, 1, 8, 15),
    ),
    _leg(
      'Hamburg Hbf',
      'Berlin Hbf',
      DateTime.utc(2026, 8, 1, 8, 30),
      DateTime.utc(2026, 8, 1, 10, 30),
      line: 'RE1',
      nr: '21012',
    ),
  ],
  price: const JourneyPrice(amount: 49.9),
);

void main() {
  group('tripsToCsv (#72)', () {
    test('one row per trip with times in Berlin, trains and price', () {
      final csv = tripsToCsv([
        TripExportRow(
          kind: TripExportKind.ticket,
          journey: _a,
          price: 29.99,
          priceSource: 'Ticket',
          offerName: 'Super Sparpreis',
          travelClass: 'KLASSE_2',
          discounts: const ['BahnCard 25'],
          orderNumber: '123456789',
        ),
      ]);
      final lines = csv.trim().split('\n');
      expect(lines.first, startsWith('Typ,Abfahrt,Ankunft,Von,Nach,Dauer'));
      expect(lines, hasLength(2));
      final row = lines[1];
      expect(row, startsWith('Ticket,2026-08-01 09:00,2026-08-01 12:30,'));
      expect(row, contains('Kiel Hbf,Berlin Hbf,210,1,'));
      expect(row, contains('ICE 584 + RE1 (21012)'));
      expect(row, contains('29.99,Ticket,Super Sparpreis,2,BahnCard 25'));
      expect(row, endsWith('123456789'));
    });

    test('sorts oldest first and leaves unknown fields empty', () {
      final csv = tripsToCsv([
        TripExportRow(kind: TripExportKind.local, journey: _a),
        TripExportRow(
          kind: TripExportKind.dbSaved,
          fallbackStart: DateTime.utc(2026, 7, 1, 10),
        ),
      ]);
      final lines = csv.trim().split('\n');
      expect(lines[1], startsWith('Gemerkte Reise,2026-07-01 12:00,,,,,,'));
      expect(lines[2], startsWith('Gespeicherte Reise,'));
      // No price → no price source either.
      expect(lines[2], isNot(contains('Suche')));
    });
  });

  group('tripExportRows (#72)', () {
    test('a bought trip exports once, as the ticket', () {
      final saved = SavedJourney(journey: _a, savedAtMs: 0);
      final ticket = DbTicketTrip(
        index: const DbReiseIndex(auftragsnummer: 'A1', kundenwunschIds: ['k']),
        ticketKey: 'A1/k',
        journey: _a,
      );
      final rows = tripExportRows(
        tickets: [ticket],
        savedReisen: const [DbSavedReiseIndex(rkUuid: 'rk1')],
        savedJourneys: {'rk1': _a},
        local: [saved],
        savedReiseIds: {saved.key: 'rk1'},
      );
      expect(rows.map((r) => r.kind), [TripExportKind.ticket]);
    });

    test('a local-only trip carries its search price', () {
      final rows = tripExportRows(
        tickets: const [],
        savedReisen: const [],
        savedJourneys: const {},
        local: [SavedJourney(journey: _a, savedAtMs: 0)],
        savedReiseIds: const {},
      );
      expect(rows.single.kind, TripExportKind.local);
      expect(rows.single.price, 49.9);
      expect(rows.single.priceSource, 'Suche');
    });
  });

  group('DbTicket.priceFromTicketHtml (#72)', () {
    test('reads the total, not a per-position price', () {
      const html =
          '<html><img src="data:image/png;base64,AAAA"/>'
          '<td>Preis</td><td>19,99&nbsp;&euro;</td>'
          '<td>Gesamtpreis</td><td>1.029,98 €</td></html>';
      expect(DbTicket.priceFromTicketHtml(html), 1029.98);
    });

    test('currency before the amount', () {
      expect(DbTicket.priceFromTicketHtml('<b>Summe</b> EUR 29,99'), 29.99);
    });

    test('a tariff name is not a price label', () {
      expect(
        DbTicket.priceFromTicketHtml('<p>Super Sparpreis 2. Klasse</p>'),
        isNull,
      );
      expect(DbTicket.priceFromTicketHtml(null), isNull);
    });
  });
}
