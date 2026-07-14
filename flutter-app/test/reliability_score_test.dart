import 'package:besser_bahn/models/journey_prediction.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('JourneyPrediction.reliabilityScore (#11)', () {
    test('a direct train is ranked on punctuality alone', () {
      expect(const JourneyPrediction(puenktlichkeit: 89).reliabilityScore, 89);
    });

    test('with transfers, the weakest link decides', () {
      // Catching the transfer is the risk here, not arriving on time.
      expect(
          const JourneyPrediction(verbindungsscore: 54, puenktlichkeit: 90)
              .reliabilityScore,
          54);
      // …and vice versa.
      expect(
          const JourneyPrediction(verbindungsscore: 94, puenktlichkeit: 71)
              .reliabilityScore,
          71);
    });

    test('no scores → null, so it sorts last rather than looking terrible', () {
      expect(const JourneyPrediction().reliabilityScore, isNull);
    });

    test("the reporter's example orders as they expect", () {
      // ICE→ICE 7min: 54 | ICE direkt: 89 | RE→ICE 18min: 94
      final tight = const JourneyPrediction(verbindungsscore: 54, puenktlichkeit: 88);
      final direct = const JourneyPrediction(puenktlichkeit: 89);
      final relaxed = const JourneyPrediction(verbindungsscore: 94, puenktlichkeit: 94);
      final scores = [tight, direct, relaxed].map((p) => p.reliabilityScore!).toList();
      expect(scores, [54, 89, 94]);
      // Sorted most-reliable-first → relaxed, direct, tight.
      scores.sort((a, b) => b.compareTo(a));
      expect(scores, [94, 89, 54]);
    });
  });
}
