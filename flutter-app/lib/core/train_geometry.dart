import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

/// Geometry helpers to draw a *top-down train body* that hugs a curved centre
/// line — a platform line on the station map, or a route polyline on the
/// Streckenverlauf. Everything happens in a local equirectangular metre frame
/// so widths, car lengths and nose tapers are honest metres: the train is
/// drawn to scale and bends naturally with the track in curves.
class TrainGeometry {
  const TrainGeometry._();

  /// Outline (a single closed polygon, in LatLng) of a train body whose centre
  /// line follows [spine] (≥2 points), [halfWidthM] metres to each side. Either
  /// end can be shaped into a rounded snout of [noseLenM] metres (e.g. an ICE
  /// driving head); a blunt end is a flat cap.
  static List<LatLng> body(
    List<LatLng> spine, {
    required double halfWidthM,
    bool noseStart = false,
    bool noseEnd = false,
    double noseLenM = 0,
  }) {
    final pts = _dedupe(spine);
    if (pts.length < 2) return const [];

    final lat0 =
        pts.map((p) => p.latitude).reduce((a, b) => a + b) / pts.length;
    final f = _Frame(lat0);
    final v = [for (final p in pts) f.xy(p)];
    final n = v.length;

    // Per-segment unit directions (skip zero-length segments by carrying the
    // last good one), then a per-vertex tangent = mean of its two adjacent
    // segment dirs. This stays well-defined even where slice() drops an
    // interpolated boundary point right next to a real vertex — a naive
    // next-minus-prev there collapses to ~0 and kicks the body sideways.
    final segDir = <math.Point<double>>[];
    var lastDir = const math.Point<double>(1, 0);
    for (var i = 0; i < n - 1; i++) {
      final d = v[i + 1] - v[i];
      if (d.magnitude > 1e-6) lastDir = _norm(d);
      segDir.add(lastDir);
    }
    // Back-fill any leading zero segments with the first good direction.
    for (var i = segDir.length - 2; i >= 0; i--) {
      if ((v[i + 1] - v[i]).magnitude <= 1e-6) segDir[i] = segDir[i + 1];
    }

    math.Point<double> tangentAt(int i) {
      if (i == 0) return segDir.first;
      if (i >= n - 1) return segDir.last;
      return _norm(segDir[i - 1] + segDir[i]);
    }

    final normals = [
      for (var i = 0; i < n; i++)
        () {
          final t = tangentAt(i);
          return math.Point(-t.y, t.x);
        }()
    ];

    final left = [for (var i = 0; i < n; i++) v[i] + normals[i] * halfWidthM];
    final right = [for (var i = 0; i < n; i++) v[i] - normals[i] * halfWidthM];

    final ring = <math.Point<double>>[];
    ring.addAll(left); // start-left … end-left
    if (noseEnd && noseLenM > 0) {
      ring.addAll(_arc(v[n - 1], normals[n - 1], segDir.last, halfWidthM,
          noseLenM,
          plusToMinus: true));
    }
    ring.addAll(right.reversed); // end-right … start-right
    if (noseStart && noseLenM > 0) {
      ring.addAll(_arc(v[0], normals[0], segDir.first * -1.0, halfWidthM,
          noseLenM,
          plusToMinus: false));
    }
    return [for (final p in ring) f.ll(p)];
  }

  /// Total length of [path] in metres.
  static double pathLength(List<LatLng> path) {
    if (path.length < 2) return 0;
    final f = _Frame(path.first.latitude);
    var total = 0.0;
    for (var i = 0; i < path.length - 1; i++) {
      total += (f.xy(path[i + 1]) - f.xy(path[i])).magnitude;
    }
    return total;
  }

  /// The slice of [path] between arc-lengths [startM]…[endM] (metres, clamped
  /// to the path), as a dense LatLng list with interpolated end points — so a
  /// moving train carved out of the route polyline keeps every bend in between.
  static List<LatLng> slice(List<LatLng> path, double startM, double endM) {
    final pts = _dedupe(path);
    if (pts.length < 2) return pts;
    if (endM < startM) {
      final t = startM;
      startM = endM;
      endM = t;
    }
    final f = _Frame(pts.first.latitude);
    final v = [for (final p in pts) f.xy(p)];
    final cum = <double>[0];
    for (var i = 0; i < v.length - 1; i++) {
      cum.add(cum.last + (v[i + 1] - v[i]).magnitude);
    }
    final total = cum.last;
    if (total <= 0) return [pts.first, pts.last];
    startM = startM.clamp(0.0, total);
    endM = endM.clamp(0.0, total);

    math.Point<double> at(double d) {
      for (var i = 0; i < cum.length - 1; i++) {
        if (d <= cum[i + 1]) {
          final segLen = cum[i + 1] - cum[i];
          final t = segLen > 0 ? (d - cum[i]) / segLen : 0.0;
          return v[i] + (v[i + 1] - v[i]) * t;
        }
      }
      return v.last;
    }

    final out = <math.Point<double>>[at(startM)];
    for (var i = 0; i < cum.length; i++) {
      if (cum[i] > startM && cum[i] < endM) out.add(v[i]);
    }
    out.add(at(endM));
    return [for (final p in out) f.ll(p)];
  }

