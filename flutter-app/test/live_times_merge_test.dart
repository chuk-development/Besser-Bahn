import 'package:besser_bahn/models/departure.dart' show TransitLine;
import 'package:besser_bahn/models/journey.dart';
import 'package:besser_bahn/models/station.dart';
import 'package:besser_bahn/models/trip.dart';
import 'package:besser_bahn/providers/live_trip_provider.dart';
import 'package:besser_bahn/utils/live_trip_summary.dart';
import 'package:flutter_test/flutter_test.dart';

/// 2026-11-13, ICE 775 Kiel → Hannover: planned 18:48, live 19:05. At 18:55
/// the chip and the Reisen card both showed "arrived" — they read the saved
/// trip's planned times instead of the live run the tracker already held.

const _kiel = Station(
  id: '8000199',
  name: 'Kiel Hbf',
  locationId: 'A=1@L=8000199@',
);
const _hannover = Station(
  id: '8000152',
  name: 'Hannover Hbf',
  locationId: 'A=1@L=8000152@',
);
const _ice = TransitLine(
  name: 'ICE 775',
  fahrtNr: '775',
  productName: 'ICE',
  product: 'nationalExpress',
);

DateTime _at(int h, int m) => DateTime(2026, 11, 13, h, m);

void main() {
  final saved = Journey(
    legs: [
      JourneyLeg(
        tripId: 'zl-775',
        origin: _kiel,
        destination: _hannover,
        departure: _at(16, 16),
        plannedDeparture: _at(16, 16),
        arrival: _at(18, 48),
        plannedArrival: _at(18, 48),
        line: _ice,
      ),
    ],
  );
  final live = Trip(
    id: 'zl-775',
    line: _ice,
    direction: 'Stuttgart Hbf',
    origin: _kiel,
    destination: _hannover,
    stopovers: [
      Stopover(
        stop: _kiel,
        departure: _at(16, 18),
        plannedDeparture: _at(16, 16),
        departureDelay: 120,
      ),
      Stopover(
        stop: _hannover,
        arrival: _at(19, 5),
        plannedArrival: _at(18, 48),
        arrivalDelay: 17 * 60,
      ),
    ],
  );

  test('the live run replaces the saved times', () {
    final j = withLiveTimes(saved, {'zl-775': live});
    final leg = j.legs.single;
    expect(leg.arrival, _at(19, 5));
    expect(leg.plannedArrival, _at(18, 48));
    expect(leg.arrivalDelayMinutes, 17);
    expect(leg.departure, _at(16, 18));
  });

  test('a late train is not "arrived" after its planned arrival', () {
    final now = _at(18, 55);
    expect(summariseTrip(saved, now).finishedAt(now), isTrue); // the bug
    final merged = summariseTrip(withLiveTimes(saved, {'zl-775': live}), now);
    expect(merged.finishedAt(now), isFalse);
    expect(merged.delayMinutes, 17);
  });

  test('no live run → the journey is returned as is', () {
    expect(identical(withLiveTimes(saved, const {}), saved), isTrue);
  });
}
