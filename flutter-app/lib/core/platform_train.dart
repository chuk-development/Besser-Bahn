import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import '../core/app_log.dart';
import '../models/coach_sequence.dart';
import '../models/station_map.dart';
import 'train_dimensions.dart';
import 'train_geometry.dart';

/// Pure, map-agnostic placement of a to-scale top-down train on a station
/// platform — shared by the Bahnhofskarte (single boarding/Ausstieg train,
/// driven from [StationMapState]) and the Streckenverlauf big route map (a
/// parked train standing on EVERY stop's Gleis).
///
/// All the geometry lives here so there is exactly ONE implementation: anchor
/// the Wagenreihung's `platform.sectors` (A–I metre offsets) to the real
/// `PLATFORM_SECTOR_CUBE` POIs, group tracks into platform islands from the
/// lift/escalator anchors, fit each island's straight principal axis, then map
/// each car onto that axis by an offset→axis least-squares regression. A
/// straight axis (not a chain of noisy cube points) keeps the train clean and
/// parallel to the track — no spurious kink at the far end.

/// A–I letter index (0–8) of a single-letter section name, else null.
int? letterIdx(String n) {
  final t = n.trim().toUpperCase();
  if (t.length != 1) return null;
  final code = t.codeUnitAt(0);
  return (code >= 65 && code <= 73) ? code - 65 : null;
}

/// Normalise a track label to its base id ("6A-C" → "6", "2 A-C" → "2").
String normalizeGleis(String g) {
  g = g.trim();
  if (g.isEmpty) return g;
  if (RegExp(r'^\d').hasMatch(g)) {
    return RegExp(r'^\d+').firstMatch(g)!.group(0)!;
  }
  return g.split(RegExp(r'\s+')).first.toUpperCase();
}

/// Parse the platform-section range from a track label's letter suffix:
/// "7 C-G" → (C,G); "13D-F" → (D,F); "7D" → (D,D); "7"/"" → null.
/// Reversed ranges ("G-C") are normalised to start ≤ end. Sectors are A–I.
({String start, String end})? parseGleisSection(String g) {
  final u = g.toUpperCase();
  final range = RegExp(r'([A-I])\s*-\s*([A-I])').firstMatch(u);
  if (range != null) {
    var a = range.group(1)!, b = range.group(2)!;
    if (a.compareTo(b) > 0) {
      final t = a;
      a = b;
      b = t;
    }
    return (start: a, end: b);
  }
  final single = RegExp(r'^\d+\s*([A-I])$').firstMatch(u.trim());
  if (single != null) return (start: single.group(1)!, end: single.group(1)!);
  return null;
}

/// A 2-D line (centroid + unit direction) for platform-island axes.
class PlatformLine {
  final double cx, cy, dx, dy;
  const PlatformLine(this.cx, this.cy, this.dx, this.dy);

  /// Perpendicular distance from point [p] to this infinite line.
  double perpDistance(math.Point<double> p) =>
      ((p.x - cx) * (-dy) + (p.y - cy) * dx).abs();
}

/// Least-squares principal-axis line through [pts] (≥2 points), via the major
/// eigenvector of the 2×2 covariance matrix.
PlatformLine? fitLine(List<math.Point<double>> pts) {
  if (pts.length < 2) return null;
  final n = pts.length;
  var cx = 0.0, cy = 0.0;
  for (final p in pts) {
    cx += p.x;
    cy += p.y;
  }
  cx /= n;
  cy /= n;
  var cxx = 0.0, cxy = 0.0, cyy = 0.0;
  for (final p in pts) {
    final ddx = p.x - cx, ddy = p.y - cy;
    cxx += ddx * ddx;
    cxy += ddx * ddy;
    cyy += ddy * ddy;
  }
  final tr = cxx + cyy;
  final l1 =
      tr / 2 + math.sqrt(math.max(tr * tr / 4 - (cxx * cyy - cxy * cxy), 0.0));
  double dx, dy;
  if (cxy.abs() > 1e-9) {
    dx = l1 - cyy;
    dy = cxy;
  } else {
    dx = cxx >= cyy ? 1 : 0;
    dy = cxx >= cyy ? 0 : 1;
  }
  final nn = math.sqrt(dx * dx + dy * dy);
  if (nn == 0) return null;
  return PlatformLine(cx, cy, dx / nn, dy / nn);
}

