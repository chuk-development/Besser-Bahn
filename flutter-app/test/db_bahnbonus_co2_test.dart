import 'package:besser_bahn/models/db_account.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses the official BahnBonus yearly CO2 statistics shape', () {
    final balance = DbBahnBonusCo2Balance.fromJson({
      'periodOfTime': {'startDate': '2026-01-01', 'endDate': '2026-07-16'},
      'emissions': {
        'co2EmissionTravelByTrain': 18.25,
        'co2EmissionTravelByCar': 143.75,
        'co2Reduction': 125.5,
      },
      'travelDistance': 1234.5,
      'comparisons': const [],
    });

    expect(balance.year, 2026);
    expect(balance.startDate, '2026-01-01');
    expect(balance.endDate, '2026-07-16');
    expect(balance.trainEmissionKg, 18.25);
    expect(balance.carEmissionKg, 143.75);
    expect(balance.reductionKg, 125.5);
    expect(balance.travelDistanceKm, 1234.5);
  });

  test('round-trips through the persisted cache shape', () {
    const original = DbBahnBonusCo2Balance(
      year: 2026,
      startDate: '2026-01-01',
      endDate: '2026-07-16',
      trainEmissionKg: 10,
      carEmissionKg: 80,
      reductionKg: 70,
      travelDistanceKm: 900,
    );

    final restored = DbBahnBonusCo2Balance.fromJson(original.toJson());

    expect(restored.year, original.year);
    expect(restored.reductionKg, original.reductionKg);
    expect(restored.travelDistanceKm, original.travelDistanceKm);
  });
}
