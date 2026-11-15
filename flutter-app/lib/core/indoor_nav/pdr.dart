/// Where the rider is on an [IndoorRoute] without GPS.
///
/// Inside a station GPS is gone or tens of metres off. But the route is
/// known, so the position is one number: metres along it. Three phone sensors
/// keep that number right:
///  * accelerometer → steps, each one a stride further;
///  * barometer → floors: one floor is about 0.4 hPa, and a floor change is
///    the one moment the position is known exactly (at the stairs), so it
///    snaps there and wipes out the stride error collected so far;
///  * a good GPS fix where there is one (open platforms) → projected onto the
///    route.
/// The rider can also tap "Ich bin hier" on the map.
library;

import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import 'indoor_route.dart';

/// Steps from raw accelerometer samples (m/s², gravity included).
///
/// Low-pass on the magnitude, then a hysteresis: a step is a rise above
/// [high] after the signal was below [low], at most one per [minGap]. Simple,
/// and it is what pedometers did before step-detector chips existed.
class StepDetector {
  StepDetector({this.high = 10.9, this.low = 9.9, this.minGap = 280});

  final double high;
  final double low;

  /// Milliseconds between two steps at least (≈ 3.5 steps/s running).
  final int minGap;

  double? _smooth;
  bool _armed = true;
  int _lastStepMs = -1 << 30;

  /// Feed one sample; true when it completes a step.
  bool add(int timeMs, double x, double y, double z) {
    final mag = math.sqrt(x * x + y * y + z * z);
    final s = _smooth = _smooth == null
        ? mag
        : _smooth! + 0.3 * (mag - _smooth!);
    if (s < low) _armed = true;
    if (_armed && s > high && timeMs - _lastStepMs >= minGap) {
      _armed = false;
      _lastStepMs = timeMs;
      return true;
    }
    return false;
  }
}

/// Floor changes from barometer samples (hPa).
///
/// Pressure rises going down. Smoothed hard (the barometer is noisy and a
/// door slam is a spike); a change of [perFloor] against the last floor's
/// baseline is one floor.
class FloorChangeDetector {
  FloorChangeDetector({this.perFloor = 0.38});

  final double perFloor;
  double? _smooth;
  double? _base;

  /// Feed one sample; +1 for one floor DOWN, −1 for one floor up, 0 else.
  int add(double hPa) {
    final s = _smooth = _smooth == null
        ? hPa
        : _smooth! + 0.08 * (hPa - _smooth!);
    final base = _base ??= s;
    final d = s - base;
    if (d.abs() < perFloor) return 0;
    final floors = d > 0 ? 1 : -1;
    _base = base + floors * perFloor;
    return floors;
  }
}

/// The rider's progress along [route], in route metres ([IndoorRoute.totalCost]).
class RouteTracker {
  RouteTracker(this.route, {this.strideMetres = 0.72});

  final IndoorRoute route;

  /// Metres per step. 0.72 is an average adult stride at station pace.
  double strideMetres;

  double progress = 0;

  bool get arrived => progress >= route.totalCost - 3;

  /// One step forward. Not across a floor change: the floor change itself
  /// (barometer) or the tap moves the rider past the stairs. Without a
  /// barometer the steps carry on through it.
  void step({bool hasBarometer = true}) {
    final next = progress + strideMetres;
    if (hasBarometer) {
      final pos = route.positionAt(progress);
      final seg = route.segments[pos.segment];
      final end = route.costBefore(pos.segment + 1);
      if (!seg.isFloorChange &&
          pos.segment + 1 < route.segments.length &&
          route.segments[pos.segment + 1].isFloorChange &&
          next > end) {
        // Wait at the stairs until the barometer says we went.
        progress = end;
        return;
      }
    }
    progress = math.min(next, route.totalCost);
  }

  /// The barometer saw [floors] floors (+ down). Snap to the end of the next
  /// floor change in that direction — but only if it is near: a lift ride in
  /// a shop next door must not teleport the dot across the station.
  void floorChanged(int floors, {double window = 150}) {
    if (floors == 0) return;
    for (var i = 0; i < route.segments.length; i++) {
      final s = route.segments[i];
      if (!s.isFloorChange) continue;
      final down =
          route.levels.indexOf(s.to.level) > route.levels.indexOf(s.from.level);
      if (down != floors > 0) continue;
      final start = route.costBefore(i);
      final end = start + s.cost;
      if (end <= progress) continue; // already behind us
      if (start - progress > window) return;
      progress = end;
      return;
    }
  }

  /// A position the rider confirmed or a good GPS fix: jump to the nearest
  /// point of the route on [level] (any floor when null).
  void snapTo(LatLng p, {String? level}) {
    var bestCost = progress;
    var bestDist = double.infinity;
    for (var i = 0; i < route.segments.length; i++) {
      final s = route.segments[i];
      if (s.isFloorChange) continue;
      if (level != null && s.from.level != level) continue;
      final t = _project(s.from.latLng, s.to.latLng, p);
      final q = LatLng(
        s.from.latLng.latitude +
            (s.to.latLng.latitude - s.from.latLng.latitude) * t,
        s.from.latLng.longitude +
            (s.to.latLng.longitude - s.from.latLng.longitude) * t,
      );
      final d = const Distance().as(LengthUnit.Meter, p, q);
      if (d < bestDist) {
        bestDist = d;
        bestCost = route.costBefore(i) + s.cost * t;
      }
    }
    progress = bestCost;
  }
}

/// Where [p] falls on the line a → b, 0..1 (flat-earth, fine for 300 m).
double _project(LatLng a, LatLng b, LatLng p) {
  final k = math.cos(a.latitude * math.pi / 180);
  final ax = a.longitude * k, ay = a.latitude;
  final bx = b.longitude * k, by = b.latitude;
  final px = p.longitude * k, py = p.latitude;
  final dx = bx - ax, dy = by - ay;
  final len = dx * dx + dy * dy;
  if (len == 0) return 0;
  return (((px - ax) * dx + (py - ay) * dy) / len).clamp(0.0, 1.0);
}