/// The boarding-Gleis platform island, resolved once: the real sector cubes
/// (letter index → LatLng) for letters [startIdx]…[endIdx], plus the metre
/// nudge (`dLat`,`dLon`) from the platform centre toward the boarding rail, and
/// the island's robust [axis]. Shared by the section line/markers and the
/// to-scale platform train so they land on the same side of the platform.
///
/// The `PLATFORM_SECTOR_CUBE` POIs carry NO track reference and platforms fan
/// out, so we group tracks into islands from the lift/escalator anchors (which
/// DO name the Gleise they serve), fit each island's axis, then assign every
/// cube to the island whose line it lies closest to. Falls back to
/// nearest-cube-per-letter when a station has no usable anchors.
({
  List<({int idx, LatLng pos})> cubes,
  double dLat,
  double dLon,
  PlatformLine? axis,
}) resolveIsland(StationMap map, MapPoi plat, String g, int startIdx,
    int endIdx) {
  const empty = (
    cubes: <({int idx, LatLng pos})>[],
    dLat: 0.0,
    dLon: 0.0,
    axis: null,
  );

  final level = plat.level ?? '';
  var cubes = map.poisOnLevel(level).where((p) => p.isPlatformSector).toList();
  // Some stations (e.g. Neumünster) carry the Gleis label on a concourse level
  // while the actual platform SECTOR_CUBE markers live on the track level — so
  // the platform's own level has no cubes. Fall back to wherever the cubes
  // actually are (the level with the most of them = the track level), so we
  // still place the train instead of giving up with "<2 cubes".
  if (cubes.length < 2) {
    final byLevel = <String, List<MapPoi>>{};
    for (final p in map.pois.where((p) => p.isPlatformSector)) {
      (byLevel[p.level ?? ''] ??= []).add(p);
    }
    if (byLevel.isNotEmpty) {
      final best = byLevel.entries
          .reduce((a, b) => b.value.length > a.value.length ? b : a);
      cubes = best.value;
    }
  }
  if (cubes.length < 2) return empty;

  // Planar metres around the floor (equirectangular).
  final lat0 =
      cubes.map((c) => c.latitude).reduce((a, b) => a + b) / cubes.length;
  const mlat = 111320.0;
  final mlon = 111320.0 * math.cos(lat0 * math.pi / 180);
  math.Point<double> xy(double lat, double lon) =>
      math.Point(lon * mlon, lat * mlat);

  // 1) Group tracks into islands from the lift/escalator anchors.
  final gleiseByKey = <String, Set<String>>{};
  final ptsByKey = <String, List<math.Point<double>>>{};
  for (final a in map.platformAnchors) {
    final key = (a.gleise.toList()..sort()).join('/');
    gleiseByKey[key] = a.gleise;
    (ptsByKey[key] ??= []).add(xy(a.latitude, a.longitude));
  }
  gleiseByKey.forEach((key, gleise) {
    for (final p in map.platforms) {
      if (gleise.contains(normalizeGleis(p.name))) {
        ptsByKey[key]!.add(xy(p.latitude, p.longitude));
      }
    }
  });

  String? ourKey;
  gleiseByKey.forEach((key, gleise) {
    if (gleise.contains(g)) ourKey = key;
  });

  // 2) Fit an axis line per island (centroid + principal direction).
  final lines = <String, PlatformLine>{};
  ptsByKey.forEach((key, pts) {
    final l = fitLine(pts);
    if (l != null) lines[key] = l;
  });

  // 3) Pick one cube per requested letter, disambiguating to our island.
  const dist = Distance();
  final byLetter = <int, List<MapPoi>>{};
  for (final c in cubes) {
    final li = letterIdx(c.name);
    if (li == null || li < startIdx || li > endIdx) continue;
    (byLetter[li] ??= []).add(c);
  }

  MapPoi? pickFor(List<MapPoi> cands) {
    if (cands.length == 1) return cands.first;
    if (ourKey != null && lines[ourKey] != null) {
      MapPoi? best;
      var bd = double.infinity;
      for (final c in cands) {
        final pt = xy(c.latitude, c.longitude);
        String? nearest;
        var nd = double.infinity;
        lines.forEach((key, l) {
          final d = l.perpDistance(pt);
          if (d < nd) {
            nd = d;
            nearest = key;
          }
        });
        if (nearest == ourKey && nd < bd) {
          bd = nd;
          best = c;
        }
      }
      if (best != null) return best;
    }
    MapPoi? best;
    var bd = double.infinity;
    for (final c in cands) {
      final d = dist(c.latLng, plat.latLng);
      if (d < bd) {
        bd = d;
        best = c;
      }
    }
    return best;
  }

  final out = <({int idx, LatLng pos})>[];
  for (var i = startIdx; i <= endIdx; i++) {
    final cands = byLetter[i];
    if (cands == null || cands.isEmpty) continue;
    final c = pickFor(cands);
    if (c != null) out.add((idx: i, pos: c.latLng));
  }
  if (out.isEmpty) return empty;

  // Nudge from the platform centre toward the boarding rail.
  var dLat = 0.0, dLon = 0.0;
  final partner = _islandPartner(map, plat, level, g, gleiseByKey, ourKey);
  if (partner != null) {
    final ex = (plat.longitude - partner.longitude) * mlon;
    final ey = (plat.latitude - partner.latitude) * mlat;
    final norm = math.sqrt(ex * ex + ey * ey);
    if (norm > 0.5) {
      final shift = math.min(6.0, norm * 0.45); // metres toward the Gleis
      dLon = ex / norm * shift / mlon;
      dLat = ey / norm * shift / mlat;
    }
  }
  // The island's robust axis (fit through the lift/escalator anchors + this
  // island's Gleis markers) is the platform's true direction — far steadier
  // than fitting through the few resolved cubes, which can sit slightly off
  // and tilt the train. Fall back to the cube fit only when no island axis.
  final axis = (ourKey != null ? lines[ourKey] : null) ??
      fitLine([for (final c in out) xy(c.pos.latitude, c.pos.longitude)]);
  return (cubes: out, dLat: dLat, dLon: dLon, axis: axis);
}

