/// A walk through a station from one Gleis to another, floor by floor.
///
/// There is no indoor router for German stations we can use: DB's own
/// `calculateroute` is an outdoor pedestrian router, the bahnhof.de map has no
/// routing, and the DB Navigator app has none either (checked in the 26.12
/// APK). What bahnhof.de DOES give is every Gleis with its floor and every
/// stair, escalator and lift with its position and floor. That is enough for
/// the question a rider has at a change: which way to the stairs, how many
/// floors, and where the other platform is.
///
/// So the route is planned here: from the arrival Gleis, one floor at a time
/// towards the departure Gleis, each time through the connector that keeps
/// the total walk shortest. Hamburg-Harburg Gleis 5 → Gleis 11 (S-Bahn):
/// platform −1, down to the Schalterhalle Ost −2, along it to the north,
/// down again to the S-Bahn platform −3 — about 300 m.
library;

import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import '../../models/station_map.dart';

const _distance = Distance();

/// What a node of the route is.
enum IndoorNodeKind { start, connector, target }

/// One point of the route on one floor.
class IndoorNode {
  final LatLng latLng;
  final String level;
  final IndoorNodeKind kind;

  /// `STAIR`, `ESCALATOR` or `ELEVATOR` for a connector, else null.
  final String? connectorType;

  /// Label of the POI (e.g. "Gleis 11/12 zu SH Ost"), when it has one.
  final String? label;

  const IndoorNode({
    required this.latLng,
    required this.level,
    required this.kind,
    this.connectorType,
    this.label,
  });
}

/// One piece of the route: a walk on one floor, or a floor change.
class IndoorSegment {
  final IndoorNode from;
  final IndoorNode to;

  /// Metres walked (0 for a floor change).
  final double metres;

  const IndoorSegment({
    required this.from,
    required this.to,
    required this.metres,
  });

  bool get isFloorChange => from.level != to.level;
}

/// The planned route.
class IndoorRoute {
  /// Floors of the station, top to bottom (bahnhof.de order).
  final List<String> levels;
  final List<IndoorNode> nodes;
  final List<IndoorSegment> segments;

  IndoorRoute({required this.levels, required this.nodes})
    : segments = [
        for (var i = 0; i + 1 < nodes.length; i++)
          _segment(nodes[i], nodes[i + 1]),
      ];

  static IndoorSegment _segment(IndoorNode a, IndoorNode b) {
    if (a.level != b.level) return IndoorSegment(from: a, to: b, metres: 0);
    final m = _distance.as(LengthUnit.Meter, a.latLng, b.latLng);
    return IndoorSegment(from: a, to: b, metres: m);
  }

  /// Metres on foot (straight lines between the points, so a lower bound).
  double get walkMetres => segments.fold(0, (s, x) => s + x.metres);

  /// Number of floor changes.
  int get floorChanges => segments.where((s) => s.isFloorChange).length;

  bool _down(IndoorSegment s) =>
      levels.indexOf(s.to.level) > levels.indexOf(s.from.level);

  /// The way as short steps a rider can follow without a map:
  ///
  ///  1. Auf dem Bahnsteig nach vorne (Zugspitze) zur Treppe, runter auf
  ///     Ebene −2
  ///  2. Ebene −2: ca. 90 m geradeaus zur Treppe, runter auf Ebene −3
  ///  3. Ebene −3: ca. 30 m zu Gleis 11
  ///
  /// [arrivalBearing] is the direction the arriving train travelled
  /// (degrees). With it the first walk on the platform says "nach vorne
  /// (Zugspitze)" or "nach hinten" — the one direction a rider stepping off
  /// a train always knows. Its distance is left out: the rider gets off at
  /// their own coach, not at the point bahnhof.de puts the Gleis.
  List<String> steps({double? arrivalBearing}) {
    final out = <String>[];
    double? lastBearing;
    for (var i = 0; i < segments.length; i++) {
      final s = segments[i];
      if (s.isFloorChange) continue;
      final next = i + 1 < segments.length ? segments[i + 1] : null;
      final bearing = _distance.bearing(s.from.latLng, s.to.latLng);
      final first = s.from.kind == IndoorNodeKind.start;
      final String where;
      if (first) {
        final dir = arrivalBearing == null
            ? null
            : _alongTrain(arrivalBearing, bearing);
        where = 'Auf dem Bahnsteig${dir != null ? ' $dir' : ''}';
      } else {
        final straight =
            lastBearing != null && _angle(lastBearing, bearing).abs() < 45;
        final m = s.metres < 15 ? null : 'ca. ${_round10(s.metres)} m';
        where = [
          '${levelLabel(s.from.level)}:',
          ?m,
          if (straight) 'geradeaus',
        ].join(' ');
      }
      final String what;
      if (next != null && next.isFloorChange) {
        final name = _connectorName(next.from.connectorType);
        final label = next.from.label;
        final named = label != null && label != name ? ' „$label“' : '';
        what =
            'zur $name$named, ${_down(next) ? 'runter' : 'hoch'} auf '
            '${levelLabel(next.to.level)}';
      } else {
        what = 'zu ${s.to.label ?? 'deinem Gleis'}';
      }
      out.add('$where $what');
      lastBearing = bearing;
    }
    return out;
  }
}

