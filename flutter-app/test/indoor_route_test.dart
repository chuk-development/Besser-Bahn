import 'dart:math' as math;

import 'package:besser_bahn/core/indoor_nav/indoor_route.dart';
import 'package:besser_bahn/core/indoor_nav/pdr.dart';
import 'package:besser_bahn/models/station_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

/// Hamburg-Harburg as bahnhof.de had it on 2026-11-15 (a subset).
StationMap _harburg() => const StationMap(
  slug: 'hamburg-harburg',
  center: LatLng(53.45696, 9.991454),
  levels: [
    'UPPER_FLOOR_1',
    'GROUND_FLOOR',
    'BASEMENT_FLOOR_1',
    'BASEMENT_FLOOR_2',
    'BASEMENT_FLOOR_3',
  ],
  levelInit: 'GROUND_FLOOR',
  pois: [
    MapPoi(
      type: 'PLATFORM',
      name: '5',
      level: 'BASEMENT_FLOOR_1',
      latitude: 53.4544512,
      longitude: 9.99209858,
    ),
    MapPoi(
      type: 'PLATFORM',
      name: '11',
      level: 'BASEMENT_FLOOR_3',
      latitude: 53.45689854,
      longitude: 9.99110156,
    ),
    // Platform 5/6 stairs, north end.
    MapPoi(
      type: 'STAIR',
      name: 'Treppe',
      level: 'BASEMENT_FLOOR_1',
      latitude: 53.45614233,
      longitude: 9.99168318,
    ),
    // Far away on −1 (Busbahnhof side) — must not win.
    MapPoi(
      type: 'STAIR',
      name: 'Treppe',
      level: 'BASEMENT_FLOOR_1',
      latitude: 53.45728688,
      longitude: 9.98972533,
    ),
    // Down to the S-Bahn.
    MapPoi(
      type: 'STAIR',
      name: 'Treppe',
      level: 'BASEMENT_FLOOR_3',
      latitude: 53.45692738,
      longitude: 9.99164806,
    ),
    MapPoi(
      type: 'ELEVATOR',
      name: 'Aufzug',
      level: 'BASEMENT_FLOOR_2',
      latitude: 53.45706,
      longitude: 9.99026,
    ),
  ],
);

void main() {
  final map = _harburg();
  MapPoi gleis(String n) => map.platforms.firstWhere((p) => p.name == n);

  test('Harburg Gleis 5 → 11: two floors down, via the near stairs', () {
    final r = planIndoorRoute(
      map: map,
      start: gleis('5'),
      target: gleis('11'),
    )!;
    expect(r.usedLevels, [
      'BASEMENT_FLOOR_1',
      'BASEMENT_FLOOR_2',
      'BASEMENT_FLOOR_3',
    ]);
    expect(r.segments.where((s) => s.isFloorChange).length, 2);
    expect(r.nodes[1].latLng.latitude, closeTo(53.45614, 1e-4));
    expect(r.walkMetres, inInclusiveRange(250, 350));
    expect(r.maneuverAt(0).text, contains('Treppe nach unten'));
    expect(r.maneuverAt(r.totalCost - 1).kind, IndoorManeuver.arrive);
  });

  test('step-free takes the lift', () {
    final r = planIndoorRoute(
      map: map,
      start: gleis('5'),
      target: gleis('11'),
      stepFree: true,
    );
    // Only one lift, on −2: −1 → −2 works through it, −2 → −3 too.
    expect(r, isNotNull);
    expect(
      r!.nodes
          .where((n) => n.connectorType != null)
          .every((n) => n.connectorType == 'ELEVATOR'),
      isTrue,
    );
  });

  test('steps stop at the stairs until the barometer says down', () {
    final r = planIndoorRoute(
      map: map,
      start: gleis('5'),
      target: gleis('11'),
    )!;
    final t = RouteTracker(r);
    for (var i = 0; i < 1000; i++) {
      t.step();
    }
    expect(t.progress, closeTo(r.costBefore(1), 0.01));
    t.floorChanged(1);
    expect(t.progress, closeTo(r.costBefore(2), 0.01));
    expect(r.positionAt(t.progress).level, 'BASEMENT_FLOOR_2');
  });

  test('a floor change far ahead is ignored', () {
    final r = planIndoorRoute(
      map: map,
      start: gleis('5'),
      target: gleis('11'),
    )!;
    final t = RouteTracker(r)..floorChanged(1, window: 50);
    expect(t.progress, 0);
  });

  test('step detector counts a walking signal', () {
    final d = StepDetector();
    var steps = 0;
    // 2 steps per second for 5 s, ±2 m/s² around g.
    for (var ms = 0; ms < 5000; ms += 20) {
      final a = 9.81 + 2.2 * math.sin(ms / 500 * 2 * math.pi);
      if (d.add(ms, 0, 0, a)) steps++;
    }
    expect(steps, inInclusiveRange(9, 11));
  });

  test('barometer: +0.4 hPa is one floor down', () {
    final f = FloorChangeDetector();
    var floors = 0;
    for (var i = 0; i < 200; i++) {
      floors += f.add(1013.0 + (i > 50 ? 0.42 : 0));
    }
    expect(floors, 1);
  });
}