/// The OTHER track of the boarding Gleis's island (e.g. 8 when boarding 7) —
/// from the island grouping if known, else the nearest other platform.
MapPoi? _islandPartner(
  StationMap m,
  MapPoi plat,
  String level,
  String g,
  Map<String, Set<String>> gleiseByKey,
  String? ourKey,
) {
  if (ourKey != null) {
    final mates = gleiseByKey[ourKey]!.where((x) => x != g).toSet();
    for (final p in m.platforms) {
      if ((p.level ?? '') == level && mates.contains(normalizeGleis(p.name))) {
        return p;
      }
    }
  }
  const dist = Distance();
  MapPoi? best;
  var bd = double.infinity;
  for (final p in m.platforms) {
    if ((p.level ?? '') != level || normalizeGleis(p.name) == g) continue;
    final d = dist(p.latLng, plat.latLng);
    if (d < bd) {
      bd = d;
      best = p;
    }
  }
  return best;
}

/// The real sector cubes (A–I) of [range], in letter order, resolved onto
/// [plat]'s platform island (with the boarding-rail nudge applied) — the line
/// of labelled markers exactly where the rider should stand. Empty when the
/// inputs are incomplete or the island can't be resolved.
List<({String letter, LatLng pos})> platformSectionLine(
  StationMap map,
  MapPoi plat,
  ({String start, String end})? range,
  String g, {
  List<LatLng>? osmRail,
}) {
  if (range == null) return const [];
  final start = letterIdx(range.start);
  final end = letterIdx(range.end);
  if (start == null || end == null) return const [];
  final island = resolveIsland(map, plat, g, start, end);
  // With OSM rail geometry, snap each sector's nudged cube onto the real track
  // so the band sits exactly on the rail; without it, keep the cube positions
  // unchanged (the existing behaviour).
  final curve =
      (osmRail != null && osmRail.length >= 2) ? RoutePath.build(osmRail) : null;
  return [
    for (final c in island.cubes)
      (
        letter: String.fromCharCode(65 + c.idx),
        pos: curve == null
            ? LatLng(c.pos.latitude + island.dLat,
                c.pos.longitude + island.dLon)
            : curve.pointAt(curve.locate(_nudgedCube(island, c.pos))),
      ),
  ];
}

