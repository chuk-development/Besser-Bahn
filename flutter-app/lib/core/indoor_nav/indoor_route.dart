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

  /// Route length this segment takes up for progress — a floor change counts
  /// as [floorChangeMetres] so the dot does not jump over it.
  final double cost;

  const IndoorSegment({
    required this.from,
    required this.to,
    required this.metres,
    required this.cost,
  });

  bool get isFloorChange => from.level != to.level;
}

/// What a floor change counts as in progress metres: about the time of a
/// flight of stairs or an escalator ride, at walking speed.
const floorChangeMetres = 15.0;

/// Walking speed for time estimates (m/s). DB plans with about 1.2.
const walkingSpeed = 1.2;

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
    if (a.level != b.level) {
      return IndoorSegment(from: a, to: b, metres: 0, cost: floorChangeMetres);
    }
    final m = _distance.as(LengthUnit.Meter, a.latLng, b.latLng);
    return IndoorSegment(from: a, to: b, metres: m, cost: m);
  }

  /// Total progress length (walk + floor changes).
  double get totalCost => segments.fold(0, (s, x) => s + x.cost);

  /// Metres on foot.
  double get walkMetres => segments.fold(0, (s, x) => s + x.metres);

  /// Estimated time.
  Duration get duration =>
      Duration(seconds: (totalCost / walkingSpeed).round());

  /// The floors the route touches, top to bottom.
  List<String> get usedLevels {
    final used = nodes.map((n) => n.level).toSet();
    return levels.where(used.contains).toList();
  }

  /// Where the rider is at [progress] metres along the route.
  ({LatLng latLng, String level, int segment, double t}) positionAt(
    double progress,
  ) {
    var left = progress.clamp(0, totalCost).toDouble();
    for (var i = 0; i < segments.length; i++) {
      final s = segments[i];
      if (left <= s.cost || i == segments.length - 1) {
        final t = s.cost == 0 ? 1.0 : (left / s.cost).clamp(0.0, 1.0);
        if (s.isFloorChange) {
          // The dot stays at the stairs; the floor flips half way.
          return (
            latLng: s.from.latLng,
            level: t < 0.5 ? s.from.level : s.to.level,
            segment: i,
            t: t,
          );
        }
        return (
          latLng: _lerp(s.from.latLng, s.to.latLng, t),
          level: s.from.level,
          segment: i,
          t: t,
        );
      }
      left -= s.cost;
    }
    final last = nodes.last;
    return (latLng: last.latLng, level: last.level, segment: 0, t: 1);
  }

  /// Progress at the START of segment [i].
  double costBefore(int i) {
    var c = 0.0;
    for (var k = 0; k < i && k < segments.length; k++) {
      c += segments[k].cost;
    }
    return c;
  }

  /// The instruction for [progress]: what to do now, and how far until the
  /// next thing happens.
  ({String text, IndoorManeuver kind, double metresToNext}) maneuverAt(
    double progress,
  ) {
    final pos = positionAt(progress);
    final i = pos.segment;
    final seg = segments[i];
    final segLeft = costBefore(i + 1) - progress.clamp(0, totalCost);
    if (seg.isFloorChange) {
      return (
        text: floorChangeText(seg),
        kind: _connectorKind(seg),
        metresToNext: math.max(0, segLeft),
      );
    }
    final metres = math.max(0, seg.metres * (1 - pos.t)).toDouble();
    final to = seg.to;
    if (to.kind == IndoorNodeKind.target) {
      return (
        text: '${_round(metres)} bis ${to.label ?? 'zum Ziel'}',
        kind: IndoorManeuver.arrive,
        metresToNext: metres,
      );
    }
    final next = i + 1 < segments.length ? segments[i + 1] : null;
    final what = next != null && next.isFloorChange
        ? '${_connectorName(next.from.connectorType)} '
              '${_down(next) ? 'nach unten' : 'nach oben'}'
        : 'zum Durchgang';
    final turn = i > 0 ? _turnWord(segments, i) : null;
    return (
      text: '${turn != null ? '$turn, ' : ''}${_round(metres)} bis zur $what',
      kind: IndoorManeuver.walk,
      metresToNext: metres,
    );
  }

  bool _down(IndoorSegment s) =>
      levels.indexOf(s.to.level) > levels.indexOf(s.from.level);

  String floorChangeText(IndoorSegment s) {
    final dir = _down(s) ? 'runter' : 'hoch';
    final name = _connectorName(s.from.connectorType);
    return '$name $dir auf ${levelLabel(s.to.level)}';
  }

  IndoorManeuver _connectorKind(IndoorSegment s) =>
      switch (s.from.connectorType) {
        'ELEVATOR' => IndoorManeuver.elevator,
        'ESCALATOR' => IndoorManeuver.escalator,
        _ => IndoorManeuver.stairs,
      };
}

/// The icon family of an instruction.
enum IndoorManeuver { walk, stairs, escalator, elevator, arrive }

String _connectorName(String? type) => switch (type) {
  'ELEVATOR' => 'Aufzug',
  'ESCALATOR' => 'Rolltreppe',
  _ => 'Treppe',
};

String _round(double m) {
  if (m < 10) return '${m.round()} m';
  return '${(m / 5).round() * 5} m';
}

/// "links"/"rechts"/null for the bend into segment [i] (walk segments only,
/// across a floor change the rider turns around anyway).
String? _turnWord(List<IndoorSegment> segs, int i) {
  if (i < 1) return null;
  final prev = segs[i - 1];
  // A floor change right before: no meaningful bend.
  if (prev.isFloorChange) return null;
  final a = _distance.bearing(prev.from.latLng, prev.to.latLng);
  final b = _distance.bearing(segs[i].from.latLng, segs[i].to.latLng);
  var d = (b - a) % 360;
  if (d > 180) d -= 360;
  if (d.abs() < 35) return 'Geradeaus';
  return d > 0 ? 'Rechts' : 'Links';
}

LatLng _lerp(LatLng a, LatLng b, double t) => LatLng(
  a.latitude + (b.latitude - a.latitude) * t,
  a.longitude + (b.longitude - a.longitude) * t,
);

/// "EG", "Ebene −2", "OG 1" — the floor as a rider reads it.
String levelLabel(String level) {
  if (level == 'GROUND_FLOOR') return 'EG';
  final b = RegExp(r'^BASEMENT_FLOOR_(\d+)$').firstMatch(level);
  if (b != null) return 'Ebene −${b.group(1)}';
  final u = RegExp(r'^UPPER_FLOOR_(\d+)$').firstMatch(level);
  if (u != null) return 'OG ${u.group(1)}';
  return level;
}

/// Short form for chips: "EG", "−2", "+1".
String levelShort(String level) {
  if (level == 'GROUND_FLOOR') return 'EG';
  final b = RegExp(r'^BASEMENT_FLOOR_(\d+)$').firstMatch(level);
  if (b != null) return '−${b.group(1)}';
  final u = RegExp(r'^UPPER_FLOOR_(\d+)$').firstMatch(level);
  if (u != null) return '+${u.group(1)}';
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
