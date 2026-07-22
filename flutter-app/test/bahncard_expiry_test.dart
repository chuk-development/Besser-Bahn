import 'package:besser_bahn/models/db_account.dart';
import 'package:flutter_test/flutter_test.dart';

DbBahnCard _card({String? from, String? until}) => DbBahnCard(
      nummer: '7081411251741233',
      typ: 'BC25',
      produktBezeichnung: 'BahnCard 25',
      klasse: 'KLASSE_2',
      gueltigAb: from,
      gueltigBis: until,
    );

void main() {
  final now = DateTime(2026, 7, 22, 12);

  group('#53 — BahnCard validity', () {
    test('the last day of validity still counts', () {
      // A card "gültig bis 2026-07-22" discounts a ticket bought on the 22nd —
      // calling it expired at 00:00 that day would drop a discount the rider
      // still has.
      expect(_card(until: '2026-07-22').isExpiredAt(now), isFalse);
      expect(_card(until: '2026-07-22').isValidAt(now), isTrue);
    });

    test('the day after is expired', () {
      expect(_card(until: '2026-07-21').isExpiredAt(now), isTrue);
      expect(_card(until: '2026-07-21').isValidAt(now), isFalse);
    });

    test('a card that starts tomorrow is not valid yet', () {
      final card = _card(from: '2026-07-23', until: '2027-07-22');
      expect(card.isNotYetValidAt(now), isTrue);
      expect(card.isValidAt(now), isFalse);
      expect(card.isExpiredAt(now), isFalse,
          reason: 'not-yet-valid is not the same as dead');
    });

    test('a card valid from today counts from 00:00', () {
      expect(_card(from: '2026-07-22').isNotYetValidAt(now), isFalse);
    });

    test('a card without dates is treated as valid', () {
      // We only ever want to demote a card we KNOW is dead — a missing date
      // must not hide a working BahnCard.
      expect(_card().isValidAt(now), isTrue);
      expect(_card().isExpiredAt(now), isFalse);
    });

    test('an unparseable date is treated as valid', () {
      expect(_card(until: 'irgendwann').isValidAt(now), isTrue);
    });
  });
}