/// The level that carries the platform SECTOR_CUBE markers — i.e. the floor
/// whose plan actually shows the Gleise (the "track level"). Some stations put
/// a Gleis label on a concourse floor, so this picks the level with the most
/// sector cubes; falls back to the station's initial level. Used to show the
/// correct indoor floor plan and to read the Gleis/sector data from it.
String? trackLevel(StationMap map) {
  final byLevel = <String, int>{};
  for (final p in map.pois.where((p) => p.isPlatformSector)) {
    final l = p.level ?? '';
    byLevel[l] = (byLevel[l] ?? 0) + 1;
  }
  if (byLevel.isNotEmpty) {
    return byLevel.entries.reduce((a, b) => b.value > a.value ? b : a).key;
  }
  if (map.levelInit.isNotEmpty) return map.levelInit;
  return map.levels.isNotEmpty ? map.levels.first : null;
}

/// All sector markers (A, B, C…) of the platform serving [gleis], in letter
/// order, placed on the real map with the boarding-rail nudge applied — for the
/// "Abschnitt A–E" labels along the platform. Empty when the Gleis/island can't
/// be resolved.
List<({String letter, LatLng pos})> platformSectors(
    StationMap map, String gleis) {
  final plat = _platformForGleis(map, gleis);
  if (plat == null) return const [];
  final island = resolveIsland(map, plat, gleis, 0, 8);
  return [
    for (final c in island.cubes)
      (
        letter: String.fromCharCode(65 + c.idx),
        pos: LatLng(c.pos.latitude + island.dLat, c.pos.longitude + island.dLon),
      ),
  ];
}

/// One filled outline polygon (LatLng) per car of [cs] on platform [plat] of
/// [map], with the [Coach] (for colour/number) and whether it's the rider's
/// portion (in [section], or all `true` when no section is given).
///
/// The placement is identical to the Bahnhofskarte's: anchor the Wagenreihung's
/// linear car offsets to the map by matching its platform sectors (A–I, each a
/// metre offset) to the real sector cubes (each a LatLng), fit the platform's
/// straight principal axis through those anchors, then place every car by a
/// linear offset→axis regression. Both end cars get a rounded snout; half-width
/// and nose length depend on whether it's a high-speed unit.
List<({List<LatLng> outline, Coach coach, bool boarding})> platformTrainCars(
  StationMap map, {
  required String gleis,
  ({String start, String end})? section,
  required CoachSequence cs,
  List<LatLng>? osmRail,
}) {
  // Every early-out logs WHY there's no train at this Gleis — the diagnostic
  // for "stop X shows no train": which guard rejected it (no matching platform
  // POI / no coach positions / too few sector cubes / too few sector anchors).
  String why(String r) {
    // Collapsed: the route map calls this per stop on every cache poll, so a
    // plain log would repeat the same "no train here" line endlessly. Only
    // failing stops log, and identical reasons fold into "… (×N)".
    AppLog.logCollapsed('platformTrainCars "${map.slug}" Gleis $gleis: $r',
        tag: 'train');
    return r;
  }

  final plat = _platformForGleis(map, gleis);
  if (plat == null) {
    why('no PLATFORM poi matches Gleis '
        '(have: ${map.platforms.map((p) => normalizeGleis(p.name)).toSet().join(",")})');
    return const [];
  }

  final coaches = cs.allCoaches
      .where(
          (c) => c.platformPosition != null && c.platformPosition!.length > 0)
      .toList();
  if (coaches.isEmpty) {
    why('Wagenreihung has no coach platformPositions');
    return const [];
  }

  final island = resolveIsland(map, plat, gleis, 0, 8);
  if (island.cubes.length < 2) {
    why('island resolved <2 sector cubes (got ${island.cubes.length})');
    return const [];
  }

  // The platform's real SHAPE the cars ride. When OSM rail geometry is supplied
  // (the accurate track centre-line — see core/osm_rail.dart) it IS the curve,
  // so the train bends exactly like the real track (Hamburg's tracks curve hard
  // toward the throat). Without it we fall back BYTE-FOR-BYTE to the old
  // straight cube-axis line — the only stable thing the mis-assigned cubes give.
  final curve = _platformCurve(island, osmRail);
  if (curve == null) {
    why('platform curve degenerate');
    return const [];
  }

  // (Wagenreihung metre offset → arc-length ALONG the curve) anchors, from the
  // sectors present as real cubes.
  final anchors = <({double off, double arc})>[];
  for (final s in cs.platform.sectors) {
    final idx = letterIdx(s.name);
    if (idx == null) continue;
    final ci = island.cubes.indexWhere((c) => c.idx == idx);
    if (ci < 0) continue;
    anchors.add((
      off: (s.start + s.end) / 2,
      arc: curve.locate(_nudgedCube(island, island.cubes[ci].pos)),
    ));
  }
  if (anchors.length < 2) {
    why('<2 sector→cube anchors '
        '(Wagenreihung sectors: ${cs.platform.sectors.map((s) => s.name).join(",")}; '
        'resolved cube letters: ${island.cubes.map((c) => String.fromCharCode(65 + c.idx)).join(",")})');
    return const [];
  }

  // Least-squares fit metre-offset → arc-length, so every car's offset maps to
  // a distance along the curve; slice() then carves a spine that keeps every
  // bend between the car's two ends.
  var sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0;
  final n = anchors.length;
  for (final a in anchors) {
    sx += a.off;
    sy += a.arc;
    sxx += a.off * a.off;
    sxy += a.off * a.arc;
  }
  final denom = n * sxx - sx * sx;
  if (denom.abs() < 1e-9) return const [];
  final aSlope = (n * sxy - sx * sy) / denom;
  final bIntercept = (sy - aSlope * sx) / n;
  double arcOf(double off) => aSlope * off + bIntercept;

  final highSpeed = isHighSpeedCoach(cs);
  final hw = (highSpeed ? 2.95 : 2.85) / 2;
  final noseLen = highSpeed ? 5.0 : 2.5;

  bool inSection(Coach c) {
    if (section == null) return true;
    final s = letterIdx(section.start), e = letterIdx(section.end);
    final ci = letterIdx(c.platformPosition!.sector.trim());
    if (s == null || e == null || ci == null) return true;
    return ci >= s && ci <= e;
  }

  final out = <({List<LatLng> outline, Coach coach, bool boarding})>[];
  for (var i = 0; i < coaches.length; i++) {
    final c = coaches[i];
    final pos = c.platformPosition!;
    final spine = curve.slice(arcOf(pos.start), arcOf(pos.end));
    final outline = TrainGeometry.body(
      spine,
      halfWidthM: hw,
      noseStart: i == 0,
      noseEnd: i == coaches.length - 1,
      noseLenM: noseLen,
    );
    if (outline.length >= 3) {
      out.add((outline: outline, coach: c, boarding: inSection(c)));
    }
  }
  return out;
}

