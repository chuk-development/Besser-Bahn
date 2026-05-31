import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../../core/app_log.dart';
import '../../../core/osm_rail.dart';
import '../../../core/platform_train.dart' as pt;
import '../../../core/train_dimensions.dart';
import '../../../core/train_geometry.dart';
import '../../../services/osm_platform_service.dart';
import '../../../models/coach_sequence.dart';
import '../../../models/station_map.dart';
import '../../../models/trip.dart';
import '../../../providers/service_providers.dart';
import '../../../services/station_map_service.dart' show StationMapException;
import '../../../theme/app_colors.dart';
import '../../../widgets/app_map.dart';

/// Open the full-screen, fully interactive route map for [trip]. Pass the
/// [coachSequence] when known so the live train is drawn to its real length,
/// and [boardingId]/[alightingId] on a journey leg so the parked train at the
/// boarding stop dims its non-boarding portion (standalone lookup → no dimming).
void openTrainMap(BuildContext context, Trip trip,
    {CoachSequence? coachSequence, String? boardingId, String? alightingId}) {
  Navigator.of(context).push(
    MaterialPageRoute(
        builder: (_) => TrainMapView(
            trip: trip,
            coachSequence: coachSequence,
            boardingId: boardingId,
            alightingId: alightingId)),
  );
}

/// Full-screen route map with the live train (a to-scale top-down body that
/// slides continuously along the exact track geometry, fetched on open).
class TrainMapView extends ConsumerStatefulWidget {
  final Trip trip;
  final CoachSequence? coachSequence;

  /// EVA / name of the stop the rider boards/alights at on this leg. Null on a
  /// standalone train lookup — then no parked train dims its boarding portion.
  final String? boardingId;
  final String? alightingId;

  const TrainMapView(
      {super.key,
      required this.trip,
      this.coachSequence,
      this.boardingId,
      this.alightingId});

  @override
  ConsumerState<TrainMapView> createState() => _TrainMapViewState();
}

class _TrainMapViewState extends ConsumerState<TrainMapView> {
  /// Trip with the exact track geometry attached once it has been resolved.
  /// Starts as the bahn.de trip (straight lines) and snaps onto the rails when
  /// [HafasService.fetchRoutePolyline] returns.
  late Trip _trip;

  bool _polylineStarted = false;

  @override
  void initState() {
    super.initState();
    _trip = widget.trip;
    _ensurePolyline();
  }

  /// Kick off the (network) route-geometry fetch only once the map is actually
  /// shown — off-screen legs must not hit the network.
  void _ensurePolyline() {
    if (_polylineStarted) return;
    _polylineStarted = true;
    _loadPolyline();
  }

  Future<void> _loadPolyline() async {
    if (_trip.polyline != null && _trip.polyline!.isNotEmpty) return;
    final sw = Stopwatch()..start();
    try {
      final poly =
          await ref.read(hafasServiceProvider).fetchRoutePolyline(_trip);
      AppLog.log('route polyline ${poly?.length ?? 0} pts in '
          '${sw.elapsedMilliseconds}ms', tag: 'route');
      if (poly != null && poly.isNotEmpty && mounted) {
        setState(() => _trip = _trip.copyWith(polyline: poly));
      }
    } catch (e) {
      AppLog.log('route polyline FAILED after ${sw.elapsedMilliseconds}ms ($e)',
          tag: 'route');
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasStops = _trip.stopovers.any((s) => s.stop.hasLocation);
    return Scaffold(
      appBar: AppBar(title: Text(_trip.line.displayName)),
      body: hasStops
          ? TrainMap(
              trip: _trip,
              coachSequence: widget.coachSequence,
              boardingId: widget.boardingId,
              alightingId: widget.alightingId,
              interactive: true)
          : const Center(child: Text('Keine Streckendaten verfügbar.')),
    );
  }
}

/// One stop's pre-computed parked-train cars (static map geometry) plus the
/// per-car centre point + wagon number for the on-zoom number labels.
class _ParkedStop {
  /// One entry per Wagen (with its [Coach] for colour + number) — or a single
  /// coach-less entry (`coach == null`) when there's no Wagenreihung and we draw
  /// just a generic to-scale body to mark where the train stands.
  final List<({List<LatLng> outline, Coach? coach, bool boarding})> cars;
  const _ParkedStop(this.cars);
}

/// The actual flutter_map for a trip: route polyline, stops, the parked trains
/// standing on every stop's platform, the live moving train, and a scale bar.
///
/// A [ConsumerStatefulWidget] so it can re-read the warm StationMap +
/// Wagenreihung session caches as the background prefetch fills them, and
/// recompute the (static) parked-train geometry ONCE per stop when its data
/// lands — never per frame.
class TrainMap extends ConsumerStatefulWidget {
  final Trip trip;
  final CoachSequence? coachSequence;
  final bool interactive;

