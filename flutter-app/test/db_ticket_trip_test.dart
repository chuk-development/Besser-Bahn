import 'package:besser_bahn/models/db_ticket.dart';
import 'package:besser_bahn/models/journey.dart';
import 'package:besser_bahn/models/library_models.dart';
import 'package:besser_bahn/models/station.dart';
import 'package:besser_bahn/providers/account_provider.dart';
import 'package:flutter_test/flutter_test.dart';

final _now = DateTime.now();

Station _st(String name) => Station(id: 'eva-$name', name: name);

Journey _journey({required DateTime dep, required DateTime arr}) => Journey(
      legs: [
        JourneyLeg(
          origin: _st('Berlin Hbf'),
          destination: _st('Wolfsburg Hbf'),
          plannedDeparture: dep,
          departure: dep,
          plannedArrival: arr,
          arrival: arr,
        ),
      ],
    );

DbTicket _ticket({DateTime? gueltigBis}) => DbTicket(
      auftragsnummer: 'A1',
      kundenwunschId: 'K1',
      status: 'GUELTIG',
      klasse: 'KLASSE_2',
      reisendeText: '1 Erwachsener',
      gueltigBis: gueltigBis,
    );

DbTicketTrip _trip({Journey? journey, DbTicket? ticket}) => DbTicketTrip(
      index: const DbReiseIndex(auftragsnummer: 'A1', kundenwunschIds: ['K1']),
      ticketKey: 'A1/K1',
      ticket: ticket,
      journey: journey,
    );

void main() {
  group('a bought ticket knows whether its trip is over (#23)', () {
    test('a trip that already arrived is past', () {
      final trip = _trip(
        journey: _journey(
          dep: _now.subtract(const Duration(days: 3, hours: 1)),
          arr: _now.subtract(const Duration(days: 3)),
        ),
      );
      expect(trip.isPast, isTrue);
    });

    test('a trip still to come is not past', () {
      final trip = _trip(
        journey: _journey(
          dep: _now.add(const Duration(days: 1)),
          arr: _now.add(const Duration(days: 1, hours: 1)),
        ),
      );
      expect(trip.isPast, isFalse);
    });

    test('a trip under way is not past — arrival still ahead', () {
      final trip = _trip(
        journey: _journey(
          dep: _now.subtract(const Duration(minutes: 30)),
          arr: _now.add(const Duration(minutes: 30)),
        ),
      );
      expect(trip.isPast, isFalse);
    });

    test('the connection wins over gueltigBis', () {
      // A Flexpreis stays valid all day; the trip is over regardless.
      final trip = _trip(
        journey: _journey(
          dep: _now.subtract(const Duration(hours: 3)),
          arr: _now.subtract(const Duration(hours: 2)),
        ),
        ticket: _ticket(gueltigBis: _now.add(const Duration(hours: 6))),
      );
      expect(trip.endTime, _now.subtract(const Duration(hours: 2)));
      expect(trip.isPast, isTrue);
    });

    test('gueltigBis carries an unparsable Verbindung', () {
      final trip = _trip(
          ticket: _ticket(gueltigBis: _now.subtract(const Duration(days: 2))));
      expect(trip.isPast, isTrue);
    });

    test('REGRESSION: a ticket we know nothing about stays upcoming', () {
      // Never demote a trip we failed to resolve — hiding a live ticket at the
      // bottom is worse than showing a stale one on top.
      expect(_trip().isPast, isFalse);
      expect(_trip(ticket: _ticket()).isPast, isFalse);
    });
  });

  group('a ticket and its local bookmark are the same trip (#23)', () {
    test('journeyKey matches the local SavedJourney key', () {
      final dep = DateTime(2026, 7, 13, 17, 47);
      final j = _journey(dep: dep, arr: DateTime(2026, 7, 13, 18, 52));
      final trip = _trip(journey: j);

      expect(trip.journeyKey, SavedJourney(journey: j, savedAtMs: 0).key);
    });

    test('a ticket without a trip has no key to dedupe on', () {
      expect(_trip(ticket: _ticket()).journeyKey, isNull);
    });
  });
}
