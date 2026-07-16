import '../core/app_log.dart';
import '../core/offline_package.dart';
import '../core/tile_cache.dart';
import '../models/journey.dart';
import '../models/trip.dart';
import 'coach_sequence_service.dart';
import 'offline_store.dart';
import 'station_map_service.dart';
import 'vendo_service.dart';

/// Progress of a running package download, for the UI.
typedef OfflineDownloadProgress = ({
  OfflinePartKind kind,
  int done,
  int total,
});

/// Whether the account layer already holds a ticket for this journey.
///
/// Passed in rather than looked up here: tickets live in the DB-account world
/// (SharedPreferences, auth-gated), and this service has no business reaching
/// into it. [exists] = the journey has a booked ticket at all; [cached] = its
/// raw payload (barcode included) is already on disk.
typedef OfflineTicketInfo = ({bool exists, bool cached});

/// Assembles the offline travel package for one saved journey (#29).
///
/// The contract this service keeps: **never claim more than it stored.** Every
/// part reports `expected` vs `stored`, a partial download is a partial package,
/// and the manifest is written even when things fail — an honest "unvollständig"
/// is worth far more to someone on a train than an optimistic badge.
class OfflinePackageService {
  OfflinePackageService({
    required VendoService vendo,
    required CoachSequenceService coach,
    required StationMapService stationMap,
    OfflineStore? store,
  })  : _vendo = vendo,
        _coach = coach,
        _stationMap = stationMap,
        _store = store ?? OfflineStore.instance;

  final VendoService _vendo;
  final CoachSequenceService _coach;
  final StationMapService _stationMap;
  final OfflineStore _store;

  /// Download everything this journey's sources will give us.
  ///
  /// Runs strictly sequentially. A package download is a background courtesy
  /// competing with whatever the rider is actually doing, and the Vendo backend
  /// rate-limits per client (a burst of `zuglauf` calls trips it and fails the
  /// whole set — see the gate in VendoService); patience costs a few seconds and
  /// buys a package that actually completes.
  Future<OfflineManifest> download(
    Journey journey, {
    required String journeyKey,
    required OfflineTicketInfo ticket,
    void Function(OfflineDownloadProgress)? onProgress,
    bool Function()? cancelled,
  }) async {
    final sw = Stopwatch()..start();
    bool stopped() => cancelled?.call() ?? false;

    // Walking legs are transfers, not trains: no run, no coach order.
    final legs = journey.legs.where((l) => !l.isWalking).toList();

    final parts = <OfflinePart>[];
    final trips = <Trip>[];

    // 1) Reiseplan — the raw run per leg, which also carries the polyline the
    //    tile corridor is derived from, so this must go first.
    parts.add(await _downloadPlans(
      journeyKey: journeyKey,
      legs: legs,
      trips: trips,
      onProgress: onProgress,
      stopped: stopped,
    ));

    // 2) Wagenreihung — per leg, at the stop the rider boards.
    if (!stopped()) {
      parts.add(await _downloadCoaches(
        journeyKey: journeyKey,
        legs: legs,
        onProgress: onProgress,
        stopped: stopped,
      ));
    }

    // 3) Bahnhofskarten — origin, every transfer, destination.
    if (!stopped()) {
      parts.add(await _downloadStationMaps(
        journeyKey: journeyKey,
        legs: legs,
        onProgress: onProgress,
        stopped: stopped,
      ));
    }

    // 4) Kartenkacheln along the corridor.
    if (!stopped()) {
      parts.add(await _downloadTiles(
        journeyKey: journeyKey,
        journey: journey,
        trips: trips,
        onProgress: onProgress,
        stopped: stopped,
      ));
    }

    // 5) Ticket — nothing to download, only to report.
    parts.add(_ticketPart(ticket));

    final manifest = OfflineManifest(
      journeyKey: journeyKey,
      fetchedAtMs: DateTime.now().millisecondsSinceEpoch,
      parts: parts,
    );
    await _store.writeManifest(manifest);

    AppLog.log(
        'offline package "$journeyKey" in ${sw.elapsedMilliseconds}ms: '
        '${parts.map((p) => '${p.kind.name} ${p.stored}/${p.expected}').join(', ')} '
        '· ${offlineSizeLabel(manifest.totalBytes)}',
        tag: 'offline');
    return manifest;
  }

