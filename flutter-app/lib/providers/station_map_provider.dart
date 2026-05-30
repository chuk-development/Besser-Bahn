import 'dart:math' as math;
import 'package:latlong2/latlong.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/app_log.dart';
import '../core/train_dimensions.dart';
import '../core/train_geometry.dart';
import '../models/coach_sequence.dart';
import '../models/station.dart';
import '../models/station_map.dart';
import '../services/station_map_service.dart';
import 'service_providers.dart';

/// A–I letter index (0–8) of a single-letter section name, else null.
int? _letterIdx(String n) {
  final t = n.trim().toUpperCase();
  if (t.length != 1) return null;
  final code = t.codeUnitAt(0);
  return (code >= 65 && code <= 73) ? code - 65 : null;
}

/// What the highlighted Gleis means for the rider — drives the map banner
/// wording: where you get on (Einstieg), off (Ausstieg) or change (Umstieg).
enum GleisRole { board, alight, transfer, none }

/// The default-shown POI categories: the Gleise and their section letters
/// (A–I), so the rider always sees which Abschnitt to stand at. Everything else
/// (lifts, stairs, lockers, exits, bus/tram stops …) starts hidden and is
/// re-enabled per-category from the legend, so the map opens uncluttered.
const kDefaultPrimaryTypes = {'PLATFORM', 'PLATFORM_SECTOR_CUBE'};