  /// EVA / name of the rider's boarding/alighting stop on this leg. Null on a
  /// standalone train lookup — then no parked train dims its boarding portion.
  final String? boardingId;
  final String? alightingId;

  const TrainMap({
    super.key,
    required this.trip,
    this.coachSequence,
    this.boardingId,
    this.alightingId,
    this.interactive = true,
  });

  @override
  ConsumerState<TrainMap> createState() => _TrainMapState();
}

class _TrainMapState extends ConsumerState<TrainMap> {
  /// The parked train per stop index, computed once its caches are warm.
  final Map<int, _ParkedStop> _parked = {};

  /// Stop indices whose parked train is already built (success OR confirmed
  /// no-data), so we never recompute them.
  final Set<int> _done = {};

  /// Stop indices we've already started fetching, so a stop isn't requested
  /// twice as the camera moves over it. Cleared for a stop if its fetch fails,
  /// so re-zooming retries it.
  final Set<int> _requested = {};

  /// Stops queued for the (sequential) lazy fetch and whether a drain is active.
  final List<int> _queue = [];
  bool _draining = false;
  Timer? _debounce;

  /// The stop the rider has zoomed in on (nearest the camera centre): its floor
  /// plan + Gleis/sector labels are shown. -1 = none focused yet.
  int _focusIndex = -1;
  int _pendingFocus = -1;

  /// The indoor floor plan to render — the focused stop's TRACK level. Null →
  /// the default ground floor (overview / before any stop is focused).
  String? _indoorLevel;

  /// Gleis + sector (A–E) labels for the focused stop, recomputed only when the
  /// focus changes (never per frame).
  List<({String letter, LatLng pos})> _focusSectors = const [];
  List<({String name, LatLng pos})> _focusGleise = const [];

  /// Only fetch a stop's heavy platform map once the rider has zoomed in toward
  /// it — at the route overview the to-scale trains are sub-pixel anyway, so
  /// prefetching the whole route there is pure waste (and the burst that choked
  /// the connection). Below this zoom we fetch nothing.
  static const _detailZoom = 12.5;

  @override
  void initState() {
    super.initState();
    // Pure lazy: NOTHING is fetched at open. A stop's platform map loads only
    // when the rider zooms it into view (see _onCamera), so opening the route
    // map fires zero scrapes and never competes with the initial tile load.
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  /// Camera moved → after a short debounce, queue any stop now in view (and
  /// zoomed in enough to matter) for its lazy platform fetch, and focus the
  /// stop nearest the camera centre (its floor plan + labels).
  void _onCamera(MapCamera cam, bool _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      if (!mounted || cam.zoom < _detailZoom) return;
      final bounds = cam.visibleBounds;
      final stops = widget.trip.stopovers;
      // Only the rider's own segment (boarding…alighting) — never fetch or focus
      // stops the train visits after the rider has already got off.
      final seg = _segmentRange;
      var added = false;
      var nearest = -1;
      var best = double.infinity;
      for (var i = seg.lo; i <= seg.hi; i++) {
        final s = stops[i];
        if (!s.stop.hasLocation) continue;
        final p = LatLng(s.stop.latitude!, s.stop.longitude!);
        if (!bounds.contains(p)) continue;
        if (!_requested.contains(i)) {
          _requested.add(i);
          _queue.add(i);
          added = true;
        }
        final d = (p.latitude - cam.center.latitude).abs() +
            (p.longitude - cam.center.longitude).abs();
        if (d < best) {
          best = d;
          nearest = i;
        }
      }
      if (added) _drainQueue();
      if (nearest >= 0) {
        _pendingFocus = nearest;
        _applyFocus();
      }
    });
  }

  /// Adopt [_pendingFocus] as the focused stop once its map is cached: switch
  /// the indoor floor plan to that stop's TRACK level (the floor with the
  /// Gleise — fixes stations like Neumünster whose tracks aren't on the ground
  /// floor) and pull its Gleis + sector (A–E) labels for the overlay.
  void _applyFocus() {
    final i = _pendingFocus;
    if (i < 0 || i == _focusIndex) return;
    final s = widget.trip.stopovers[i];
    final map = ref.read(stationMapServiceProvider).cachedByName(s.stop.name);
    if (map == null) return; // not fetched yet — _buildParked retries this
    final lvl = pt.trackLevel(map);
    final gleis = pt.normalizeGleis(s.platform?.trim() ?? '');
    final sectors = gleis.isEmpty
        ? const <({String letter, LatLng pos})>[]
        : pt.platformSectors(map, gleis);
    final gleise = [
      for (final p in map.platforms)
        if ((p.level ?? '') == lvl) (name: p.name, pos: p.latLng),
    ];
    setState(() {
      _focusIndex = i;
      _indoorLevel = lvl;
      _focusSectors = sectors;
      _focusGleise = gleise;
    });
  }

