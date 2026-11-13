import 'package:besser_bahn/models/departure.dart' show TransitLine;
import 'package:besser_bahn/models/journey.dart';
import 'package:besser_bahn/models/station.dart';
import 'package:besser_bahn/providers/live_trip_provider.dart';
import 'package:flutter_test/flutter_test.dart';

/// 2026-11-13: ICE 77 reached Göttingen at 20:50, the RB82 left at 20:48. The
/// tracker must offer the RE2 21:04 from Gleis 6 — not the train already gone.

const _goe = Station(
  id: '8000128',
  name: 'Göttingen',
  locationId: 'A=1@L=8000128@',
);
const _ein = Station(
  id: '8001703',
  name: 'Einbeck-Salzderhelden',
  locationId: 'A=1@L=8001703@',
);
DateTime _at(int h, int m) => DateTime(2026, 11, 13, h, m);

Journey _j(String line, DateTime dep, DateTime arr, {String gleis = '6'}) =>
    Journey(
      legs: [
        JourneyLeg(
          origin: _goe,
          destination: _ein,
          departure: dep,
          plannedDeparture: dep,
          arrival: arr,
          plannedArrival: arr,
          departurePlatform: gleis,
          line: TransitLine(
            name: line,
            fahrtNr: '1',
            productName: line.split(' ').first,
            product: 'regional',
          ),
        ),
      ],
    );

void main() {
  final rb82 = _j('RB82', _at(20, 48), _at(21, 10), gleis: '4');
  final re2 = _j('RE2', _at(21, 4), _at(21, 24));
  final re2late = _j('RE2', _at(22, 9), _at(22, 30));

  test('skips the train that already left, takes the next one', () {
    final pick = LiveTripTracker.pickReplacement([
      rb82,
      re2,
      re2late,
    ], readyAt: _at(20, 50));
    expect(pick, same(re2));
    expect(
      LiveTripTracker.replacementText(pick!),
      'Nimm RE2 21:04 Gl. 6 → an 21:24',
    );
  });

  test('needs two minutes to reach the platform', () {
    expect(
      LiveTripTracker.pickReplacement([re2, re2late], readyAt: _at(21, 3)),
      same(re2late),
    );
  });

  test('nothing reachable → null', () {
    expect(
      LiveTripTracker.pickReplacement([rb82], readyAt: _at(21, 0)),
      isNull,
    );
  });
}
