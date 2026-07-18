import 'package:besser_bahn/core/share_text.dart';
import 'package:besser_bahn/models/departure.dart';
import 'package:besser_bahn/models/journey.dart';
import 'package:besser_bahn/models/station.dart';
import 'package:besser_bahn/models/trip.dart';
import 'package:flutter_test/flutter_test.dart';

/// #50: a Gleiswechsel announced after the search must show in the share text
/// once a realtime trip run is supplied — not the stale planned platform.
void main() {
  final berlinSued = const Station(id: '8011113', name: 'Berlin Südkreuz');
  final elstal = const Station(id: '8013467', name: 'Elstal');

  final leg = JourneyLeg(
    tripId: 'trip-3149',
    origin: berlinSued,
    destination: elstal,
    plannedDeparture: DateTime(2026, 7, 18, 8, 44),
    departure: DateTime(2026, 7, 18, 8, 44),
    plannedDeparturePlatform: '6',
    departurePlatform: '6', // search snapshot: no Gleiswechsel yet
    plannedArrival: DateTime(2026, 7, 18, 9, 19),
    arrival: DateTime(2026, 7, 18, 9, 19),
    arrivalPlatform: '1',
    plannedArrivalPlatform: '1',
    line: const TransitLine(
        name: 'RE4', fahrtNr: '3149', productName: 'RE', product: 'regional'),
    direction: 'Rathenow',
  );
  final journey = Journey(legs: [leg]);

  test('without live overlay shows the search-time (planned) platform', () {
    final txt = journeyShareText(journey, 'https://x/vbid=1');
    expect(txt, contains('Ab 08:44 Berlin Südkreuz, Gleis 6'));
  });

  test('live overlay surfaces the realtime Gleiswechsel (6 → 7)', () {
    final live = {
      'trip-3149': Trip(
        id: 'trip-3149',
        line: const TransitLine(
            name: 'RE4', fahrtNr: '3149', productName: 'RE', product: 'regional'),
        direction: 'Rathenow',
        origin: berlinSued,
        destination: elstal,
        stopovers: [
          Stopover(
            stop: berlinSued,
            departure: DateTime(2026, 7, 18, 8, 43),
            plannedDeparture: DateTime(2026, 7, 18, 8, 44),
            departurePlatform: '7', // ezGleis — the change DB announced
            plannedDeparturePlatform: '6',
          ),
          Stopover(
            stop: elstal,
            arrival: DateTime(2026, 7, 18, 9, 19),
            plannedArrival: DateTime(2026, 7, 18, 9, 19),
            arrivalPlatform: '1',
            plannedArrivalPlatform: '1',
          ),
        ],
      ),
    };
    final txt = journeyShareText(journey, 'https://x/vbid=1', live: live);
    expect(txt, contains('Ab 08:43 Berlin Südkreuz, Gleis 7'));
    expect(txt, isNot(contains('Gleis 6')));
  });

  test('live overlay missing a leg falls back to that leg values', () {
    final txt = journeyShareText(journey, 'https://x/vbid=1', live: const {});
    expect(txt, contains('Gleis 6'));
  });
}