  /// Fetch queued stops ONE AT A TIME (a single connection — mirrors the
  /// single-station Karte tab, which works fine; the old whole-route burst is
  /// what choked the connection). Each stop: Wagenreihung + station map, then
  /// build its parked train.
  Future<void> _drainQueue() async {
    if (_draining) return;
    _draining = true;
    final coachSvc = ref.read(coachSequenceServiceProvider);
    final mapSvc = ref.read(stationMapServiceProvider);
    final line = widget.trip.line;
    final stops = widget.trip.stopovers;
    while (_queue.isNotEmpty && mounted) {
      final i = _queue.removeAt(0);
      final s = stops[i];
      final sw = Stopwatch()..start();
      // Kick the Wagenreihung and the station map CONCURRENTLY — they're
      // independent endpoints, so awaiting them in series needlessly doubled
      // the wait before a train could draw. Start the coach fetch (don't await
      // yet), fetch the map, then join the coach future.
      final coachFut = line.fahrtNr.isNotEmpty
          ? coachSvc.getCoachSequenceForDeparture(
              category: line.productName,
              trainNumber: line.fahrtNr,
              stationEva: s.stop.id,
              departureTime: s.departure ?? s.arrival,
            )
          : null;
      var failed = false;
      var permanent = false;
      try {
        await mapSvc.fetchByStationName(s.stop.name, background: true);
      } on StationMapException catch (e) {
        failed = true;
        permanent = !e.transient; // 404 / no map data → never retry
      } catch (_) {
        failed = true;
      }
      if (coachFut != null) {
        try {
          await coachFut;
        } catch (_) {}
      }
      if (!mounted) break;
      AppLog.log(
          '${failed ? (permanent ? "∅" : "✗") : "✓"} ${s.stop.name} '
          '${sw.elapsedMilliseconds}ms',
          tag: 'route');
      if (!failed) {
        _buildParked(i);
      } else if (permanent) {
        _done.add(i); // this station has no map — settled, don't ever retry
      } else {
        _requested.remove(i); // transient (timeout) → retry if revisited
      }
    }
    _draining = false;
  }

  /// Build one stop's parked-train cars from the now-warm caches. A small
  /// station with no platform-sector data simply yields no train (correct, not
  /// an error) — it's marked done so we don't retry it.
  void _buildParked(int i) {
    if (!mounted || _done.contains(i)) return;
    final mapSvc = ref.read(stationMapServiceProvider);
    final coachSvc = ref.read(coachSequenceServiceProvider);
    final line = widget.trip.line;
    final s = widget.trip.stopovers[i];
    final gleisRaw = s.platform?.trim() ?? '';
    final map = mapSvc.cachedByName(s.stop.name);
    if (map == null) return; // fetch didn't land in cache; leave for a retry
    _done.add(i);
    if (gleisRaw.isEmpty || map.platforms.isEmpty) return;
    final gleis = pt.normalizeGleis(gleisRaw);
    // The real OSM track curve — computed ONCE; both the coach placement and the
    // generic-body fallback ride it. Null until Overpass is warm (it then kicks
    // a fetch + rebuilds this stop) or when the track is genuinely unknown — in
    // which case we draw nothing rather than guess where the train stands.
    final osmRail = _osmRailFor(map, gleis, rebuildStop: i);
    final section = i == _boardingIndex ? _boardingSection : null;
    final cs = coachSvc.cachedForDeparture(
      category: line.productName,
      trainNumber: line.fahrtNr,
      stationEva: s.stop.id,
      departureTime: s.departure ?? s.arrival,
    );

    final cars = <({List<LatLng> outline, Coach? coach, bool boarding})>[];
    if (cs != null) {
      // Real coaches at EXACT, DB-given positions: cube-anchored where cubes
      // exist (exact sector alignment), else composition-on-rail.
      cars.addAll(pt.platformTrainCars(
        map,
        gleis: gleis,
        section: section,
        cs: cs,
        osmRail: osmRail,
      ));
    }
    if (cars.isEmpty && widget.coachSequence != null) {
      // No per-stop Wagenreihung (DB publishes it per DEPARTURE; at a terminus
      // arrival like Hamburg it 404s). Reuse the composition we DID fetch for
      // the rider's own leg — same train, real car order + lengths — and place
      // it on THIS stop's OSM rail, centred on the platform. The car order is
      // exact; the absolute spot is best-effort (DB gave none here).
      cars.addAll(pt.platformTrainFromComposition(
        map,
        gleis: gleis,
        section: section,
        cs: widget.coachSequence!,
        osmRail: osmRail,
      ));
    }
    if (cars.isEmpty) {
      // No Wagenreihung at all (e.g. erixx isn't covered by the vehicle-sequence
      // endpoint) — still MARK the train: a single to-scale body for the product
      // standing on the real OSM rail, so every stop on the segment shows where
      // the train is, even when DB won't say which sector it stops at.
      final dims = TrainDimensions.forProduct(line.product);
      final body = pt.platformGenericBody(
        map,
        gleis: gleis,
        section: section,
        lengthM: dims.totalLengthM,
        osmRail: osmRail,
      );
      if (body.length >= 3) {
        cars.add((outline: body, coach: null, boarding: true));
      }
    }
    if (cars.isNotEmpty) {
      _parked[i] = _ParkedStop(cars);
      if (mounted) setState(() {});
    }
    // If this stop is the one the rider just zoomed to, now that its map is in
    // cache we can switch the floor plan + show its labels.
    if (i == _pendingFocus) _applyFocus();
  }

