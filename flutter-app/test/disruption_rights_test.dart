import 'package:besser_bahn/core/disruption_rights.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('ticket type from the order name', () {
    expect(
      DisruptionRights.ticketFrom(angebotsname: 'Flexpreis Young'),
      RightsTicket.fernverkehrFlex,
    );
    expect(
      DisruptionRights.ticketFrom(angebotsname: 'Super Sparpreis'),
      RightsTicket.fernverkehrSpar,
    );
    expect(
      DisruptionRights.ticketFrom(hasDeutschlandTicket: true),
      RightsTicket.deutschlandTicket,
    );
    expect(DisruptionRights.ticketFrom(), RightsTicket.unbekannt);
  });

  test('on time → nothing to say', () {
    expect(
      DisruptionRights.answers(
        ticket: RightsTicket.fernverkehrFlex,
        delayMinutes: 10,
        cancelled: false,
      ),
      isEmpty,
    );
  });

  test(
    'Flexpreis + cancelled RE2 (2026-11-13): other train/route allowed, no taxi',
    () {
      final a = DisruptionRights.answers(
        ticket: RightsTicket.fernverkehrFlex,
        delayMinutes: 0,
        cancelled: true,
        plannedArrival: DateTime(2026, 11, 13, 20, 30),
      );
      expect(a.first.allowed, isTrue);
      expect(a.first.text, contains('andere'));
      expect(a.last.title, 'Taxi');
      expect(a.last.allowed, isFalse);
    },
  );

  test(
    'Deutschlandticket: no ICE in the evening, ICE/taxi up to 120 € for the last train',
    () {
      final normal = DisruptionRights.answers(
        ticket: RightsTicket.deutschlandTicket,
        delayMinutes: 30,
        cancelled: true,
      );
      expect(normal.first.allowed, isFalse);
      final last = DisruptionRights.answers(
        ticket: RightsTicket.deutschlandTicket,
        delayMinutes: 30,
        cancelled: true,
        lastOfDay: true,
      );
      expect(last.first.allowed, isTrue);
      expect(last.first.text, contains('120'));
      expect(last.last.allowed, isTrue);
    },
  );

  test('night arrival 0–5 h with ≥60 min → taxi refunded', () {
    final a = DisruptionRights.answers(
      ticket: RightsTicket.nahverkehr,
      delayMinutes: 65,
      cancelled: false,
      plannedArrival: DateTime(2026, 11, 14, 1, 30),
    );
    expect(a.last.allowed, isTrue);
  });

  test('unknown ticket answers for every type', () {
    final a = DisruptionRights.answers(
      ticket: RightsTicket.unbekannt,
      delayMinutes: 25,
      cancelled: false,
    );
    expect(a.length, 5);
  });
}
