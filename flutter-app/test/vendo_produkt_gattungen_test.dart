import 'package:besser_bahn/services/vendo_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// The codes `/mob/trip/weitereabfahrten` accepts, probed live. Anything else
/// comes back `400 VALIDIERUNG` — the endpoint does not ignore unknown values.
/// Kept in step with `WEITERE_ABFAHRTEN_GATTUNGEN` in api-tests/healthcheck.py.
const _accepted = {
  'ICE',
  'IC_EC',
  'RB',
  'SBAHN',
  'BUS',
  'UBAHN',
  'STR',
  'SCHIFF',
};

void main() {
  group('produktGattungenFor — "Weitere Abfahrten" product codes', () {
    test('every product maps to a code the endpoint accepts', () {
      // Whatever _mapProduct can produce, plus the unknown case.
      const products = [
        'nationalExpress',
        'national',
        'regional',
        'regionalExp',
        'suburban',
        'bus',
        'subway',
        'tram',
        'ferry',
        null,
        'taxi',
      ];
      for (final p in products) {
        expect(_accepted, contains(VendoService.produktGattungenFor(p)),
            reason: 'product "$p" would 400 the whole switcher');
      }
    });

    test('IC/EC uses the live spelling IC_EC, not EC_IC', () {
      // Same slip the board parser had: EC_IC never appears in live data, and
      // here it took every IC/EC leg's "Weitere Abfahrten" down with a 400.
      expect(VendoService.produktGattungenFor('national'), 'IC_EC');
    });

    test('U-Bahn is UBAHN', () {
      expect(VendoService.produktGattungenFor('subway'), 'UBAHN');
    });

    test('an unknown product falls back to regional, not an invented ALL', () {
      expect(VendoService.produktGattungenFor(null), 'RB');
    });
  });
}
