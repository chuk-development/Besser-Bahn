import 'package:besser_bahn/models/journey.dart';
import 'package:besser_bahn/models/station.dart';
import 'package:besser_bahn/utils/journey_highlights.dart';
import 'package:flutter_test/flutter_test.dart';

Station _st(String n) => Station(id: n, name: n);

/// A journey of [minutes] costing [price], departing at a fixed time.
/// Journey.duration reads the live departure/arrival, so set those.
Journey _j({required int minutes, double? price, String tag = ''}) {
  final dep = DateTime(2026, 7, 15, 10);
  return Journey(
    legs: [
      JourneyLeg(
        tripId: tag,
        origin: _st('A'),
        destination: _st('B'),
        departure: dep,
        plannedDeparture: dep,
        arrival: dep.add(Duration(minutes: minutes)),
        plannedArrival: dep.add(Duration(minutes: minutes)),
      ),
    ],
    price: price == null ? null : JourneyPrice(amount: price),
  );
}

void main() {
  group('journeyHighlights (#11, point 9)', () {
    test("the reporter's shape: fastest, cheapest, safest, compromise", () {
      final fast = _j(minutes: 167, price: 59.90, tag: 'fast'); // 2:47
      final cheap = _j(minutes: 201, price: 19.90, tag: 'cheap'); // 3:21
      final safe = _j(minutes: 185, price: 34.90, tag: 'safe'); // 3:05
      final mid = _j(minutes: 178, price: 29.90, tag: 'mid'); // 2:58
      final scores = {'fast': 63.0, 'cheap': 81.0, 'safe': 94.0, 'mid': 90.0};

      final out = journeyHighlights([fast, cheap, safe, mid],
          (j) => scores[j.legs.first.tripId]);

      expect(out[JourneyHighlight.fastest], same(fast));
      expect(out[JourneyHighlight.cheapest], same(cheap));
      expect(out[JourneyHighlight.safest], same(safe));
      expect(out[JourneyHighlight.balanced], same(mid),
          reason: 'the middle option wins on the combined axes');
    });

    test('no prices → no "Günstigste" rather than a made-up one', () {
      final a = _j(minutes: 100, tag: 'a');
      final b = _j(minutes: 120, tag: 'b');
      final out = journeyHighlights([a, b], (j) => null);

      expect(out.containsKey(JourneyHighlight.cheapest), isFalse);
      expect(out[JourneyHighlight.fastest], same(a));
    });

    test('identical fares → "Günstigste" is dropped (it distinguishes nothing)',
        () {
      final a = _j(minutes: 100, price: 20, tag: 'a');
      final b = _j(minutes: 120, price: 20, tag: 'b');
      final out = journeyHighlights([a, b], (j) => null);

      expect(out.containsKey(JourneyHighlight.cheapest), isFalse,
          reason: 'labelling one of two equal fares "cheapest" is noise');
    });

    test('predictions still loading → no "Sicherste" yet', () {
      final a = _j(minutes: 100, price: 20, tag: 'a');
      final b = _j(minutes: 120, price: 30, tag: 'b');
      final out = journeyHighlights([a, b], (j) => null);

      expect(out.containsKey(JourneyHighlight.safest), isFalse);
      expect(out[JourneyHighlight.fastest], same(a));
      expect(out[JourneyHighlight.cheapest], same(a));
    });

    test('the compromise never duplicates an extreme', () {
      // Two journeys: whatever wins is already fastest or cheapest.
      final a = _j(minutes: 100, price: 50, tag: 'a');
      final b = _j(minutes: 140, price: 20, tag: 'b');
      final out = journeyHighlights([a, b], (j) => null);

      final balanced = out[JourneyHighlight.balanced];
      if (balanced != null) {
        expect(
            out.entries
                .where((e) => e.key != JourneyHighlight.balanced)
                .any((e) => identical(e.value, balanced)),
            isFalse,
            reason: 'a badge that repeats another tells you nothing');
      }
    });

    test('one connection gets no badges — there is nothing to compare', () {
      expect(journeyHighlights([_j(minutes: 100, price: 20)], (j) => 90.0),
          isEmpty);
      expect(journeyHighlights([], (j) => null), isEmpty);
    });

    test('the same journey can be both fastest and cheapest', () {
      final winner = _j(minutes: 90, price: 10, tag: 'w');
      final other = _j(minutes: 150, price: 40, tag: 'o');
      final out = journeyHighlights([winner, other], (j) => null);

      expect(out[JourneyHighlight.fastest], same(winner));
      expect(out[JourneyHighlight.cheapest], same(winner));
    });
  });
}