/// The arc-length-indexed curve the train rides at the platform. When [osmRail]
/// is non-null with ≥2 points it's the real OSM track centre-line (accurate, see
/// core/osm_rail.dart); otherwise it's the straight cube-axis line — the exact
/// pre-OSM fallback, so behaviour is byte-for-byte identical when OSM is
/// unavailable. Returns null when neither yields a buildable path.
RoutePath? _platformCurve(
  ({List<({int idx, LatLng pos})> cubes, double dLat, double dLon, PlatformLine? axis})
      island,
  List<LatLng>? osmRail,
) {
  if (osmRail != null && osmRail.length >= 2) {
    final c = RoutePath.build(osmRail);
    if (c != null) return c;
  }
  return RoutePath.build(_cubeCurvePts(island));
}

/// Ordered points down a platform island's sector cubes — each nudged onto the
/// boarding rail — forming the platform's real centreline (the spine for the
/// per-car, composition and generic bodies).
///
/// MEASURED REALITY (Kiel + Hamburg fixtures): the bahnhof.de sector cubes are
/// badly mis-assigned per letter — a single Abschnitt sits 28 m (Kiel) to 60 m
/// (Hamburg) off the platform line, which is physically impossible for one
/// sector. So we CANNOT draw a trustworthy curve by connecting the cubes: every
/// attempt (raw chaining, axis-projection, parabola fit, spike removal)
/// zig-zagged, folded, or gave wildly different shapes per Gleis. Instead we lay
/// the train STRAIGHT along the platform's best-fit axis: that axis is dominated
/// by the platform's LENGTH, so the cross-track contamination barely rotates it,
/// giving a stable, correctly-placed straight body. A genuinely curved body
/// would need a clean geometry source (e.g. the track polyline), not these
/// cubes.
List<LatLng> _cubeCurvePts(
    ({List<({int idx, LatLng pos})> cubes, double dLat, double dLon, PlatformLine? axis})
        island) {
  final cubes = island.cubes;
  LatLng nud(LatLng p) =>
      LatLng(p.latitude + island.dLat, p.longitude + island.dLon);
  if (cubes.length < 2) return [for (final c in cubes) nud(c.pos)];

  final lat0 =
      cubes.map((c) => c.pos.latitude).reduce((a, b) => a + b) / cubes.length;
  const mlat = 111320.0;
  final mlon = 111320.0 * math.cos(lat0 * math.pi / 180);
  math.Point<double> xy(LatLng p) => math.Point(p.longitude * mlon, p.latitude * mlat);
  LatLng ll(math.Point<double> p) => LatLng(p.y / mlat, p.x / mlon);

  // Place the train STRAIGHT along the platform's principal axis. We measured
  // the bahnhof.de sector cubes and they are badly MIS-ASSIGNED: a single
  // sector "jumps" 28 m (Kiel) to 60 m (Hamburg) sideways off the platform line
  // — physically impossible for one Abschnitt, so the per-letter cube positions
  // can't be trusted to draw a curve (every attempt zig-zagged or folded). The
  // best-fit axis through the cubes, by contrast, is dominated by the platform's
  // LENGTH, so the cross-track contamination barely tilts it — a robust, stable
  // straight line at the right place. (A true curve needs a clean source, e.g.
  // the track polyline; the cubes aren't it.)
  final pts = [for (final c in cubes) xy(c.pos)];
  final axis = fitLine(pts);
  if (axis == null) return [for (final c in cubes) nud(c.pos)];

  // Project the cubes onto the axis to get the platform's extent, then extend
  // past both ends so a train longer than the cube span keeps going.
  var tMin = double.infinity, tMax = -double.infinity;
  for (final p in pts) {
    final t = (p.x - axis.cx) * axis.dx + (p.y - axis.cy) * axis.dy;
    if (t < tMin) tMin = t;
    if (t > tMax) tMax = t;
  }
  const ext = 60.0;
  tMin -= ext;
  tMax += ext;
  math.Point<double> at(double t) =>
      math.Point(axis.cx + axis.dx * t, axis.cy + axis.dy * t);
  return [nud(ll(at(tMin))), nud(ll(at(tMax)))];
}

