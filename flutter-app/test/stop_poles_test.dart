import 'package:besser_bahn/core/stop_poles.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

/// Real coordinates from ZOB Kiel. OSM signs these poles A1…A5/B1…B3 (the same
/// codes on the real signs, and the codes DB puts in a leg's Gleis); DELFI
/// numbers the same poles 1/7/11 internally.
const _osmA4 = LatLng(54.31731, 10.13369);
const _osmA5 = LatLng(54.31748, 10.13383);
const _osmB3 = LatLng(54.31709, 10.13366);
const _delfi1 = LatLng(54.31729, 10.13371); // 2 m from OSM A4
const _delfi11 = LatLng(54.31747, 10.13384); // 2 m from OSM A5
const _delfi7 = LatLng(54.31709, 10.13371); // 4 m from OSM B3

StopPole _osm(String bay, LatLng at) =>
    StopPole(latLng: at, name: 'Kiel ZOB', bay: bay, shelter: true);
StopPole _delfi(String bay, LatLng at, List<String> dirs) =>
    StopPole(latLng: at, name: 'Kiel ZOB', bay: bay, directions: dirs);

void main() {
  group('#55 — merging the two sources', () {
    test('the same pole from both sources becomes one', () {
      final merged = mergePoles(
        [_osm('A4', _osmA4), _osm('A5', _osmA5), _osm('B3', _osmB3)],
        [
          _delfi('1', _delfi1, ['740 → Kiel ZOB']),
          _delfi('11', _delfi11, ['201 → Schönberg']),
          _delfi('7', _delfi7, ['743 → Gettorf']),
        ],
      );
      expect(merged, hasLength(3), reason: 'three physical poles, not six');
    });

    test('the signed code wins over DELFI\'s internal numbering', () {
      // The sign says A5, DELFI calls it 11 — the rider is looking for A5, and
      // that is also what DB puts in the leg.
      final merged = mergePoles(
        [_osm('A5', _osmA5)],
        [_delfi('11', _delfi11, ['201 → Schönberg'])],
      );
      expect(merged.single.bay, 'A5');
      expect(merged.single.directions, ['201 → Schönberg'],
          reason: 'the direction still comes from DELFI');
    });

    test('a pole only one source knows is kept', () {
      // OSM tags no bay at Wittenberger Passau; DELFI has both poles. Dropping
      // one would hide a pole the rider might be standing at.
      final merged = mergePoles(
        [StopPole(latLng: const LatLng(54.29029, 10.38406), name: 'B202')],
        [
          _delfi('1', const LatLng(54.29077, 10.38255), ['Kiel']),
          _delfi('2', const LatLng(54.2903, 10.38412), ['Schönberg']),
        ],
      );
      expect(merged, hasLength(3 - 1),
          reason: 'the OSM pole merges with DELFI Steig 2, Steig 1 is its own');
      expect(merged.map((p) => p.bay).toList(), ['1', '2']);
    });

    test('either source alone still yields a map', () {
      expect(mergePoles([_osm('A4', _osmA4)], const []), hasLength(1));
      expect(mergePoles(const [], [_delfi('1', _delfi1, const [])]),
          hasLength(1));
      expect(mergePoles(const [], const []), isEmpty);
    });

    test('poles sort by bay code, unlabelled last', () {
      final merged = mergePoles([
        _osm('B1', const LatLng(54.3165, 10.13322)),
        StopPole(latLng: const LatLng(54.3160, 10.1330), name: 'Kiel ZOB'),
        _osm('A1', const LatLng(54.31671, 10.13323)),
      ], const []);
      expect(merged.map((p) => p.bay).toList(), ['A1', 'B1', null]);
    });
  });

  group('#55 — finding the rider\'s own pole', () {
    final poles = mergePoles(
      [_osm('A4', _osmA4), _osm('A5', _osmA5), _osm('B3', _osmB3)],
      [_delfi('1', _delfi1, const ['740 → Kiel ZOB'])],
    );

    test('the leg\'s Gleis picks the pole with that code', () {
      // "Dein Einstieg: Gleis A4" → that exact pole, 90 m from A1.
      expect(poleForGleis(poles, 'A4')?.latLng, _osmA4);
      expect(poleForGleis(poles, 'A5')?.latLng, _osmA5);
    });

    test('spacing and case do not matter', () {
      expect(poleForGleis(poles, 'a4')?.bay, 'A4');
      expect(poleForGleis(poles, ' A 4 ')?.bay, 'A4');
    });

    test('an unknown code marks nothing rather than the nearest pole', () {
      // Marking the wrong pole is worse than marking none: the rider would
      // cross the road for it.
      expect(poleForGleis(poles, 'C9'), isNull);
      expect(poleForGleis(poles, null), isNull);
      expect(poleForGleis(poles, ''), isNull);
    });
  });

  test('metresBetween is right at pole distances', () {
    // A4 → A5 is one bay apart at ZOB Kiel.
    expect(metresBetween(_osmA4, _osmA5), closeTo(20, 4));
    expect(metresBetween(_osmA4, _delfi1), lessThan(kSamePoleMetres));
  });
}