/// "nach vorne (Zugspitze)" / "nach hinten (Zugende)" / null when the walk
/// goes across.
String? _alongTrain(double trainBearing, double walkBearing) {
  final d = _angle(trainBearing, walkBearing).abs();
  if (d <= 60) return 'nach vorne (Zugspitze)';
  if (d >= 120) return 'nach hinten (Zugende)';
  return null;
}

/// Signed difference b − a in degrees, −180..180.
double _angle(double a, double b) {
  var d = (b - a) % 360;
  if (d > 180) d -= 360;
  if (d < -180) d += 360;
  return d;
}

int _round10(double m) => math.max(10, (m / 10).round() * 10);

String _connectorName(String? type) => switch (type) {
  'ELEVATOR' => 'Aufzug',
  'ESCALATOR' => 'Rolltreppe',
  _ => 'Treppe',
};

/// "EG", "Ebene −2", "OG 1" — the floor as a rider reads it.
String levelLabel(String level) {
  if (level == 'GROUND_FLOOR') return 'EG';
  final b = RegExp(r'^BASEMENT_FLOOR_(\d+)$').firstMatch(level);
  if (b != null) return 'Ebene −${b.group(1)}';
  final u = RegExp(r'^UPPER_FLOOR_(\d+)$').firstMatch(level);
  if (u != null) return 'OG ${u.group(1)}';
  return level;
}

const _connectorTypes = {'STAIR', 'ESCALATOR', 'ELEVATOR'};

/// Plan the walk from [start] to [target] through [map].
///
/// [stepFree] → lifts only (the rider with a pram or a wheelchair); else a
/// lift costs a detour penalty, since stairs and escalators are where the
/// flow goes and a lift has a queue.
///
/// Null when a floor change is needed and no connector exists for it.
IndoorRoute? planIndoorRoute({
  required StationMap map,
  required MapPoi start,
  required MapPoi target,
  bool stepFree = false,
  String? startLabel,
  String? targetLabel,
}) {
  final levels = map.levels;
  final a = start.level ?? map.levelInit;
  final b = target.level ?? map.levelInit;
  final ia = levels.indexOf(a);
  final ib = levels.indexOf(b);
  final nodes = <IndoorNode>[
    IndoorNode(
      latLng: start.latLng,
      level: a,
      kind: IndoorNodeKind.start,
      label: startLabel ?? 'Gleis ${start.name}',
    ),
  ];
  if (ia < 0 || ib < 0) return null;
  var cur = start.latLng;
  var li = ia;
  while (li != ib) {
    final step = ib > li ? 1 : -1;
    final here = levels[li];
    final there = levels[li + step];
    MapPoi? best;
    var bestCost = double.infinity;
    for (final p in map.pois) {
      if (!_connectorTypes.contains(p.type)) continue;
      if (p.level != here && p.level != there) continue;
      if (stepFree && p.type != 'ELEVATOR') continue;
      if (p.status != null && p.status!.toUpperCase() == 'INACTIVE') continue;
      final c =
          _distance.as(LengthUnit.Meter, cur, p.latLng) +
          _distance.as(LengthUnit.Meter, p.latLng, target.latLng) +
          (p.type == 'ELEVATOR' && !stepFree ? 40 : 0);
      if (c < bestCost) {
        bestCost = c;
        best = p;
      }
    }
    if (best == null) return null;
    final label = best.detail?.isNotEmpty == true
        ? best.detail
        : (best.name.isNotEmpty ? best.name : null);
    nodes
      ..add(
        IndoorNode(
          latLng: best.latLng,
          level: here,
          kind: IndoorNodeKind.connector,
          connectorType: best.type,
          label: label,
        ),
      )
      ..add(
        IndoorNode(
          latLng: best.latLng,
          level: there,
          kind: IndoorNodeKind.connector,
          connectorType: best.type,
          label: label,
        ),
      );
    cur = best.latLng;
    li += step;
  }
  nodes.add(
    IndoorNode(
      latLng: target.latLng,
      level: b,
      kind: IndoorNodeKind.target,
      label: targetLabel ?? 'Gleis ${target.name}',
    ),
  );
  return IndoorRoute(levels: levels, nodes: nodes);
}
