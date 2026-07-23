import 'package:besser_bahn/core/passenger_rights.dart';
import 'package:besser_bahn/models/journey.dart';
import 'package:besser_bahn/models/station.dart';
import 'package:flutter_test/flutter_test.dart';

final _base = DateTime(2026, 8, 1, 8);

Station _st(String n) => Station(id: n, name: n);

/// One transit leg with a planned and (optionally) delayed actual arrival.
JourneyLeg _leg({
  required int depMin,
  required int plannedArrMin,
  int? actualArrMin,
  int? arrivalDelaySec,
  bool walking = false,
}) =>
    JourneyLeg(
      origin: _st('A'),
      destination: _st('B'),
      plannedDeparture: _base.add(Duration(minutes: depMin)),
      departure: _base.add(Duration(minutes: depMin)),
      plannedArrival: _base.add(Duration(minutes: plannedArrMin)),
      arrival: _base.add(Duration(minutes: actualArrMin ?? plannedArrMin)),
      arrivalDelay: arrivalDelaySec,
      isWalking: walking,
    );

Journey _journey(List<JourneyLeg> legs, {JourneyPrice? price}) =>
    Journey(legs: legs, price: price);

void main() {
  group('delay thresholds (#60)', () {
    test('under 60 min is not eligible', () {
      final j = _journey([_leg(depMin: 0, plannedArrMin: 60, actualArrMin: 119)]);
      final r = PassengerRights.evaluate(j);
      expect(r.delayMinutes, 59);
      expect(r.isEligible, isFalse);
      expect(r.percent, 0);
    });

    test('60 min → 25 %', () {
      final j = _journey([_leg(depMin: 0, plannedArrMin: 60, actualArrMin: 120)]);
      final r = PassengerRights.evaluate(j);
      expect(r.delayMinutes, 60);
      expect(r.percent, 25);
    });

    test('120 min → 50 %', () {
      final j = _journey([_leg(depMin: 0, plannedArrMin: 60, actualArrMin: 180)]);
      expect(PassengerRights.evaluate(j).percent, 50);
    });

    test('the delay is the larger of the live leg delay and planned-vs-actual',
        () {
      // Leg carries no live delay, but the re-planned arrival is 90 min late —
      // the difference is the safety net for a missed-connection re-plan.
      final j = _journey([_leg(depMin: 0, plannedArrMin: 60, actualArrMin: 150)]);
      expect(PassengerRights.evaluate(j).delayMinutes, 90);

      // And the other way: a live leg delay larger than the naive difference.
      final j2 = _journey(
          [_leg(depMin: 0, plannedArrMin: 60, arrivalDelaySec: 75 * 60)]);
      expect(PassengerRights.evaluate(j2).delayMinutes, 75);
    });

    test('a hand-corrected delay drives the same tiers', () {
      expect(PassengerRights.fromDelay(59).isEligible, isFalse);
      expect(PassengerRights.fromDelay(60).percent, 25);
      expect(PassengerRights.fromDelay(200).percent, 50);
      expect(PassengerRights.fromDelay(-5).delayMinutes, 0);
    });
  });

  group('payout by fare kind', () {
    final r25 = PassengerRights.fromDelay(60);
    final r50 = PassengerRights.fromDelay(120);

    test('single ticket: percent of the fare', () {
      final e = r25.estimate(FareKind.einzelfahrt, fareEuros: 40);
      expect(e.amount, closeTo(10, 0.001));
      expect(e.isPayable, isTrue);
      expect(e.isPauschale, isFalse);
    });

    test('return ticket: only the affected direction (half) counts', () {
      final e = r50.estimate(FareKind.hinUndRueck, fareEuros: 40);
      expect(e.amount, closeTo(10, 0.001),
          reason: '50 % of half of 40 € = 10 €');
    });

    test('under the €4 minimum: computed but not payable', () {
      final e = r25.estimate(FareKind.einzelfahrt, fareEuros: 12);
      expect(e.amount, closeTo(3, 0.001));
      expect(e.belowMinimum, isTrue);
      expect(e.isPayable, isFalse);
    });

    test('Deutschlandticket: fixed 2nd-class pauschale, not a percentage', () {
      final e = r50.estimate(FareKind.deutschlandTicket, fareEuros: 999);
      expect(e.amount, PassengerRights.pauschaleSecondClassEuros);
      expect(e.isPauschale, isTrue);
      expect(e.isPayable, isTrue);
    });

    test('other season ticket: 1st vs 2nd class pauschale', () {
      expect(r25.estimate(FareKind.zeitkarte).amount,
          PassengerRights.pauschaleSecondClassEuros);
      expect(r25.estimate(FareKind.zeitkarte, firstClass: true).amount,
          PassengerRights.pauschaleFirstClassEuros);
    });

    test('unknown fare or fare kind: no amount', () {
      expect(r25.estimate(FareKind.einzelfahrt).amount, isNull);
      expect(r25.estimate(FareKind.unbekannt, fareEuros: 40).amount, isNull);
    });

    test('not eligible → nothing regardless of fare', () {
      final r = PassengerRights.fromDelay(30);
      expect(r.estimate(FareKind.einzelfahrt, fareEuros: 100).amount, isNull);
    });
  });

  test('refundEuros keeps the compact-banner behaviour', () {
    final r = PassengerRights.fromDelay(60);
    expect(r.refundEuros(40), closeTo(10, 0.001));
    expect(r.refundEuros(null), isNull);
    expect(PassengerRights.fromDelay(10).refundEuros(40), isNull);
  });

  test('prefill text carries the facts a claim needs', () {
    final j = _journey([
      _leg(depMin: 0, plannedArrMin: 60, actualArrMin: 130),
    ], price: const JourneyPrice(amount: 40));
    final text = PassengerRights.evaluate(j).prefillText(j);
    expect(text, contains('Verspätung: 70 Min'));
    expect(text, contains('25 % Entschädigung'));
    expect(text, contains('A → B'));
  });

  test('the non-binding disclaimer and caveats exist for the UI', () {
    expect(PassengerRights.disclaimer, contains('keine'));
    expect(PassengerRights.caveats, isNotEmpty);
    expect(PassengerRights.caveats.any((c) => c.contains('Split')), isTrue);
  });
}