  /// The real OSM rail spine for [gleis] at [map]'s station, so the parked train
  /// rides the true track curve. Returns null (→ cube fallback) until this
  /// station's Overpass geometry is warm; the first miss kicks off the fetch and
  /// rebuilds [rebuildStop] once it lands. Soft-fails: a station with no usable
  /// OSM geometry just stays on the cube placement.
  List<LatLng>? _osmRailFor(StationMap map, String gleis,
      {required int rebuildStop}) {
    final svc = OsmPlatformService.instance;
    final geom = svc.cached(map.slug);
    if (geom == null) {
      if (!svc.isResolved(map.slug)) {
        svc.fetch(map.slug, map.center).then((_) {
          if (!mounted) return;
          _done.remove(rebuildStop);
          _buildParked(rebuildStop);
        });
      }
      return null;
    }
    if (gleis.isEmpty) return null;
    // cubeSide may be empty at small stations with no sector cubes — that's
    // fine: osmRailForGleis then picks the platform's track-side edge by
    // centre-line, which is unambiguous on a single-track-edge platform.
    final cubeSide = pt.platformCubeSide(map, gleis);
    final rail = osmRailForGleis(
      platforms: geom.platforms,
      rails: geom.rails,
      gleis: gleis,
      cubeSide: cubeSide,
    );
    return rail.length >= 2 ? rail : null;
  }

  /// The stop the rider boards at, resolved from the leg's [boardingId] (EVA,
  /// then name). -1 on a standalone train lookup (no boardingId) — so no stop's
  /// parked train dims; the whole standing train is shown lit at every stop.
  int get _boardingIndex {
    final id = widget.boardingId;
    if (id == null || id.isEmpty) return -1;
    final stops = widget.trip.stopovers;
    for (var i = 0; i < stops.length; i++) {
      if (stops[i].stop.id == id) return i;
    }
    for (var i = 0; i < stops.length; i++) {
      if (stops[i].stop.name == id) return i;
    }
    return -1;
  }

  /// The stop the rider alights at, resolved from the leg's [alightingId] (EVA,
  /// then name). -1 on a standalone train lookup (no alightingId).
  int get _alightingIndex {
    final id = widget.alightingId;
    if (id == null || id.isEmpty) return -1;
    final stops = widget.trip.stopovers;
    for (var i = 0; i < stops.length; i++) {
      if (stops[i].stop.id == id) return i;
    }
    for (var i = 0; i < stops.length; i++) {
      if (stops[i].stop.name == id) return i;
    }
    return -1;
  }

  /// The inclusive [lo, hi] index range over `trip.stopovers` the rider actually
  /// travels — boarding…alighting. On a standalone train lookup (no boarding/
  /// alighting) it's the whole train run. So the route map shows ONLY the
  /// rider's segment (Kiel→Raisdorf), not where the train continues afterwards.
  ({int lo, int hi}) get _segmentRange {
    final n = widget.trip.stopovers.length;
    final bi = _boardingIndex, ai = _alightingIndex;
    if (bi >= 0 && ai >= 0 && bi <= ai) return (lo: bi, hi: ai);
    return (lo: 0, hi: n - 1);
  }

  /// The boarding section parsed from the boarding stop's track label, if any.
  ({String start, String end})? get _boardingSection {
    final i = _boardingIndex;
    if (i < 0) return null;
    final g = widget.trip.stopovers[i].platform?.trim() ?? '';
    return g.isEmpty ? null : pt.parseGleisSection(g);
  }

