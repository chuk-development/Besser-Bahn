import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../../core/platform_train.dart' as pt;
import '../../../core/train_dimensions.dart';
import '../../../core/train_geometry.dart';
import '../../../models/coach_sequence.dart';
import '../../../models/trip.dart';
import '../../../providers/service_providers.dart';
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
    _prefetchStopTrains();
  }

  /// Warm both caches for every stop while the trip is open, so the to-scale
  /// train is ready instantly on any stop's platform — the Wagenreihung (which
  /// car stops where) AND the station map (the Gleis the cars stand on). Both
  /// are fire-and-forget; missing data just means no parked train there.
  void _prefetchStopTrains() {
    final line = _trip.line;
    if (line.fahrtNr.isNotEmpty) {
      ref.read(coachSequenceServiceProvider).prefetchTrainStops(
            category: line.productName,
            trainNumber: line.fahrtNr,
            stops: _trip.stopovers
                .map((s) => (eva: s.stop.id, time: s.departure ?? s.arrival)),
          );
    }
    // The station-map scrape is heavier (~230 KB per stop), so it streams in a
    // bounded window inside the service rather than all at once — long ICE
    // routes warm in the background without stalling the device.
    ref.read(stationMapServiceProvider).prefetch(
          _trip.stopovers.map((s) => s.stop.name),
        );
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
    try {
      final poly =
          await ref.read(hafasServiceProvider).fetchRoutePolyline(_trip);
      if (poly != null && poly.isNotEmpty && mounted) {
        setState(() => _trip = _trip.copyWith(polyline: poly));
      }
    } catch (_) {/* keep straight-line fallback */}
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
  final List<({List<LatLng> outline, Coach coach, bool boarding})> cars;
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

  /// Stop indices we've already resolved (success OR confirmed no-data), so we
  /// don't recompute the same stop on every poll.
  final Set<int> _done = {};

  Timer? _poll;
  int _pollAttempts = 0;

  /// Hard ceiling on poll attempts (× 800 ms ≈ 2 min). The prefetch streams the
  /// StationMaps in bounded windows (≤12 s each) plus the Wagenreihungen, so a
  /// long route is warm well inside this. Without a ceiling, a stop whose map or
  /// Wagenreihung never resolves (small stations often have neither) would keep
  /// the timer polling forever while the screen is open — bounded to the screen
  /// lifetime, but wasteful. We stop once everything resolved OR this ceiling.
  static const _maxPollAttempts = 150;

  @override
  void initState() {
    super.initState();
    // The prefetch streams the per-stop StationMaps + Wagenreihungen in over a
    // few seconds; poll the warm caches and build each stop's static parked
    // train as its data arrives, then stop. This is the ONLY place the parked
    // geometry is computed — it never runs per frame.
    _refreshParked();
    _poll = Timer.periodic(const Duration(milliseconds: 800), (t) {
      _refreshParked();
      _pollAttempts++;
      if (_done.length >= widget.trip.stopovers.length ||
          _pollAttempts >= _maxPollAttempts) {
        t.cancel();
      }
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  /// For every stop not yet resolved, if BOTH its StationMap and Wagenreihung
  /// are now cached, compute its parked-train cars once and keep them.
  void _refreshParked() {
    if (!mounted) return;
    final mapSvc = ref.read(stationMapServiceProvider);
    final coachSvc = ref.read(coachSequenceServiceProvider);
    final line = widget.trip.line;
    var changed = false;
    final stops = widget.trip.stopovers;
    for (var i = 0; i < stops.length; i++) {
      if (_done.contains(i)) continue;
      final s = stops[i];
      final gleisRaw = s.platform?.trim() ?? '';
      final map = mapSvc.cachedByName(s.stop.name);
      // No map yet → keep polling. A map with no platforms means the scrape
      // failed/placeholder → give up on this stop.
      if (map == null) continue;
      if (gleisRaw.isEmpty || map.platforms.isEmpty) {
        _done.add(i);
        continue;
      }
      final cs = coachSvc.cachedForDeparture(
        category: line.productName,
        trainNumber: line.fahrtNr,
        stationEva: s.stop.id,
        departureTime: s.departure ?? s.arrival,
      );
      if (cs == null) continue; // Wagenreihung not in yet (or never will be).
      _done.add(i);
      final cars = pt.platformTrainCars(
        map,
        gleis: pt.normalizeGleis(gleisRaw),
        // Only the rider's boarding stop dims the non-boarding portion; at the
        // other stops the whole standing train is shown lit.
        section: i == _boardingIndex ? _boardingSection : null,
        cs: cs,
      );
      if (cars.isNotEmpty) {
        _parked[i] = _ParkedStop(cars);
        changed = true;
      }
    }
    if (changed && mounted) setState(() {});
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
    final stops = trip.stopovers.where((s) => s.stop.hasLocation).toList();
    if (stops.isEmpty) return const SizedBox.shrink();

    final points = stops
        .map((s) => LatLng(s.stop.latitude!, s.stop.longitude!))
        .toList();
    final routePoints = (trip.polyline != null && trip.polyline!.isNotEmpty)
        ? trip.polyline!.map((p) => LatLng(p['lat']!, p['lng']!)).toList()
        : points;

    // Flatten every stop's parked-train cars into one polygon layer. They're
    // to scale, so they only become visible (more than a speck) once the rider
    // zooms into a stop — intended.
    final parkedPolygons = <Polygon>[];
    final parkedCars = <({List<LatLng> outline, Coach coach, bool boarding})>[];
    for (final p in _parked.values) {
      for (final car in p.cars) {
        if (car.outline.length < 3) continue;
        parkedCars.add(car);
        final fill = car.boarding
            ? coachColor(car.coach)
            : coachColor(car.coach).withValues(alpha: 0.45);
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
      // Show the real DB station floor plans when you zoom into a stop, so the
      // gliding/parked train reads as pulling into each platform. (Indoor tiles
      // only fetch at high zoom — minNativeZoom 14 — so the overview costs
      // nothing; ground floor covers most platforms.)
      indoorLevel: 'GROUND_FLOOR',
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
        if (parkedPolygons.isNotEmpty)
          PolygonLayer(polygons: parkedPolygons, simplificationTolerance: 0),
        // Wagon-number labels, only once a car is large enough on screen — i.e.
        // when the rider has zoomed into a stop (gated by metres/pixel, like the
        // live train), so they don't clutter the overview.
        if (parkedCars.isNotEmpty) _ParkedNumbers(cars: parkedCars),
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
  final List<({List<LatLng> outline, Coach coach, bool boarding})> cars;
  const _ParkedNumbers({required this.cars});

  @override
  Widget build(BuildContext context) {
    final cam = MapCamera.of(context);
    final markers = <Marker>[];
    for (final car in cars) {
      if (car.coach.wagonNumber <= 0 || car.outline.length < 3) continue;
      // Cheap early-out for the overview zoom (where every car is a speck and
      // all of these get rejected): the body's two long ends sit at the start
      // of the ring and just past its half — project only those and skip the
      // full O(n²) span scan unless that one span is already near the
      // threshold. Avoids projecting every ring point of every car per camera
      // frame across a whole multi-stop route.
      final ring = car.outline;
      final a = cam.latLngToScreenOffset(ring.first);
      final b = cam.latLngToScreenOffset(ring[ring.length ~/ 2]);
      if ((a - b).distance < 18) continue;
      // Car width on screen: the longest screen span between ring points. Show
      // the number only when it comfortably fits (≈ a zoomed-in platform).
      final pts = [for (final p in ring) cam.latLngToScreenOffset(p)];
      var maxSpan = 0.0;
      for (var i = 0; i < pts.length; i++) {
        for (var j = i + 1; j < pts.length; j++) {
          final d = (pts[i] - pts[j]).distance;
          if (d > maxSpan) maxSpan = d;
        }
      }
      if (maxSpan < 22) continue;
      markers.add(_numberMarker(
          _centroid(car.outline), car.coach.wagonNumber, coachColor(car.coach)));
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