  Future<OfflinePart> _downloadPlans({
    required String journeyKey,
    required List<JourneyLeg> legs,
    required List<Trip> trips,
    required void Function(OfflineDownloadProgress)? onProgress,
    required bool Function() stopped,
  }) async {
    // Only legs that actually carry a run id can have a plan fetched.
    final ids = legs
        .map((l) => l.tripId)
        .whereType<String>()
        .where((id) => id.isNotEmpty)
        .toList();
    var stored = 0;
    var bytes = 0;
    String? note;

    for (var i = 0; i < ids.length; i++) {
      if (stopped()) break;
      onProgress?.call((kind: OfflinePartKind.plan, done: i, total: ids.length));
      try {
        final raw = await _vendo.getTripRaw(ids[i]);
        bytes += await _store.writeJson(
            journeyKey, OfflineStore.planName(ids[i]), raw);
        stored++;
        // Parse now so the tile corridor has geometry without a second fetch.
        try {
          trips.add(_vendo.parseTrip(raw, ids[i]));
        } catch (_) {
          // A payload we stored but can't parse still replays later if the
          // parser improves; it just doesn't contribute geometry today.
        }
      } catch (e) {
        note ??= 'Zuglauf nicht abrufbar ($e)';
      }
    }
    onProgress?.call(
        (kind: OfflinePartKind.plan, done: ids.length, total: ids.length));

    if (ids.length < legs.length) {
      note ??= '${legs.length - ids.length} Abschnitt(e) ohne Zuglauf-ID';
    }
    return OfflinePart(
      kind: OfflinePartKind.plan,
      expected: ids.length,
      stored: stored,
      bytes: bytes,
      note: note,
    );
  }

  Future<OfflinePart> _downloadCoaches({
    required String journeyKey,
    required List<JourneyLeg> legs,
    required void Function(OfflineDownloadProgress)? onProgress,
    required bool Function() stopped,
  }) async {
    // Only trains the vehicle-sequence endpoint serves, at a stop with a time.
    final targets = <({String key, String cat, int number, String eva, DateTime time})>[];
    for (final leg in legs) {
      final line = leg.line;
      final time = leg.departure ?? leg.plannedDeparture;
      if (line == null || time == null || leg.origin.id.isEmpty) continue;
      final k = CoachSequenceService.sequenceKeyFor(line.productName, line.fahrtNr);
      if (k == null) continue; // S-Bahn/bus/tram — no Wagenreihung exists
      targets.add((
        key: CoachSequenceService.cacheKeyFor(
            category: k.category,
            number: k.number,
            stationEva: leg.origin.id,
            departureTime: time),
        cat: k.category,
        number: k.number,
        eva: leg.origin.id,
        time: time,
      ));
    }

    var stored = 0;
    var bytes = 0;
    String? note;
    for (var i = 0; i < targets.length; i++) {
      if (stopped()) break;
      onProgress?.call(
          (kind: OfflinePartKind.wagenreihung, done: i, total: targets.length));
      final t = targets[i];
      try {
        final raw = await _coach.getCoachSequenceRaw(
          category: t.cat,
          number: t.number,
          stationEva: t.eva,
          date: t.time,
          time: t.time,
        );
        bytes +=
            await _store.writeJson(journeyKey, OfflineStore.coachName(t.key), raw);
        stored++;
      } catch (_) {
        // Common and not alarming: DB serves no sequence for plenty of trains,
        // and the endpoint 403s intermittently.
        note ??= 'Für manche Züge liefert DB keine Wagenreihung';
      }
    }
    onProgress?.call((
      kind: OfflinePartKind.wagenreihung,
      done: targets.length,
      total: targets.length
    ));

    return OfflinePart(
      kind: OfflinePartKind.wagenreihung,
      expected: targets.length,
      stored: stored,
      bytes: bytes,
      note: note,
    );
  }

  Future<OfflinePart> _downloadStationMaps({
    required String journeyKey,
    required List<JourneyLeg> legs,
    required void Function(OfflineDownloadProgress)? onProgress,
    required bool Function() stopped,
  }) async {
    // Boundaries of the train legs = origin, every transfer, destination.
    final slugs = <String>{};
    for (final leg in legs) {
      for (final s in [leg.origin, leg.destination]) {
        if (s.name.trim().isEmpty) continue;
        slugs.add(StationMapService.slugify(s.name));
      }
    }
    final list = slugs.toList();

    var stored = 0;
    var bytes = 0;
    String? note;
    for (var i = 0; i < list.length; i++) {
      if (stopped()) break;
      onProgress?.call(
          (kind: OfflinePartKind.stationMap, done: i, total: list.length));
      try {
        final res = await _stationMap.fetchRawBySlug(list[i], background: true);
        bytes += await _store.writeText(
            journeyKey, OfflineStore.stationName(list[i]), res.body);
        stored++;
      } catch (_) {
        // Plenty of small halts genuinely have no bahnhof.de map.
        note ??= 'Nicht jeder Halt hat eine Bahnhofskarte';
      }
    }
    onProgress?.call(
        (kind: OfflinePartKind.stationMap, done: list.length, total: list.length));

    return OfflinePart(
      kind: OfflinePartKind.stationMap,
      expected: list.length,
      stored: stored,
      bytes: bytes,
      note: note,
    );
  }

