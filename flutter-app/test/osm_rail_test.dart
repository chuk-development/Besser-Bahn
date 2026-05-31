import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:besser_bahn/core/osm_rail.dart';
import 'package:besser_bahn/core/platform_train.dart';
import 'package:besser_bahn/services/station_map_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

/// The proven OSM-rail recovery (the dev preview's technique, now in
/// core/osm_rail.dart) must produce the real Gleis-7 rail spine from the
/// Hamburg OSM fixture, anchored on the bahnhof.de cube side.
void main() {
  ({List<({String ref, List<LatLng> pts})> platforms, List<List<LatLng>> rails})
      loadOsm() {
    final osm = json.decode(
        File('test/fixtures/hamburg-osm.json').readAsStringSync()) as Map;
    final platforms = [
      for (final p in (osm['platforms'] as List))
        (
          ref: p['ref'] as String,
          pts: [
            for (final q in (p['pts'] as List))
              LatLng((q['lat'] as num).toDouble(), (q['lng'] as num).toDouble())
          ],
        ),
    ];
    final rails = [
      for (final r in (osm['rails'] as List))
        [
          for (final q in (r['pts'] as List))
            LatLng((q['lat'] as num).toDouble(), (q['lng'] as num).toDouble())
        ],
    ];
    return (platforms: platforms, rails: rails);
  }

  test('osmRailForGleis recovers the Gleis-7 rail spine from the OSM fixture',
      () {
    final osm = loadOsm();
    final map = parseStationMapBody('hamburg-hbf',
        File('test/fixtures/hamburg-hbf.rsc.txt').readAsStringSync());

    // The trusted cube chain on Gleis 7's side (resolved by the production
    // helper) tells which of the platform's two long edges faces track 7.
    final cubeSide = platformCubeSide(map, '7');
    expect(cubeSide.length, greaterThanOrEqualTo(2),
        reason: 'need the Gleis-7 cube chain as the side reference');

    final rail = osmRailForGleis(
      platforms: osm.platforms,
      rails: osm.rails,
      gleis: '7',
      cubeSide: cubeSide,
    );

    // A real platform rail is a long, smooth line of many points.
    expect(rail.length, greaterThanOrEqualTo(2));

    // Total arc-length is a full platform (Hamburg Hbf's are ~400 m), not a
    // degenerate stub.
    final mlon = 111320.0 * math.cos(rail.first.latitude * math.pi / 180);
    var len = 0.0;
    for (var i = 0; i < rail.length - 1; i++) {
      final dx = (rail[i + 1].longitude - rail[i].longitude) * mlon;
      final dy = (rail[i + 1].latitude - rail[i].latitude) * 111320.0;
      len += math.sqrt(dx * dx + dy * dy);
    }
    expect(len, greaterThan(100.0),
        reason: 'the Gleis-7 rail spine should span much of the platform');

    // It must sit close to the trusted cube side (same track, not the
    // neighbour's): every cube is within a few metres of the recovered rail.
    final railPath = [for (final p in rail) p];
    double nearest(LatLng p) {
      var best = double.infinity;
      for (final r in railPath) {
        final dx = (p.longitude - r.longitude) * mlon;
        final dy = (p.latitude - r.latitude) * 111320.0;
        best = math.min(best, math.sqrt(dx * dx + dy * dy));
      }
      return best;
    }

    final maxGap = cubeSide.map(nearest).reduce(math.max);
    expect(maxGap, lessThan(40.0),
        reason: 'recovered rail should run alongside the Gleis-7 cube side');
  });

  test('osmRailForGleis returns empty for an unknown Gleis', () {
    final osm = loadOsm();
    final rail = osmRailForGleis(
      platforms: osm.platforms,
      rails: osm.rails,
      gleis: '999',
      cubeSide: const [],
    );
    expect(rail, isEmpty);
  });
}
