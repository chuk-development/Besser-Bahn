import 'package:besser_bahn/core/stop_poles.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

/// Wittenberger Passau B202, Martensrade — the stop from #55 that has no bay
/// codes at all. Two poles on the Kieler Straße, which runs roughly west
/// (Kiel) to east (Oldenburg). North pole serves the Kiel direction, south
/// pole the Oldenburg one — real coordinates and real headsigns.
const _stop = LatLng(54.29053, 10.38333);
const _north = LatLng(54.29081, 10.38246);
const _south = LatLng(54.29029, 10.38406);
const _kiel = LatLng(54.3149, 10.1318); // roughly west
const _oldenburg = LatLng(54.2949, 10.8879); // roughly east

List<StopPole> _passau() => const [
      StopPole(
        latLng: _north,
        name: 'Wittenberger Passau, B202',
        directions: ['310 → Kiel ZOB', '315 → Kiel ZOB'],
      ),
      StopPole(
        latLng: _south,
        name: 'Wittenberger Passau, B202',
        directions: [
          '310 → Oldenburg (Holstein), Markt',
          '315 → Lütjenburg ZOB',
        ],
      ),
    ];

/// ZOB Kiel: signed bays, so the code decides and nothing else has to.
List<StopPole> _zob() => const [
      StopPole(
        latLng: LatLng(54.31731, 10.13369),
        name: 'Kiel ZOB',
        bay: 'A4',
        directions: ['300 → Raisdorf, Bahnhof'],
      ),
      StopPole(
        latLng: LatLng(54.31748, 10.13383),
        name: 'Kiel ZOB',
        bay: 'A5',
        directions: ['210 → Schönberg'],
      ),
    ];

void main() {
  group('#55 — picking the rider\'s pole when nothing is signed', () {
    test('the bay code wins whenever there is one', () {
      final picked = pickPole(_zob(), gleis: 'A4', line: '210',
          towardsName: 'Schönberg');
      expect(picked?.pole.bay, 'A4');
      expect(picked?.how, PoleMatch.bay,
          reason: 'the ticket says A4 — nothing else needs asking');
    });

    test('line + destination pick the pole where that ride departs', () {
      // Riding towards Oldenburg → the south pole, even though neither is
      // signed.
      final picked = pickPole(_passau(),
          line: '310', towardsName: 'Oldenburg (Holstein), Markt');
      expect(picked?.pole.latLng, _south);
      expect(picked?.how, PoleMatch.route);

      final back = pickPole(_passau(), line: '310', towardsName: 'Kiel ZOB');
      expect(back?.pole.latLng, _north);
    });

    test('the destination is matched loosely — spellings differ', () {
      // Timetable "Kiel, ZOB" vs headsign "Kiel ZOB".
      expect(
        pickPole(_passau(), line: '310', towardsName: 'Kiel, ZOB')?.pole.latLng,
        _north,
      );
      // Only the leading place name is known ("Oldenburg").
      expect(
        pickPole(_passau(), line: '310', towardsName: 'Oldenburg')?.pole.latLng,
        _south,
      );
    });

    test('a line that contradicts the pole is not accepted', () {
      // Line 315 does not go to Oldenburg; nothing may be marked from that.
      expect(
        poleForRoute(_passau(), line: '315', towardsName: 'Oldenburg'),
        isNull,
      );
    });

    test('with no line at all, the destination alone still decides', () {
      expect(poleForRoute(_passau(), towardsName: 'Lütjenburg ZOB')?.latLng,
          _south);
    });

    test('the side of the road answers it when the timetable does not', () {
      // No bay code, no usable direction — but we know the bus continues east
      // towards Oldenburg, and buses stop on the right.
      final picked =
          pickPole(_bare(), stop: _stop, nextStop: _oldenburg);
      expect(picked?.pole.latLng, _south);
      expect(picked?.how, PoleMatch.side);

      // Coming the other way, it is the other pole.
      expect(
        pickPole(_bare(), stop: _stop, nextStop: _kiel)?.pole.latLng,
        _north,
      );
    });

    test('the side rule refuses when it cannot separate the poles', () {
      // Both poles on the same side of the line of travel → no answer.
      const sameSide = [
        StopPole(latLng: LatLng(54.29081, 10.38246), name: 'x'),
        StopPole(latLng: LatLng(54.29085, 10.38250), name: 'y'),
      ];
      expect(
        poleOnTravelSide(sameSide, stop: _stop, nextStop: _oldenburg),
        isNull,
      );
      // Next stop practically on top of this one → no direction to speak of.
      expect(
        poleOnTravelSide(_bare(),
            stop: _stop, nextStop: const LatLng(54.29055, 10.38335)),
        isNull,
      );
    });

    test('nothing to go on marks nothing', () {
      expect(pickPole(_bare()), isNull);
      expect(pickPole(const []), isNull);
      expect(pickPole(_passau(), line: '999', towardsName: 'Timbuktu'), isNull);
    });
  });
}

/// The same two poles, stripped of everything but their position.
List<StopPole> _bare() => const [
      StopPole(latLng: _north, name: 'Wittenberger Passau, B202'),
      StopPole(latLng: _south, name: 'Wittenberger Passau, B202'),
    ];