/// The boarding-rail-nudged LatLng of a resolved sector cube.
LatLng _nudgedCube(
        ({List<({int idx, LatLng pos})> cubes, double dLat, double dLon, PlatformLine? axis})
            island,
        LatLng p) =>
    LatLng(p.latitude + island.dLat, p.longitude + island.dLon);

/// Place a known train COMPOSITION (coach order + real lengths, from a stop
/// that HAS a Wagenreihung) onto ANOTHER stop's platform — for stops the
/// per-station vehicle-sequence endpoint doesn't serve. A regional train's
/// TERMINUS arrival 404s on that endpoint (regional formation is published per
/// *departure* only), though the same train's departure is fine — so at the
/// destination we'd otherwise have no train. We can't know which sector each
/// coach hits there, but the order + lengths are train-wide, so we draw the
/// train to its real length, in order, curved along the cubes, centred on the
/// highlighted boarding section (where it stops) or the platform centre.
List<({List<LatLng> outline, Coach coach, bool boarding})>
    platformTrainFromComposition(
  StationMap map, {
  required String gleis,
  ({String start, String end})? section,
  required CoachSequence cs,
  List<LatLng>? osmRail,
}) {
  final coaches = cs.allCoaches
      .where((c) => c.platformPosition != null && c.platformPosition!.length > 0)
      .toList();
  if (coaches.isEmpty) return const [];
  final plat = _platformForGleis(map, gleis);
  if (plat == null) return const [];
  final island = resolveIsland(map, plat, gleis, 0, 8);
  if (island.cubes.length < 2) return const [];
  final curve = _platformCurve(island, osmRail);
  if (curve == null) return const [];

  final lens = [for (final c in coaches) c.platformPosition!.length];
  final total = lens.fold(0.0, (a, b) => a + b);
  if (total <= 0) return const [];

  final highSpeed = isHighSpeedCoach(cs);
  final hw = (highSpeed ? 2.95 : 2.85) / 2;
  final noseLen = highSpeed ? 5.0 : 2.5;

  final startArc = _anchorStartArc(curve, island, section, total);
  final out = <({List<LatLng> outline, Coach coach, bool boarding})>[];
  var off = startArc;
  for (var i = 0; i < coaches.length; i++) {
    final spine = curve.slice(off, off + lens[i]);
    off += lens[i];
    final outline = TrainGeometry.body(
      spine,
      halfWidthM: hw,
      noseStart: i == 0,
      noseEnd: i == coaches.length - 1,
      noseLenM: noseLen,
    );
    if (outline.length >= 3) {
      out.add((outline: outline, coach: coaches[i], boarding: true));
    }
  }
  return out;
}

