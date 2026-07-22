import 'package:besser_bahn/models/journey.dart';
import 'package:besser_bahn/models/station.dart';
import 'package:besser_bahn/utils/leg_swap.dart';
import 'package:flutter_test/flutter_test.dart';

final _base = DateTime(2026, 8, 1, 8);

Station _st(String name) => Station(id: name, name: name);

JourneyLeg _leg(
  String from,
  String to, {
  required int depMin,
  required int arrMin,
  bool walking = false,
}) =>
    JourneyLeg(
      origin: _st(from),
      destination: _st(to),
      plannedDeparture: _base.add(Duration(minutes: depMin)),
      departure: _base.add(Duration(minutes: depMin)),
      plannedArrival: _base.add(Duration(minutes: arrMin)),
      arrival: _base.add(Duration(minutes: arrMin)),
      isWalking: walking,
    );

/// Kiel → Hamburg → München, the case from the report.
List<JourneyLeg> _kielMuenchen() => [
      _leg('Kiel Hbf', 'Hamburg Hbf', depMin: 0, arrMin: 75),
      _leg('Hamburg Hbf', 'Hamburg Hbf', depMin: 75, arrMin: 85, walking: true),
      _leg('Hamburg Hbf', 'München Hbf', depMin: 85, arrMin: 445),
    ];

Journey _journey(List<JourneyLeg> legs) => Journey(legs: legs);

void main() {
  group('a swapped leg drags the rest of the journey with it', () {
    test('a later train means the connection behind it is re-planned', () {
      expect(
        tailNeedsReplan(_kielMuenchen(), 0,
            oldArrival: _base.add(const Duration(minutes: 75)),
            newArrival: _base.add(const Duration(minutes: 135))),
        isTrue,
      );
    });

    test('an earlier train too — the rider should not wait for nothing', () {
      expect(
        tailNeedsReplan(_kielMuenchen(), 0,
            oldArrival: _base.add(const Duration(minutes: 75)),
            newArrival: _base.add(const Duration(minutes: 45))),
        isTrue,
      );
    });

    test('the same arrival changes nothing behind it', () {
      final same = _base.add(const Duration(minutes: 75));
      expect(
        tailNeedsReplan(_kielMuenchen(), 0,
            oldArrival: same, newArrival: same),
        isFalse,
      );
    });

    test('the last train has no tail to re-plan', () {
      expect(
        tailNeedsReplan(_kielMuenchen(), 2,
            oldArrival: _base.add(const Duration(minutes: 445)),
            newArrival: _base.add(const Duration(minutes: 500))),
        isFalse,
      );
      // A walk behind the swapped leg is not a train either.
      expect(
        tailNeedsReplan([_kielMuenchen()[0], _kielMuenchen()[1]], 0,
            oldArrival: _base, newArrival: _base.add(const Duration(hours: 1))),
        isFalse,
      );
    });

    test('an unknown new arrival is not acted on', () {
      expect(
        tailNeedsReplan(_kielMuenchen(), 0,
            oldArrival: _base, newArrival: null),
        isFalse,
      );
    });
  });

  group('picking the onward journey', () {
    final arrival = _base.add(const Duration(minutes: 135));

    test('the first one that leaves after the new arrival wins', () {
      final tooEarly =
          _journey([_leg('Hamburg Hbf', 'München Hbf', depMin: 85, arrMin: 445)]);
      final good =
          _journey([_leg('Hamburg Hbf', 'München Hbf', depMin: 150, arrMin: 510)]);
      final later =
          _journey([_leg('Hamburg Hbf', 'München Hbf', depMin: 210, arrMin: 570)]);
      expect(firstBoardable([tooEarly, good, later], arrival), same(good),
          reason: 'the backend window can start before the requested time');
    });

    test('leaving exactly on arrival counts as boardable', () {
      final onTheDot =
          _journey([_leg('Hamburg Hbf', 'München Hbf', depMin: 135, arrMin: 495)]);
      expect(firstBoardable([onTheDot], arrival), same(onTheDot));
    });

    test('nothing boardable yields null rather than a wrong train', () {
      final gone =
          _journey([_leg('Hamburg Hbf', 'München Hbf', depMin: 85, arrMin: 445)]);
      expect(firstBoardable([gone], arrival), isNull);
      expect(firstBoardable(const [], arrival), isNull);
    });
  });

  group('splicing', () {
    test('the swapped leg is kept and everything behind it replaced', () {
      final legs = _kielMuenchen();
      final onward = _journey([
        _leg('Hamburg Hbf', 'Hamburg Hbf', depMin: 140, arrMin: 150, walking: true),
        _leg('Hamburg Hbf', 'München Hbf', depMin: 150, arrMin: 510),
      ]);
      final spliced = spliceTail(legs, 0, onward);
      expect(spliced, hasLength(3));
      expect(spliced.first.destination.name, 'Hamburg Hbf');
      expect(spliced.last.plannedArrival,
          _base.add(const Duration(minutes: 510)));
    });
  });
}
