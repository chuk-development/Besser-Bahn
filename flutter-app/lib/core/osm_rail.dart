import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import 'platform_train.dart' show fitLine;

/// Pure, map-agnostic recovery of the **real rail centre-line** a train rides at
/// a platform, straight from OpenStreetMap geometry — the proven technique from
/// the `lib/dev/platform_preview.dart` prototype, lifted out so the production
/// platform-train placement can use it as the curve instead of the unreliable
/// bahnhof.de sector cubes (which are mis-assigned 28–60 m off the platform line
/// and can only be trusted for the A→I *ordering*, not absolute geometry).
///
/// OSM maps platforms as long thin AREA loops tagged with the Gleis pair (`ref`
/// = "7;8") and the tracks as `railway=rail` ways. Given those, plus the trusted
/// cube chain on the wanted Gleis's side (`cubeSide`, used only to pick which of
/// the platform's two long edges faces this track), [osmRailForGleis] returns
/// the rail spine. Empty when OSM lacks the geometry — the caller then falls
/// back to the cube-straight line, so nothing regresses.

/// Resample [path] to [n] points evenly spaced by arc-length. Ported verbatim
/// from the preview's `_resample`.
List<LatLng> _resample(List<LatLng> path, int n) {
  if (path.length < 2) return path;
  final mlon = 111320.0 * math.cos(path.first.latitude * math.pi / 180);
  double d(LatLng a, LatLng b) {
    final dx = (a.longitude - b.longitude) * mlon;
    final dy = (a.latitude - b.latitude) * 111320.0;
    return math.sqrt(dx * dx + dy * dy);
  }

  final cum = <double>[0];
  for (var i = 0; i < path.length - 1; i++) {
    cum.add(cum.last + d(path[i], path[i + 1]));
  }
  final total = cum.last;
  if (total <= 0) return [path.first, path.last];
  final out = <LatLng>[];
  for (var k = 0; k < n; k++) {
    final dd = total * k / (n - 1);
    var i = 0;
    while (i < cum.length - 2 && cum[i + 1] < dd) {
      i++;
    }
    final seg = cum[i + 1] - cum[i];
    final f = seg > 0 ? (dd - cum[i]) / seg : 0.0;
    out.add(LatLng(
      path[i].latitude + (path[i + 1].latitude - path[i].latitude) * f,
      path[i].longitude + (path[i + 1].longitude - path[i].longitude) * f,
    ));
  }
  return out;
}

/// The Gleis-side long edge of an OSM platform AREA. A platform is a long thin
/// loop with one long edge against each track. Split the loop at its two extreme
/// ends into the two long edges and return the one nearer [ref] (the trusted
/// cube chain on the wanted Gleis's side). Ported verbatim from the preview's
/// `_trackSideEdge`.
List<LatLng> _trackSideEdge(List<LatLng> poly, List<LatLng> ref) {
  final loop = poly.toList();
  if (loop.length > 1 &&
      loop.first.latitude == loop.last.latitude &&
      loop.first.longitude == loop.last.longitude) {
    loop.removeLast();
  }
  if (loop.length < 4) return poly;
  final mlon = 111320.0 * math.cos(loop.first.latitude * math.pi / 180);
  math.Point<double> xy(LatLng p) =>
      math.Point(p.longitude * mlon, p.latitude * 111320.0);
  final axis = fitLine([for (final p in loop) xy(p)]);
  if (axis == null) return poly;
  final ts = [
    for (final p in loop)
      (xy(p).x - axis.cx) * axis.dx + (xy(p).y - axis.cy) * axis.dy
  ];
  var iMin = 0, iMax = 0;
  for (var i = 1; i < ts.length; i++) {
    if (ts[i] < ts[iMin]) iMin = i;
    if (ts[i] > ts[iMax]) iMax = i;
  }
  List<LatLng> arc(int a, int b) {
    final out = <LatLng>[];
    var i = a;
    while (true) {
      out.add(loop[i]);
      if (i == b) break;
      i = (i + 1) % loop.length;
    }
    return out;
  }

  const n = 40;
  final e1 = _resample(arc(iMin, iMax), n);
  final e2 = _resample(arc(iMax, iMin), n).reversed.toList();
  if (ref.length < 2) {
    return [
      for (var k = 0; k < n; k++)
        LatLng((e1[k].latitude + e2[k].latitude) / 2,
            (e1[k].longitude + e2[k].longitude) / 2),
    ];
  }
  final m2 = 111320.0 * math.cos(e1.first.latitude * math.pi / 180);
  double d(LatLng a, LatLng b) {
    final dx = (a.longitude - b.longitude) * m2,
        dy = (a.latitude - b.latitude) * 111320.0;
    return math.sqrt(dx * dx + dy * dy);
  }

  double avg(List<LatLng> e) {
    var s = 0.0;
    for (final p in e) {
      var mn = double.infinity;
      for (final r in ref) {
        mn = math.min(mn, d(p, r));
      }
      s += mn;
    }
    return s / e.length;
  }

  return avg(e1) <= avg(e2) ? e1 : e2;
}