/// A single to-scale train BODY (curved along the platform's sector cubes) for
/// when there is NO Wagenreihung at all — so the map still shows a *train*
/// standing at the Gleis (bent to the platform, rounded snouts), not a bare
/// line. Drawn to [lengthM] (a realistic per-product length) and centred on the
/// boarding [section], NOT spanning the whole platform — a too-long body reads
/// as wrong. Empty when the Gleis/island can't be resolved.
List<LatLng> platformGenericBody(
  StationMap map, {
  required String gleis,
  ({String start, String end})? section,
  required double lengthM,
  bool highSpeed = false,
  List<LatLng>? osmRail,
}) {
  final plat = _platformForGleis(map, gleis);
  if (plat == null) return const [];
  final island = resolveIsland(map, plat, gleis, 0, 8);
  if (island.cubes.length < 2) return const [];
  final curve = _platformCurve(island, osmRail);
  if (curve == null) return const [];
  final len = lengthM <= 0 ? curve.length : math.min(lengthM, curve.length);
  final startArc = _anchorStartArc(curve, island, section, len);
  return TrainGeometry.body(
    curve.slice(startArc, startArc + len),
    halfWidthM: (highSpeed ? 2.95 : 2.85) / 2,
    noseStart: true,
    noseEnd: true,
    noseLenM: highSpeed ? 5.0 : 2.5,
  );
}

/// Arc-length where a body of [lengthM] should START so it sits centred on the
/// highlighted [section]'s cubes (where the train actually stops), or the
/// platform centre when there's no section — clamped to keep the body on the
/// platform when it fits.
double _anchorStartArc(
  RoutePath curve,
  ({List<({int idx, LatLng pos})> cubes, double dLat, double dLon, PlatformLine? axis}) island,
  ({String start, String end})? section,
  double lengthM,
) {
  double centerArc = curve.length / 2;
  if (section != null) {
    final s = letterIdx(section.start), e = letterIdx(section.end);
    if (s != null && e != null) {
      final lo = math.min(s, e), hi = math.max(s, e);
      final arcs = <double>[];
      for (final c in island.cubes) {
        if (c.idx >= lo && c.idx <= hi) {
          arcs.add(curve.locate(_nudgedCube(island, c.pos)));
        }
      }
      if (arcs.isNotEmpty) {
        centerArc = arcs.reduce((a, b) => a + b) / arcs.length;
      }
    }
  }
  var start = centerArc - lengthM / 2;
  final maxStart = curve.length - lengthM;
  if (maxStart > 0) start = start.clamp(0.0, maxStart);
  return start;
}

/// The resolved sector-cube chain (A→I order) for [gleis], nudged onto the
/// boarding rail — the trusted "which side of the platform" reference fed to
/// `osmRailForGleis` to pick the Gleis-side edge of the OSM platform area.
/// Empty when the Gleis/island can't be resolved.
List<LatLng> platformCubeSide(StationMap map, String gleis) {
  final plat = _platformForGleis(map, gleis);
  if (plat == null) return const [];
  final island = resolveIsland(map, plat, gleis, 0, 8);
  return [for (final c in island.cubes) _nudgedCube(island, c.pos)];
}

/// The platform POI whose normalised name matches [gleis], or null.
MapPoi? _platformForGleis(StationMap map, String gleis) {
  for (final p in map.platforms) {
    if (normalizeGleis(p.name) == gleis) return p;
  }
  return null;
}