  @override
  Widget build(BuildContext context) {
    final trip = widget.trip;
    // Show only the rider's segment: the stopovers from boarding to alighting
    // (the whole run on a standalone lookup). The train continues past the
    // rider's exit, but the map should stop where the rider does.
    final seg = _segmentRange;
    final segStops = trip.stopovers.sublist(seg.lo, seg.hi + 1);
    final stops = segStops.where((s) => s.stop.hasLocation).toList();
    if (stops.isEmpty) return const SizedBox.shrink();

    final points = stops
        .map((s) => LatLng(s.stop.latitude!, s.stop.longitude!))
        .toList();
    // Clip the full train-run polyline to just the rider's segment (between the
    // boarding and alighting stops) so the map doesn't draw track the rider
    // never rides.
    List<LatLng> routePoints;
    if (trip.polyline != null && trip.polyline!.isNotEmpty) {
      final full =
          trip.polyline!.map((p) => LatLng(p['lat']!, p['lng']!)).toList();
      final path = RoutePath.build(full);
      if (path != null && points.length >= 2) {
        final a = path.locate(points.first);
        final b = path.locate(points.last);
        final clipped = path.slice(math.min(a, b), math.max(a, b));
        routePoints = clipped.length >= 2 ? clipped : full;
      } else {
        routePoints = full;
      }
    } else {
      routePoints = points;
    }

    // Flatten every stop's parked-train cars into one polygon layer. They're
    // to scale, so they only become visible (more than a speck) once the rider
    // zooms into a stop — intended.
    final parkedPolygons = <Polygon>[];
    final parkedCars = <({List<LatLng> outline, Coach? coach, bool boarding})>[];
    for (final entry in _parked.entries) {
      if (entry.key < seg.lo || entry.key > seg.hi) continue;
      for (final car in entry.value.cars) {
        if (car.outline.length < 3) continue;
        parkedCars.add(car);
        // A coach-less generic body (no Wagenreihung) uses the neutral loco
        // colour; real coaches keep their class colour.
        final base = car.coach != null
            ? coachColor(car.coach!)
            : AppColors.locomotive;
        final fill = car.boarding ? base : base.withValues(alpha: 0.45);
        parkedPolygons.add(Polygon(
          points: car.outline,
          color: fill,
          borderColor: Colors.white.withValues(alpha: 0.9),
          borderStrokeWidth: 1.2,
        ));
      }
    }

    return AppMap(
      interactive: widget.interactive,
      // Lazily fetch a stop's platform only once it's zoomed into view.
      onPositionChanged: _onCamera,
      // Show the real DB station floor plan when you zoom into a stop. The
      // level follows the FOCUSED stop's track floor (the one with the Gleise)
      // — not always the ground floor (e.g. Neumünster). Indoor tiles only
      // fetch at high zoom (minNativeZoom 14), so the overview costs nothing.
      indoorLevel: _indoorLevel ?? 'GROUND_FLOOR',
      dbAttribution: true,
      initialCameraFit: CameraFit.bounds(
        bounds: LatLngBounds.fromPoints(points),
        padding: const EdgeInsets.all(40),
      ),
      children: [
        PolylineLayer(
          polylines: [
            Polyline(
              points: routePoints,
              color: AppColors.dbRed.withAlpha(200),
              strokeWidth: 4,
            ),
          ],
        ),
        MarkerLayer(
          markers: [
            for (final stop in stops)
              Marker(
                point: LatLng(stop.stop.latitude!, stop.stop.longitude!),
                width: 12,
                height: 12,
                child: Container(
                  decoration: BoxDecoration(
                    color: stop.isPast ? Colors.grey : Colors.white,
                    shape: BoxShape.circle,
                    border: Border.all(color: AppColors.dbRed, width: 2),
                  ),
                ),
              ),
          ],
        ),
        // Static parked trains, one polygon per Wagen on every stop's platform.
        // Drawn under the live train so the moving train wins where they meet.
        // These are STATIC (don't move), so we let flutter_map simplify them
        // (default tolerance) — fewer points reprojected per pan/zoom frame than
        // tolerance:0, which we only need for the gliding live train.
        if (parkedPolygons.isNotEmpty) PolygonLayer(polygons: parkedPolygons),
        // Wagon-number labels, only once a car is large enough on screen — i.e.
        // when the rider has zoomed into a stop (gated by metres/pixel, like the
        // live train), so they don't clutter the overview.
        if (parkedCars.isNotEmpty) _ParkedNumbers(cars: parkedCars),
        // Gleis ("Gleis 5") + sector (A–E) labels for the focused stop, shown
        // only when zoomed in. Static geometry, computed once on focus change.
        if (_focusSectors.isNotEmpty || _focusGleise.isNotEmpty)
          _StopLabels(sectors: _focusSectors, gleise: _focusGleise),
        // The live train: a top-down body that hugs the rails and slides
        // continuously (its own throttled ticker) instead of jumping. While it
        // dwells at a stop that already has a parked train standing on its
        // platform, it hides — the parked train IS the train there, so the two
        // don't stack/flicker on the same spot.
        _LiveTrain(
            trip: trip,
            route: routePoints,
            coachSequence: widget.coachSequence,
            parkedStops: _parked.keys.toSet()),
      ],
    );
  }

}