  Future<OfflinePart> _downloadTiles({
    required String journeyKey,
    required Journey journey,
    required List<Trip> trips,
    required void Function(OfflineDownloadProgress)? onProgress,
    required bool Function() stopped,
  }) async {
    // The basemap needs its style bundle before any tile is worth anything —
    // without it no Style can be built offline and the map stays blank however
    // many tiles we cached. AWAIT it: fetching the style is what persists it, so
    // firing and forgetting would let a first-ever download report the style
    // missing purely because the fetch hadn't finished yet.
    final haveStyle = await TileCache.ensureStyle();
    if (!haveStyle) {
      return const OfflinePart(
        kind: OfflinePartKind.tiles,
        expected: 1,
        stored: 0,
        note: 'Kartenstil nicht verfügbar — Karte offline nicht nutzbar',
      );
    }

    final points = _routePoints(journey, trips);
    if (points.isEmpty) {
      return const OfflinePart(
        kind: OfflinePartKind.tiles,
        expected: 0,
        stored: 0,
        note: 'Keine Streckengeometrie — keine Kacheln nötig',
      );
    }

    final tiles = tilesAlongRoute(points);
    final res = await TileCache.prefetchVectorTiles(
      tiles,
      cancelled: stopped,
      onProgress: (done, total) => onProgress
          ?.call((kind: OfflinePartKind.tiles, done: done, total: total)),
    );
    await _store.writeTileList(journeyKey, res.files);

    // Capped by bytes (mid-download) or by the tile ceiling (before it started):
    // either way the corridor is short, and `expected` must stay the honest
    // count so the part reports itself incomplete rather than "all of it".
    final capped = res.capped || tiles.length >= kOfflineMaxTiles;
    return OfflinePart(
      kind: OfflinePartKind.tiles,
      expected: tiles.length,
      stored: res.files.length,
      bytes: res.bytes,
      note: capped
          ? 'Lange Strecke — Karte (Zoom $kOfflineTileMinZoom–$kOfflineTileMaxZoom) '
              'auf ${offlineSizeLabel(kOfflineMaxTileBytes)} begrenzt'
          : null,
    );
  }

  /// Points to lay the tile corridor over. The run's polyline is the truth (it
  /// follows the rails); a leg's stop coordinates are the fallback for a run we
  /// couldn't fetch or that carried no geometry.
  List<({double lat, double lng})> _routePoints(
      Journey journey, List<Trip> trips) {
    final points = <({double lat, double lng})>[];
    for (final trip in trips) {
      final poly = trip.polyline;
      if (poly != null && poly.isNotEmpty) {
        for (final p in poly) {
          final lat = p['lat'], lng = p['lng'];
          if (lat != null && lng != null) points.add((lat: lat, lng: lng));
        }
        continue;
      }
      for (final s in trip.stopovers) {
        final st = s.stop;
        if (st.hasLocation) {
          points.add((lat: st.latitude!, lng: st.longitude!));
        }
      }
    }
    if (points.isEmpty) {
      // Last resort: the journey's own endpoints still give a usable corridor.
      for (final leg in journey.legs) {
        for (final s in [leg.origin, leg.destination]) {
          if (s.hasLocation) points.add((lat: s.latitude!, lng: s.longitude!));
        }
      }
    }
    return points;
  }

  OfflinePart _ticketPart(OfflineTicketInfo ticket) {
    if (!ticket.exists) {
      // No ticket booked — nothing to carry, and not a shortfall.
      return const OfflinePart(
        kind: OfflinePartKind.ticket,
        expected: 0,
        stored: 0,
        note: 'Kein Ticket zu dieser Reise',
      );
    }
    return OfflinePart(
      kind: OfflinePartKind.ticket,
      expected: 1,
      stored: ticket.cached ? 1 : 0,
      note: ticket.cached
          ? 'Ticket inkl. Barcode liegt bereits offline vor'
          : 'Ticket noch nicht geladen — einmal im Profil öffnen',
    );
  }
}
