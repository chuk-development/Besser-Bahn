import 'package:besser_bahn/models/departure.dart';
import 'package:besser_bahn/models/journey.dart';
import 'package:besser_bahn/models/station.dart';
import 'package:besser_bahn/utils/earlier_onward.dart';
import 'package:besser_bahn/utils/tight_chain.dart';
import 'package:flutter_test/flutter_test.dart';

// So. 15.11.2026, Bremen → Kiel, the case from the report.
final _day = DateTime(2026, 11, 15);
DateTime _t(int h, int m) => _day.add(Duration(hours: h, minutes: m));

Station _st(String name) => Station(id: name, name: name, locationId: name);

JourneyLeg _leg(
  String from,
  String to,
  DateTime dep,
  DateTime arr, {
  String name = 'S3',
  String product = 'suburban',
  String? trip,
  bool walking = false,
}) => JourneyLeg(
  tripId: trip ?? '$name-${dep.toIso8601String()}',
  origin: _st(from),
  destination: _st(to),
  departure: dep,
  plannedDeparture: dep,
  arrival: arr,
  plannedArrival: arr,
  isWalking: walking,
  line: walking
      ? null
      : TransitLine(
          name: name,
          fahrtNr: '1',
          productName: name.split(' ').first,
          product: product,
        ),
);

Journey _j(List<JourneyLeg> legs) => Journey(legs: legs);

void main() {
  final booked = _leg('Harburg', 'Hbf', _t(15, 59), _t(16, 15));
  final re7 = _leg(
    'Hbf',
    'Kiel',
    _t(16, 39),
    _t(17, 52),
    name: 'RE7',
    product: 'regional',
  );

  group('Früher weiter', () {
    test('an earlier metronom to Hbf moves the wait there', () {
      final me = _j([
        _leg(
          'Harburg',
          'Hbf',
          _t(15, 38),
          _t(15, 50),
          name: 'ME',
          product: 'regional',
        ),
      ]);
      final pick = earlierOnwardFor(
        candidates: [me],
        booked: booked,
        readyAt: _t(15, 35),
        following: re7,
      );
      expect(pick, isNotNull);
      expect(pick!.gainMinutes, 21);
      expect(pick.waitThereMinutes, 49);
    });

    test('a train that leaves before the rider is there is not offered', () {
      final early = _j([_leg('Harburg', 'Hbf', _t(15, 31), _t(15, 47))]);
      expect(
        earlierOnwardFor(
          candidates: [early],
          booked: booked,
          readyAt: _t(15, 35),
          following: re7,
        ),
        isNull,
      );
    });

    test('a train that misses the following one is not offered', () {
      final late = _j([_leg('Harburg', 'Hbf', _t(15, 40), _t(16, 37))]);
      expect(
        earlierOnwardFor(
          candidates: [late],
          booked: booked,
          readyAt: _t(15, 35),
          following: re7,
        ),
        isNull,
      );
    });

    test('long distance is never suggested (Zugbindung)', () {
      final ice = _j([
        _leg(
          'Harburg',
          'Hbf',
          _t(15, 40),
          _t(15, 52),
          name: 'ICE 1',
          product: 'nationalExpress',
        ),
      ]);
      expect(
        earlierOnwardFor(
          candidates: [ice],
          booked: booked,
          readyAt: _t(15, 35),
          following: re7,
        ),
        isNull,
      );
    });

    test('splice keeps the following train', () {
      final legs = [
        _leg(
          'Bremen',
          'Harburg',
          _t(14, 33),
          _t(15, 30),
          name: 'RE4',
          product: 'regional',
        ),
        _leg('Harburg', 'Harburg', _t(15, 30), _t(15, 35), walking: true),
        booked,
        _leg('Hbf', 'Hbf', _t(16, 15), _t(16, 20), walking: true),
        re7,
      ];
      final me = _j([
        _leg('Harburg', 'Hbf', _t(15, 38), _t(15, 50), name: 'ME'),
      ]);
      final out = spliceEarlierOnward(legs, 1, 4, me);
      expect(out.map((l) => l.line?.name), ['RE4', 'ME', 'RE7']);
    });
  });

  group('tight chain', () {
    test('two 3-minute changes beat two half-hour waits', () async {
      // What DB answers from each station: its own best, with its own
      // (long) transfer times behind the first train.
      Future<List<Journey>> search(Station from, DateTime at) async {
        if (from.name == 'Harburg') {
          return [
            _j([
              _leg(
                'Harburg',
                'Hbf',
                _t(15, 36),
                _t(15, 48),
                name: 'ME',
                product: 'regional',
              ),
              _leg(
                'Hbf',
                'Kiel',
                _t(16, 39),
                _t(17, 52),
                name: 'RE7',
                product: 'regional',
              ),
            ]),
          ];
        }
        if (from.name == 'Hbf') {
          expect(at, _t(15, 51)); // arrival + 3
          return [
            _j([
              _leg(
                'Hbf',
                'Kiel',
                _t(15, 53),
                _t(17, 9),
                name: 'RE70',
                product: 'regional',
              ),
            ]),
          ];
        }
        return const [];
      }

      final chain = await buildTightChain(
        search: search,
        start: _st('Harburg'),
        readyAt: _t(15, 33),
        tightMinutes: 3,
      );
      expect(chain, isNotNull);
      expect(chain!.legs.where((l) => !l.isWalking).map((l) => l.line?.name), [
        'ME',
        'RE70',
      ]);
      expect(chain.legs.last.arrival, _t(17, 9));
      final c = tightestChange(chain)!;
      expect(c.minutes, 5);
      expect(c.station, 'Hbf');
    });

    test('no answer → no chain', () async {
      final chain = await buildTightChain(
        search: (_, _) async => const [],
        start: _st('Harburg'),
        readyAt: _t(15, 33),
        tightMinutes: 3,
      );
      expect(chain, isNull);
    });
  });
}