/// Wagon-number labels for the parked trains, drawn inside the map so it can
/// read the live camera: a number sits at each car's centre only once that car
/// is wide enough on screen (the rider has zoomed into a stop), so the labels
/// stay hidden over the route overview. Rebuilds on camera change via
/// flutter_map's own listenable — no ticker, this is static geometry.
class _ParkedNumbers extends StatelessWidget {
  final List<({List<LatLng> outline, Coach? coach, bool boarding})> cars;
  const _ParkedNumbers({required this.cars});

  @override
  Widget build(BuildContext context) {
    final cam = MapCamera.of(context);
    final markers = <Marker>[];
    for (final car in cars) {
      final coach = car.coach;
      // A coach-less generic body has no wagon number to show.
      if (coach == null || coach.wagonNumber <= 0 || car.outline.length < 3) {
        continue;
      }
      // O(1) per car: the body is a thin sleeve, so its on-screen length is the
      // distance between the two NOSE ends — the first ring vertex and the one
      // at the half-way point. Project only those two (not the whole ring, and
      // NOT an O(n²) all-pairs scan) — this runs every camera frame across all
      // stops, so it has to stay cheap. Show the number once that span is big
      // enough that the rider has zoomed into the platform.
      final ring = car.outline;
      final a = cam.latLngToScreenOffset(ring.first);
      final b = cam.latLngToScreenOffset(ring[ring.length ~/ 2]);
      if ((a - b).distance < 22) continue;
      markers.add(_numberMarker(
          _centroid(car.outline), coach.wagonNumber, coachColor(coach)));
    }
    if (markers.isEmpty) return const SizedBox.shrink();
    return MarkerLayer(markers: markers);
  }

  static LatLng _centroid(List<LatLng> ring) {
    var lat = 0.0, lon = 0.0;
    for (final p in ring) {
      lat += p.latitude;
      lon += p.longitude;
    }
    return LatLng(lat / ring.length, lon / ring.length);
  }

  static Marker _numberMarker(LatLng at, int number, Color carColor) => Marker(
        point: at,
        width: 22,
        height: 16,
        child: Center(
          child: Text(
            '$number',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w800,
              color: AppColors.onClass(carColor),
              shadows: const [Shadow(color: Colors.black26, blurRadius: 1)],
            ),
          ),
        ),
      );
}

/// The focused stop's platform labels: the Gleis numbers (e.g. "Gleis 5") at
/// each platform and the sector letters (A, B, C…) along the boarding track.
/// Shown only when zoomed into the platform (gated by screen spacing), so they
/// don't clutter the route overview. Static geometry — rebuilds only on camera
/// change via flutter_map's listenable, no ticker.
class _StopLabels extends StatelessWidget {
  final List<({String letter, LatLng pos})> sectors;
  final List<({String name, LatLng pos})> gleise;
  const _StopLabels({required this.sectors, required this.gleise});

  @override
  Widget build(BuildContext context) {
    final cam = MapCamera.of(context);
    // Only show once the platform fills the screen: gate on the on-screen
    // spacing between the first two sectors (≈ 25 m apart in reality).
    if (sectors.length >= 2) {
      final a = cam.latLngToScreenOffset(sectors[0].pos);
      final b = cam.latLngToScreenOffset(sectors[1].pos);
      if ((a - b).distance < 26) return const SizedBox.shrink();
    } else if (cam.zoom < 16) {
      return const SizedBox.shrink();
    }

    final markers = <Marker>[
      for (final s in sectors)
        Marker(
          point: s.pos,
          width: 18,
          height: 18,
          child: Center(
            child: Text(
              s.letter,
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w900,
                color: Colors.black54,
                shadows: [Shadow(color: Colors.white, blurRadius: 2)],
              ),
            ),
          ),
        ),
      for (final g in gleise)
        Marker(
          point: g.pos,
          width: 60,
          height: 16,
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.82),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                'Gleis ${g.name}',
                overflow: TextOverflow.clip,
                maxLines: 1,
                style: const TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.w700,
                  color: Colors.black87,
                ),
              ),
            ),
          ),
        ),
    ];
    if (markers.isEmpty) return const SizedBox.shrink();
    return MarkerLayer(markers: markers);
  }
}

/// The moving train, drawn as a to-scale top-down body on the route polyline.
///
/// It carries its own frame ticker and recomputes the head position from the
/// wall clock, so the train glides smoothly along the track and rounds curves —
/// rather than hopping every few seconds. When zoomed out far enough that the
/// real body would be sub-pixel, it's floored to a small on-screen size so it
/// stays a visible train; once the real length exceeds that floor (zoomed in)
/// it is exactly to scale.
///
/// Performance: the route polyline is projected to metres + cumulative
/// arc-lengths ONCE into a [RoutePath] (rebuilt only when the route changes),
/// so the per-tick `locate`/`slice`/`pointAt` are cheap cached lookups instead
/// of re-projecting the whole (possibly thousands-of-points) line 60×/s. And
/// the ticker only triggers a rebuild when the head has actually moved more
/// than ~0.3 px on screen since the last frame — a train crawls, so this stays
/// perfectly smooth while leaving the CPU idle between meaningful moves.
class _LiveTrain extends StatefulWidget {
  final Trip trip;
  final List<LatLng> route;
  final CoachSequence? coachSequence;

