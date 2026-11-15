import 'package:besser_bahn/core/indoor_nav/indoor_route.dart';
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
    expect(r.floorChanges, 2);
    expect(r.segments.where((s) => s.isFloorChange).length, 2);
    expect(r.nodes[1].latLng.latitude, closeTo(53.45614, 1e-4));
    expect(r.walkMetres, inInclusiveRange(250, 350));
    // RE4 from Bremen arrives heading north-east; the stairs are north.
    final steps = r.steps(arrivalBearing: 20);
    expect(steps, [
      'Auf dem Bahnsteig nach vorne (Zugspitze) zur Treppe, runter auf Ebene −2',
      'Ebene −2: ca. 90 m geradeaus zur Treppe, runter auf Ebene −3',
      'Ebene −3: ca. 40 m zu Gleis 11',
    ]);
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
}