/// The Gleis's rail centre-line. The platform [edge] is the LIP; the rail runs
/// ~1–3 m off it, mapped as several short fragments. Gather every OSM rail
/// vertex within 4 m of [edge] (captures this rail, skips the neighbour ~8 m
/// away on the other lip), order them by arc-position along [edge], resample.
/// Ported from the preview's `_railFromEdge`, with one production tweak: when no
/// rail can be recovered it returns EMPTY (not the platform edge), so the caller
/// falls back to the cube line rather than riding the platform lip.
List<LatLng> _railFromEdge(List<LatLng> edge, List<List<LatLng>> rails) {
  if (edge.length < 2 || rails.isEmpty) return const [];
  final mlon = 111320.0 * math.cos(edge.first.latitude * math.pi / 180);
  math.Point<double> xy(LatLng p) =>
      math.Point(p.longitude * mlon, p.latitude * 111320.0);

  ({double dist, double s}) onEdge(math.Point<double> p) {
    var best = double.infinity, bestS = 0.0, acc = 0.0;
    for (var i = 0; i < edge.length - 1; i++) {
      final a = xy(edge[i]), b = xy(edge[i + 1]);
      final ab = b - a;
      final len2 = ab.x * ab.x + ab.y * ab.y;
      final t = len2 > 0
          ? (((p.x - a.x) * ab.x + (p.y - a.y) * ab.y) / len2).clamp(0.0, 1.0)
          : 0.0;
      final proj = math.Point(a.x + ab.x * t, a.y + ab.y * t);
      final dd = (p - proj).magnitude;
      if (dd < best) {
        best = dd;
        bestS = acc + math.sqrt(len2) * t;
      }
      acc += math.sqrt(len2);
    }
    return (dist: best, s: bestS);
  }

  final picked = <({double s, LatLng p})>[];
  for (final r in rails) {
    for (final q in r) {
      final n = onEdge(xy(q));
      if (n.dist <= 4.0) picked.add((s: n.s, p: q));
    }
  }
  if (picked.length < 4) return const [];
  picked.sort((a, b) => a.s.compareTo(b.s));
  return _resample([for (final e in picked) e.p], 60);
}

/// The real rail spine the train rides at [gleis], recovered from OSM
/// [platforms] (long thin AREA loops tagged with the Gleis pair) + [rails]
/// (`railway=rail` ways). [cubeSide] is the trusted sector-cube chain on this
/// Gleis's side — used only to pick which of the platform's two long edges faces
/// the wanted track. Returns an empty list when the geometry is unavailable so
/// the caller can fall back to the cube-straight line.
List<LatLng> osmRailForGleis({
  required List<({String ref, List<LatLng> pts})> platforms,
  required List<List<LatLng>> rails,
  required String gleis,
  required List<LatLng> cubeSide,
}) {
  // OSM tags double-track island platforms with the track pair ("7;8"); match
  // the wanted Gleis against either member.
  final plat = platforms.where((p) => p.ref.split(';').contains(gleis)).toList();
  if (plat.isEmpty) return const [];
  final rail = _railFromEdge(_trackSideEdge(plat.first.pts, cubeSide), rails);
  // _railFromEdge returns the edge itself when it can't find ≥4 nearby rail
  // vertices; treat "couldn't recover a rail" as unavailable so we fall back.
  if (rail.length < 2) return const [];
  return rail;
}