  /// Stop indices (into [trip].stopovers) that have a parked train drawn on
  /// their platform. The live train hides while dwelling at one of these, so it
  /// doesn't stack on top of the identical parked train.
  final Set<int> parkedStops;

  const _LiveTrain(
      {required this.trip,
      required this.route,
      this.coachSequence,
      this.parkedStops = const {}});

  @override
  State<_LiveTrain> createState() => _LiveTrainState();
}

class _LiveTrainState extends State<_LiveTrain>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;

  /// The route projected + arc-length-indexed once; rebuilt only on route change.
  RoutePath? _path;

  /// Head position + ground metres/pixel at the last rebuild — to decide whether
  /// the next tick has moved enough on screen to be worth another rebuild.
  LatLng? _lastHead;
  double _lastMpp = 1;

  static const _distance = Distance();

  @override
  void initState() {
    super.initState();
    _path = RoutePath.build(widget.route);
    _ticker = createTicker(_onTick)..start();
  }

  @override
  void didUpdateWidget(covariant _LiveTrain old) {
    super.didUpdateWidget(old);
    // Reproject only when the polyline identity/length actually changes (it
    // snaps from straight-line to real geometry once, then stays put).
    if (!identical(old.route, widget.route) ||
        old.route.length != widget.route.length) {
      _path = RoutePath.build(widget.route);
      _lastHead = null; // force a rebuild against the new geometry
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  /// Throttle rebuilds: only when the head moved > ~0.3 px on screen since the
  /// last frame (or there's no previous frame yet). A moving train covers a
  /// fraction of a pixel per frame, so without this we'd rebuild 60×/s for a
  /// sub-pixel change and peg the CPU on long routes.
  void _onTick(Duration _) {
    final head = _head();
    if (head == null) {
      if (_lastHead != null) setState(() => _lastHead = null);
      return;
    }
    final prev = _lastHead;
    if (prev == null) {
      setState(() {});
      return;
    }
    // metres moved → pixels via the last frame's metres/pixel.
    final movedM = _distance(prev, head);
    if (movedM / (_lastMpp <= 0 ? 1 : _lastMpp) > 0.3) setState(() {});
  }

  /// Where the train's head is right now: the live-interpolated position while
  /// running, else the platform it's dwelling at, else nothing.
  ///
  /// While dwelling at a stop that already has a parked train on its platform,
  /// this returns null: the parked train shows the train there, so the live
  /// body steps aside instead of stacking on the exact same spot (which would
  /// double-draw / flicker as the throttle toggles it).
  LatLng? _head() {
    final pos = widget.trip.estimatedPosition;
    if (pos != null) return LatLng(pos.latitude, pos.longitude);
    // Dwelling at a stop (arrived, not yet departed) → sit on that platform.
    final now = DateTime.now();
    Stopover? at;
    var atIndex = -1;
    final stops = widget.trip.stopovers;
    for (var i = 0; i < stops.length; i++) {
      final s = stops[i];
      final arr = s.arrival ?? s.departure;
      if (arr != null && !arr.isAfter(now)) {
        final dep = s.departure ?? s.arrival;
        if (dep == null || dep.isAfter(now)) {
          at = s;
          atIndex = i;
        }
      }
    }
    if (at != null && !widget.parkedStops.contains(atIndex) &&
        at.stop.hasLocation) {
      return LatLng(at.stop.latitude!, at.stop.longitude!);
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final head = _head();
    final path = _path;
    if (head == null || path == null) {
      return const SizedBox.shrink();
    }

    // Real-world size: exact from the Wagenreihung if we have it, else a
    // realistic figure for the product category.
    final dims = TrainDimensions.forProduct(widget.trip.line.product);
    var lenM = dims.totalLengthM;
    var halfWM = dims.halfWidthM;
    final cs = widget.coachSequence;
    final cars = cs?.allCoaches
            .where((c) =>
                c.platformPosition != null && c.platformPosition!.length > 0)
            .toList() ??
        const [];
    final highSpeed = cs != null && isHighSpeedCoach(cs);
    if (cs != null) {
      if (cars.isNotEmpty) {
        final s = cars.map((c) => c.platformPosition!.start).reduce(math.min);
        final e = cars.map((c) => c.platformPosition!.end).reduce(math.max);
        if (e - s > 10) lenM = e - s;
      }
      halfWM = (highSpeed ? 2.95 : 2.85) / 2;
    }
    // The route train is the SAME train as on the platform: class colours, car
    // divisions, real length, and rounded snouts at BOTH ends.
    final noseM = highSpeed ? 5.0 : 2.5;

    // Floor the on-screen size so the train never shrinks to an invisible
    // speck; above the floor it's exactly to scale.
    final mpp = _metersPerPixel(MapCamera.of(context), head);
    // Remember this frame's head + scale so the ticker can throttle the next one.
    _lastHead = head;
    _lastMpp = mpp;
    final effLen = math.max(lenM, 30 * mpp);
    final effHalfW = math.max(halfWM, 4 * mpp);
    final effNose = math.min(effLen * 0.42, math.max(noseM, effLen * 0.22));

    // Carve the body out of the (precomputed) route path: tail (min arc) → head
    // (front, direction of travel), so it bends with every curve between.
    final headArc = path.locate(head);
    final tailArc = headArc - effLen;
    final spine = path.slice(tailArc, headArc);
    if (spine.length < 2) return const SizedBox.shrink();

    final polygons = <Polygon>[];

    if (cars.isEmpty) {
      // No Wagenreihung → one neutral body, rounded both ends.
      final outline = TrainGeometry.body(spine,
          halfWidthM: effHalfW,
          noseStart: true,
          noseEnd: true,
          noseLenM: effNose);
      if (outline.length >= 3) {
        polygons.add(
            _carPolygon(outline, AppColors.locomotive, Colors.white));
      }
    } else {
      // One polygon per Wagen, class-coloured, so the cars/compartments read as
      // divisions — exactly like the platform train.
      final start = cars.map((c) => c.platformPosition!.start).reduce(math.min);
      final end = cars.map((c) => c.platformPosition!.end).reduce(math.max);
      final span = (end - start).abs();
      for (var i = 0; i < cars.length; i++) {
        final pos = cars[i].platformPosition!;
        final f0 = span > 0 ? (pos.start - start) / span : 0.0;
        final f1 = span > 0 ? (pos.end - start) / span : 1.0;
        final seg = path.slice(tailArc + f0 * effLen, tailArc + f1 * effLen);
        if (seg.length < 2) continue;
        final outline = TrainGeometry.body(
          seg,
          halfWidthM: effHalfW,
          noseStart: i == 0,
          noseEnd: i == cars.length - 1,
          noseLenM: effNose,
        );
        if (outline.length >= 3) {
          polygons.add(_carPolygon(
              outline, coachColor(cars[i]), Colors.white.withValues(alpha: 0.9)));
        }
      }
    }
    if (polygons.isEmpty) return const SizedBox.shrink();

    // Wagon-number labels, once each car is large enough on screen to fit.
    final carPx = (effLen / math.max(cars.length, 1)) / mpp;
    final showNumbers = cars.isNotEmpty && carPx > 16;
    final numberMarkers = <Marker>[];
    if (showNumbers) {
      final start = cars.map((c) => c.platformPosition!.start).reduce(math.min);
      final end = cars.map((c) => c.platformPosition!.end).reduce(math.max);
      final span = (end - start).abs();
      for (final c in cars) {
        if (c.wagonNumber <= 0) continue;
        final pos = c.platformPosition!;
        final fc = span > 0 ? (pos.center - start) / span : 0.5;
        final at = path.pointAt(tailArc + fc * effLen);
        numberMarkers.add(_numberMarker(at, c.wagonNumber, coachColor(c)));
      }
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        // simplificationTolerance: 0 is essential — the default snaps points to
        // a ~½px grid, making a slowly-moving train twitch between quantised
        // spots instead of gliding.
        PolygonLayer(polygons: polygons, simplificationTolerance: 0),
        if (numberMarkers.isNotEmpty) MarkerLayer(markers: numberMarkers),
      ],
    );
  }

  Polygon _carPolygon(List<LatLng> outline, Color fill, Color border) => Polygon(
        points: outline,
        color: fill,
        borderColor: border,
        borderStrokeWidth: 1.2,
      );

  /// A wagon number centred on a car, in the colour that reads on its class.
  static Marker _numberMarker(LatLng at, int number, Color carColor) => Marker(
        point: at,
        width: 22,
        height: 16,
        child: Center(
          child: Text(
            '$number',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w800,
              color: AppColors.onClass(carColor),
              shadows: const [Shadow(color: Colors.black26, blurRadius: 1)],
            ),
          ),
        ),
      );

  /// Ground metres per screen pixel near [at] — for flooring the on-screen size.
  double _metersPerPixel(MapCamera cam, LatLng at) {
    final east = LatLng(at.latitude, at.longitude + 0.002);
    final pa = cam.latLngToScreenOffset(at);
    final pb = cam.latLngToScreenOffset(east);
    final px = (pb - pa).distance;
    if (px <= 0) return 1;
    return const Distance()(at, east) / px;
  }
}