  /// The point at arc-length [distM] (clamped) along [path] — for placing a
  /// label (e.g. a wagon number) at a car's centre on the route.
  static LatLng pointAt(List<LatLng> path, double distM) {
    final pts = _dedupe(path);
    if (pts.isEmpty) return const LatLng(0, 0);
    if (pts.length < 2) return pts.first;
    final f = _Frame(pts.first.latitude);
    final v = [for (final q in pts) f.xy(q)];
    var cum = 0.0;
    for (var i = 0; i < v.length - 1; i++) {
      final len = (v[i + 1] - v[i]).magnitude;
      if (distM <= cum + len) {
        final t = len > 0 ? (distM - cum) / len : 0.0;
        return f.ll(v[i] + (v[i + 1] - v[i]) * t.clamp(0.0, 1.0));
      }
      cum += len;
    }
    return pts.last;
  }

  /// Arc-length (metres from the path start) of the point on [path] nearest to
  /// [p] — used to place a moving train's head on the route polyline.
  static double locate(List<LatLng> path, LatLng p) {
    final pts = _dedupe(path);
    if (pts.length < 2) return 0;
    final f = _Frame(pts.first.latitude);
    final v = [for (final q in pts) f.xy(q)];
    final pp = f.xy(p);
    var cum = 0.0, best = double.infinity, bestArc = 0.0;
    for (var i = 0; i < v.length - 1; i++) {
      final a = v[i], b = v[i + 1];
      final ab = b - a;
      final len2 = ab.x * ab.x + ab.y * ab.y;
      final t = len2 > 0
          ? (((pp.x - a.x) * ab.x + (pp.y - a.y) * ab.y) / len2).clamp(0.0, 1.0)
          : 0.0;
      final proj = a + ab * t;
      final d = (pp - proj).magnitude;
      if (d < best) {
        best = d;
        bestArc = cum + math.sqrt(len2) * t;
      }
      cum += math.sqrt(len2);
    }
    return bestArc;
  }

  // Intermediate points of a half-ellipse snout, strictly between the two body
  // corners (center ± normal·hw), bulging [noseLenM] along [outward].
  static List<math.Point<double>> _arc(
    math.Point<double> center,
    math.Point<double> normal,
    math.Point<double> outward,
    double hw,
    double noseLenM, {
    required bool plusToMinus,
    int steps = 7,
  }) {
    final out = <math.Point<double>>[];
    for (var k = 1; k < steps; k++) {
      final th = math.pi * k / steps;
      // plusToMinus: +hw → −hw (cos: 1→−1). else: −hw → +hw (−cos: −1→1).
      final lat = (plusToMinus ? math.cos(th) : -math.cos(th)) * hw;
      final fwd = math.sin(th) * noseLenM;
      out.add(center + normal * lat + outward * fwd);
    }
    return out;
  }

  static math.Point<double> _norm(math.Point<double> p) {
    final m = p.magnitude;
    return m == 0 ? const math.Point(1.0, 0.0) : p * (1 / m);
  }

  static List<LatLng> _dedupe(List<LatLng> pts) {
    final out = <LatLng>[];
    for (final p in pts) {
      if (out.isEmpty ||
          (out.last.latitude - p.latitude).abs() > 1e-9 ||
          (out.last.longitude - p.longitude).abs() > 1e-9) {
        out.add(p);
      }
    }
    return out;
  }
}

/// Local equirectangular metre frame around a reference latitude.
class _Frame {
  final double mlat, mlon;
  _Frame(double lat0)
      : mlat = 111320.0,
        mlon = 111320.0 * math.cos(lat0 * math.pi / 180);

  math.Point<double> xy(LatLng p) =>
      math.Point(p.longitude * mlon, p.latitude * mlat);
  LatLng ll(math.Point<double> p) => LatLng(p.y / mlat, p.x / mlon);
}