/// Which POI category is the *relevant* one to show by default for a leg of
/// this transport [product] — Gleise for a train/S-Bahn, bus stops for a bus,
/// U-Bahn entrances for a subway. Everything not in this set starts hidden.
Set<String> primaryPoiTypesForProduct(String? product) {
  switch (product) {
    case 'bus':
      return const {'BUS', 'RAIL_REPLACEMENT_TRANSPORT'};
    case 'subway':
      return const {'SUBWAY'};
    default:
      // All rail products (nationalExpress/national/regional/suburban …) ride
      // on Gleise; unknown products fall back to Gleise too.
      return kDefaultPrimaryTypes;
  }
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
class _Line {
  final double cx, cy, dx, dy;
  const _Line(this.cx, this.cy, this.dx, this.dy);

  /// Perpendicular distance from point [p] to this infinite line.
  double perpDistance(math.Point<double> p) =>
      ((p.x - cx) * (-dy) + (p.y - cy) * dx).abs();
}

/// Least-squares principal-axis line through [pts] (≥2 points), via the major
/// eigenvector of the 2×2 covariance matrix.
_Line? _fitLine(List<math.Point<double>> pts) {
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
  return _Line(cx, cy, dx / nn, dy / nn);
}

class StationMapState {
  final Station? station;
  final StationMap? map;
  final String? selectedLevel;

  /// Categories the user has toggled off in the legend.
  final Set<String> hiddenCategories;

  /// When arriving from a journey: the Gleis to board at, highlighted on the
  /// map (normalised, e.g. "6"). Null for a plain station lookup.
  final String? highlightGleis;

  /// The platform-section range to board at, parsed from the arrival/boarding
  /// track label (e.g. "7 C-G" → (C,G)). Null when the label has no section.
  final ({String start, String end})? highlightSection;

  /// When the map is opened for a transfer: a short note shown as a banner,
  /// e.g. "Ankunft Gleis 7 · Weiter ab Gleis 12". Null otherwise.
  final String? transferNote;

  /// What the highlighted Gleis is for (Einstieg/Ausstieg/Umstieg). Defaults to
  /// [GleisRole.board] so a plain boarding highlight reads "Einstieg".
  final GleisRole highlightRole;

  /// A SECOND highlighted Gleis on the same map — used for a transfer, where
  /// the primary is the Einstieg (next train) and this is the Ausstieg
  /// (arriving train), drawn in a distinct colour. Null when not a transfer.
  final String? secondaryGleis;
  final GleisRole secondaryRole;

  /// Section range for the secondary (Ausstieg) Gleis, e.g. "7 G-I" → (G,I).
  final ({String start, String end})? secondarySection;

  /// The boarding train's Wagenreihung, when the map was opened from a leg at
  /// the stop this sequence belongs to — lets us draw the train to scale on the
  /// platform. Null for a plain station lookup or an intermediate/transfer stop.
  final CoachSequence? coachSequence;

  /// On a transfer map, the Ausstieg (arriving) train's Wagenreihung — drawn on
  /// the secondary Gleis. Null when not a transfer.
  final CoachSequence? secondaryCoachSequence;

  /// The train this map was opened for, e.g. "RE 7" — shown in the banner so
  /// the map says which train it is. Null for a plain station lookup.
  final String? trainLabel;

  final bool isLoading;
  final String? error;

  const StationMapState({
    this.station,
    this.map,
    this.selectedLevel,
    this.hiddenCategories = const {},
    this.highlightGleis,
    this.highlightSection,
    this.transferNote,
    this.highlightRole = GleisRole.board,
    this.secondaryGleis,
    this.secondaryRole = GleisRole.none,
    this.secondarySection,
    this.coachSequence,
    this.secondaryCoachSequence,
    this.trainLabel,
    this.isLoading = false,
    this.error,
  });

  StationMapState copyWith({
    Station? station,
    StationMap? map,
    String? selectedLevel,
    Set<String>? hiddenCategories,
    String? highlightGleis,
    ({String start, String end})? highlightSection,
    String? transferNote,
    GleisRole? highlightRole,
    String? secondaryGleis,
    GleisRole? secondaryRole,
    ({String start, String end})? secondarySection,
    CoachSequence? coachSequence,
    CoachSequence? secondaryCoachSequence,
    String? trainLabel,
    bool clearHighlight = false,
    bool clearSection = false,
    bool clearTransferNote = false,
    bool clearSecondary = false,
    bool clearCoachSequence = false,
    bool clearTrainLabel = false,
    bool? isLoading,
    String? error,
    bool clearError = false,
  }) {
    return StationMapState(
      station: station ?? this.station,
      map: map ?? this.map,
      selectedLevel: selectedLevel ?? this.selectedLevel,
      hiddenCategories: hiddenCategories ?? this.hiddenCategories,
      highlightGleis:
          clearHighlight ? null : (highlightGleis ?? this.highlightGleis),
      highlightSection: (clearHighlight || clearSection)
          ? null
          : (highlightSection ?? this.highlightSection),
      transferNote:
          clearTransferNote ? null : (transferNote ?? this.transferNote),
      highlightRole: clearHighlight
          ? GleisRole.none
          : (highlightRole ?? this.highlightRole),
      secondaryGleis: (clearHighlight || clearSecondary)
          ? null
          : (secondaryGleis ?? this.secondaryGleis),
      secondaryRole: (clearHighlight || clearSecondary)
          ? GleisRole.none
          : (secondaryRole ?? this.secondaryRole),
      secondarySection: (clearHighlight || clearSecondary)
          ? null
          : (secondarySection ?? this.secondarySection),
      coachSequence: clearCoachSequence
          ? null
          : (coachSequence ?? this.coachSequence),
      secondaryCoachSequence: (clearCoachSequence || clearSecondary)
          ? null
          : (secondaryCoachSequence ?? this.secondaryCoachSequence),
      trainLabel:
          clearTrainLabel ? null : (trainLabel ?? this.trainLabel),
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : (error ?? this.error),
    );
  }

  /// The POI for the highlighted boarding Gleis, if present on the current map.
  MapPoi? get highlightPoi => _poiForGleis(highlightGleis);

  /// The POI for the secondary (Ausstieg) Gleis on a transfer map.
  MapPoi? get secondaryHighlightPoi => _poiForGleis(secondaryGleis);

  MapPoi? _poiForGleis(String? g) {
    final m = map;
    if (g == null || m == null) return null;
    for (final p in m.platforms) {
      if (normalizeGleis(p.name) == g) return p;
    }
    return null;
  }

  /// Role to highlight [poi] as on the map: primary, secondary, or none.
  GleisRole roleForPoi(MapPoi poi) {
    if (!poi.isPlatform) return GleisRole.none;
    final n = normalizeGleis(poi.name);
    if (highlightGleis != null && n == highlightGleis) return highlightRole;
    if (secondaryGleis != null && n == secondaryGleis) return secondaryRole;
    return GleisRole.none;
  }

  /// The real sector cubes (A–I) of the boarding section range, in letter
  /// order, resolved onto the boarding Gleis's platform island — so the map
  /// draws a line and labelled markers exactly where the rider should stand.
  ///
  /// The `PLATFORM_SECTOR_CUBE` POIs carry NO track reference and the platforms
  /// fan out (curve apart toward the far end), so neither a straight-line model
  /// nor nearest-centroid works. But bahnhof.de DOES tell us, on each
  /// lift/escalator, which track pair it serves ("zu Gleis 7/8 …") with a real
  /// position — see [PlatformAnchor]. We group tracks into platform islands
  /// from those anchors, fit each island's axis line (anchors + the island's
  /// Gleis markers), then assign every sector cube to the island whose line it
  /// lies closest to. The boarding Gleis's island gives the real cubes for the
  /// requested letters. Falls back to nearest-cube-per-letter when a station
  /// has no usable anchors. Universal, data-driven, no per-station table.
  List<({String letter, LatLng pos})> get highlightSectionLine =>
      _sectionLineFor(highlightPoi, highlightSection, highlightGleis);

  /// Same band, for the secondary (Ausstieg) Gleis on a transfer map.
  List<({String letter, LatLng pos})> get secondarySectionLine =>
      _sectionLineFor(secondaryHighlightPoi, secondarySection, secondaryGleis);

  List<({String letter, LatLng pos})> _sectionLineFor(
      MapPoi? plat, ({String start, String end})? range, String? g) {
    if (plat == null || range == null || g == null) return const [];
    final start = _letterIdx(range.start);
    final end = _letterIdx(range.end);
    if (start == null || end == null) return const [];

    final island = _resolveIsland(plat, g, start, end);
    return [
      for (final c in island.cubes)
        (
          letter: String.fromCharCode(65 + c.idx),
          pos: LatLng(
              c.pos.latitude + island.dLat, c.pos.longitude + island.dLon),
        ),
    ];
  }

  /// The boarding-Gleis platform island, resolved once: the real sector cubes
  /// (letter index → LatLng) for letters [startIdx]…[endIdx], plus the metre
  /// nudge (`dLat`,`dLon`) from the platform centre toward the boarding rail.
  /// Shared by the section line/markers and the to-scale platform train so they
  /// land on the same side of the platform.
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
    _Line? axis,
  }) _resolveIsland(MapPoi plat, String g, int startIdx, int endIdx) {
    const empty = (
      cubes: <({int idx, LatLng pos})>[],
      dLat: 0.0,
      dLon: 0.0,
      axis: null,
    );
    final m = map;
    if (m == null) return empty;

    final level = plat.level ?? '';
    final cubes =
        m.poisOnLevel(level).where((p) => p.isPlatformSector).toList();
    if (cubes.isEmpty) return empty;

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
    for (final a in m.platformAnchors) {
      final key = (a.gleise.toList()..sort()).join('/');
      gleiseByKey[key] = a.gleise;
      (ptsByKey[key] ??= []).add(xy(a.latitude, a.longitude));
    }
    gleiseByKey.forEach((key, gleise) {
      for (final p in m.platforms) {
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
    final lines = <String, _Line>{};
    ptsByKey.forEach((key, pts) {
      final l = _fitLine(pts);
      if (l != null) lines[key] = l;
    });

    // 3) Pick one cube per requested letter, disambiguating to our island.
    const dist = Distance();
    final byLetter = <int, List<MapPoi>>{};
    for (final c in cubes) {
      final li = _letterIdx(c.name);
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
    final partner = _islandPartner(m, plat, level, g, gleiseByKey, ourKey);
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
        _fitLine([for (final c in out) xy(c.pos.latitude, c.pos.longitude)]);
    return (cubes: out, dLat: dLat, dLon: dLon, axis: axis);
  }

  /// The boarding (Einstieg) train drawn to scale, top-down, on its platform.
  List<({List<LatLng> outline, Coach coach, bool boarding})>
      get boardingTrainCars =>
          _trainCarsFor(highlightPoi, highlightGleis, highlightSection,
              coachSequence);

  /// The Ausstieg train on a transfer map — the arriving train on its Gleis.
  List<({List<LatLng> outline, Coach coach, bool boarding})>
      get secondaryTrainCars => _trainCarsFor(secondaryHighlightPoi,
          secondaryGleis, secondarySection, secondaryCoachSequence);

  /// One filled outline polygon (LatLng) per car of [cs] on platform [plat],
  /// with the [Coach] (for colour/number) and whether it's the rider's portion
  /// (in [section]).
  ///
  /// We anchor the Wagenreihung's linear car offsets to the map by matching its
  /// platform sectors (A–I, each a metre offset) to the real sector cubes (each
  /// a LatLng), then fit the platform's straight principal axis through those
  /// anchors and place every car by a linear offset→axis regression. A straight
  /// axis (rather than chaining noisy cube points) keeps the train clean — no
  /// spurious kink at the far end where a single cube or an extrapolation used
  /// to throw it off in a nonsensical direction.
  List<({List<LatLng> outline, Coach coach, bool boarding})> _trainCarsFor(
      MapPoi? plat,
      String? g,
      ({String start, String end})? section,
      CoachSequence? cs) {
    if (cs == null || plat == null || g == null) return const [];
    final coaches = cs.allCoaches
        .where((c) =>
            c.platformPosition != null && c.platformPosition!.length > 0)
        .toList();
    if (coaches.isEmpty) return const [];

    final island = _resolveIsland(plat, g, 0, 8);
    if (island.cubes.length < 2) return const [];
    final cubeByIdx = {for (final c in island.cubes) c.idx: c.pos};

    // (offset metres → LatLng) anchors from sectors present as real cubes.
    final anchors = <({double off, LatLng pos})>[];
    for (final s in cs.platform.sectors) {
      final idx = _letterIdx(s.name);
      if (idx == null) continue;
      final pos = cubeByIdx[idx];
      if (pos == null) continue;
      anchors.add((off: (s.start + s.end) / 2, pos: pos));
    }
    if (anchors.length < 2) return const [];

    final lat0 =
        anchors.map((a) => a.pos.latitude).reduce((x, y) => x + y) /
            anchors.length;
    const mlat = 111320.0;
    final mlon = 111320.0 * math.cos(lat0 * math.pi / 180);
    final ax = [
      for (final a in anchors)
        math.Point(a.pos.longitude * mlon, a.pos.latitude * mlat)
    ];

    // Use the platform island's robust axis (from anchors + Gleis markers); it
    // gives the true platform direction so the train sits parallel to the track
    // instead of tilting to the scatter of a few cubes. Then least-squares fit
    // the anchors' metre offset → position-along-axis; cars map straight onto it.
    final line = island.axis ?? _fitLine(ax);
    if (line == null) return const [];
    var sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0;
    final n = anchors.length;
    for (var i = 0; i < n; i++) {
      final t = (ax[i].x - line.cx) * line.dx + (ax[i].y - line.cy) * line.dy;
      final off = anchors[i].off;
      sx += off;
      sy += t;
      sxx += off * off;
      sxy += off * t;
    }
    final denom = n * sxx - sx * sx;
    if (denom.abs() < 1e-9) return const [];
    final aSlope = (n * sxy - sx * sy) / denom;
    final bIntercept = (sy - aSlope * sx) / n;

    LatLng axisLatLng(double off) {
      final t = aSlope * off + bIntercept;
      final x = line.cx + line.dx * t, y = line.cy + line.dy * t;
      return LatLng(y / mlat + island.dLat, x / mlon + island.dLon);
    }

    final highSpeed = isHighSpeedCoach(cs);
    final hw = (highSpeed ? 2.95 : 2.85) / 2;
    final noseLen = highSpeed ? 5.0 : 2.5;

    bool inSection(Coach c) {
      if (section == null) return true;
      final s = _letterIdx(section.start), e = _letterIdx(section.end);
      final ci = _letterIdx(c.platformPosition!.sector.trim());
      if (s == null || e == null || ci == null) return true;
      return ci >= s && ci <= e;
    }

    final out = <({List<LatLng> outline, Coach coach, bool boarding})>[];
    for (var i = 0; i < coaches.length; i++) {
      final c = coaches[i];
      final pos = c.platformPosition!;
      final outline = TrainGeometry.body(
        [axisLatLng(pos.start), axisLatLng(pos.end)],
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

  /// POIs to render: current floor, minus hidden categories.
  List<MapPoi> get visiblePois {
    final m = map;
    if (m == null || selectedLevel == null) return const [];
    return m
        .poisOnLevel(selectedLevel!)
        .where((p) => !hiddenCategories.contains(p.type))
        .toList();
  }
}

class StationMapNotifier extends Notifier<StationMapState> {
  StationMapService get _service => ref.read(stationMapServiceProvider);

  /// The journey-relevant categories to show by default for the current load
  /// (e.g. Gleise for a train, bus stops for a bus). Used in [_load] to compute
  /// the default-hidden set once the map's categories are known.
  Set<String> _primaryTypes = kDefaultPrimaryTypes;

  /// The train(s) this map was opened for — so we can fetch the Wagenreihung
  /// for THIS stop (works at every stop, not just where the train was first
  /// looked up) and draw it to scale on the platform. [_coachRef] is the
  /// Einstieg train; [_coachRefSecondary] is the Ausstieg train on a transfer.
  ({String category, String trainNumber, DateTime? time})? _coachRef;
  ({String category, String trainNumber, DateTime? time})? _coachRefSecondary;

  @override
  StationMapState build() => const StationMapState();

  /// Load the map for a station. Pass [highlightGleis] when coming from a
  /// journey so the boarding track is highlighted and its floor pre-selected.
  /// [role] sets whether that Gleis is the rider's Einstieg, Ausstieg or Umstieg
  /// — so the banner doesn't call the destination an "Einstieg".
  Future<void> loadForStation(Station station,
      {String? highlightGleis,
      String? transferNote,
      GleisRole role = GleisRole.board,
      String? secondaryGleis,
      GleisRole secondaryRole = GleisRole.none,
      ({String start, String end})? sectionOverride,
      ({String category, String trainNumber, DateTime? time})? coachRef,
      ({String category, String trainNumber, DateTime? time})?
          secondaryCoachRef,
      String? trainLabel,
      Set<String>? primaryTypes}) async {
    _primaryTypes = primaryTypes ?? kDefaultPrimaryTypes;
    _coachRef = coachRef;
    _coachRefSecondary = secondaryCoachRef;
    final raw = highlightGleis?.trim() ?? '';
    final hl = raw.isNotEmpty ? normalizeGleis(raw) : null;
    // [sectionOverride] (the boarding portion of a wing train, e.g. just "I")
    // wins over the section parsed from the track label (the whole train's range)
    // — so the map highlights exactly where the rider's coaches stop.
    final section =
        sectionOverride ?? (raw.isNotEmpty ? parseGleisSection(raw) : null);
    final sraw = secondaryGleis?.trim() ?? '';
    final sec = sraw.isNotEmpty ? normalizeGleis(sraw) : null;
    final secSection = sraw.isNotEmpty ? parseGleisSection(sraw) : null;
    state = state.copyWith(
      station: station,
      highlightGleis: hl,
      highlightSection: section,
      transferNote: transferNote,
      highlightRole: hl == null ? GleisRole.none : role,
      secondaryGleis: sec,
      secondaryRole: sec == null ? GleisRole.none : secondaryRole,
      secondarySection: secSection,
      // Clear any train from the previous map; this stop's Wagenreihung is
      // fetched fresh below.
      clearCoachSequence: true,
      trainLabel: trainLabel,
      clearTrainLabel: trainLabel == null,
      clearHighlight: hl == null,
      // Without an explicit section, drop any stale one from a previous train
      // (else every train would keep showing the first train's "G–I").
      clearSection: section == null,
      clearTransferNote: transferNote == null,
      clearSecondary: sec == null,
    );
    await _load(() => _service.fetchByStationName(station.name));
  }

  Future<void> loadBySlug(String slug) async {
    _primaryTypes = kDefaultPrimaryTypes;
    _coachRef = null;
    _coachRefSecondary = null;
    state = state.copyWith(clearHighlight: true, clearCoachSequence: true);
    await _load(() => _service.fetchBySlug(slug));
  }

  /// Fetch the Wagenreihung(en) for the train(s) at THIS stop and attach them,
  /// so the platform train is drawn at every stop where data exists — not only
  /// where the train was first looked up. Best-effort: failures leave no train.
  Future<void> _loadCoachSequences(Station station) async {
    if (station.id.isEmpty) return;
    final svc = ref.read(coachSequenceServiceProvider);
    Future<CoachSequence?> fetch(
        ({String category, String trainNumber, DateTime? time})? r) async {
      if (r == null || r.trainNumber.isEmpty) return null;
      try {
        return await svc.getCoachSequenceForDeparture(
          category: r.category,
          trainNumber: r.trainNumber,
          stationEva: station.id,
          departureTime: r.time,
        );
      } catch (_) {
        return null;
      }
    }

    final results = await Future.wait([fetch(_coachRef), fetch(_coachRefSecondary)]);
    final primary = results[0];
    final secondary = results[1];
    if (primary == null && secondary == null) return;
    state = state.copyWith(
      coachSequence: primary,
      secondaryCoachSequence: secondary,
    );
  }

  Future<void> _load(Future<StationMap> Function() fetch) async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final map = await fetch();
      final level = _levelForLoad(map);
      AppLog.log(
          'map loaded: slug "${map.slug}", level "$level", '
          'highlight ${state.highlightGleis ?? '–'} '
          'section ${state.highlightSection == null ? '–' : '${state.highlightSection!.start}–${state.highlightSection!.end}'}',
          tag: 'map');
      state = state.copyWith(
        map: map,
        selectedLevel: level,
        // Open uncluttered: hide every category except the journey-relevant
        // one(s). The rider re-enables lifts/exits/lockers/etc. via the legend.
        hiddenCategories:
            map.pois.map((p) => p.type).toSet().difference(_primaryTypes),
        isLoading: false,
      );
      // Then attach the platform train(s) for this stop (non-blocking visually).
      final st = state.station;
      if (st != null) await _loadCoachSequences(st);
    } on StationMapException catch (e) {
      // Known/expected failure (bad slug, no map data) — message is user-safe.
      AppLog.log('map load failed (StationMapException): ${e.message}',
          tag: 'map');
      state = state.copyWith(isLoading: false, error: e.message);
    } catch (e, st) {
      // Unexpected — log the real type + message + stack so the in-app Log
      // shows WHY, instead of the generic "konnte nicht geladen werden".
      AppLog.log('map load CRASHED: ${e.runtimeType}: $e', tag: 'map');
      AppLog.log('$st', tag: 'map');
      state = state.copyWith(
        isLoading: false,
        error: 'Karte konnte nicht geladen werden ($e).',
      );
    }
  }

  void selectLevel(String level) =>
      state = state.copyWith(selectedLevel: level);

  void toggleCategory(String category) {
    final next = Set<String>.from(state.hiddenCategories);
    next.contains(category) ? next.remove(category) : next.add(category);
    state = state.copyWith(hiddenCategories: next);
  }

  /// Floor to show on load: the one carrying the highlighted boarding Gleis
  /// if we have one, otherwise the floor with the most platforms.
  String _levelForLoad(StationMap map) {
    final g = state.highlightGleis;
    if (g != null) {
      for (final p in map.platforms) {
        if (normalizeGleis(p.name) == g && (p.level?.isNotEmpty ?? false)) {
          return p.level!;
        }
      }
    }
    return _defaultLevel(map);
  }

  /// Default to the floor that actually has the most platforms (Gleise),
  /// so the user lands on the tracks instead of an empty concourse.
  String _defaultLevel(StationMap map) {
    String? best;
    var bestCount = -1;
    for (final lvl in map.levels) {
      final count = map.poisOnLevel(lvl).where((p) => p.isPlatform).length;
      if (count > bestCount) {
        bestCount = count;
        best = lvl;
      }
    }
    if (bestCount <= 0) {
      best = map.levelInit.isNotEmpty
          ? map.levelInit
          : (map.levels.isNotEmpty ? map.levels.first : null);
    }
    return best ?? '';
  }
}

final stationMapProvider =
    NotifierProvider<StationMapNotifier, StationMapState>(
        StationMapNotifier.new);
