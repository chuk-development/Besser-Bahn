import 'package:latlong2/latlong.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/app_log.dart';
import '../core/osm_rail.dart';
import '../core/platform_train.dart' as pt;
import '../core/train_dimensions.dart';
import '../models/coach_sequence.dart';
import '../models/station.dart';
import '../models/station_map.dart';
import '../services/osm_bus_stop_service.dart';
import '../services/osm_platform_service.dart';
import '../services/station_map_service.dart';
import 'service_providers.dart';

// The Gleis-label parsing and the platform-train geometry live in the pure
// `core/platform_train.dart` module — shared with the Streckenverlauf route map
// so there's exactly ONE implementation. These re-exports keep the existing
// `normalizeGleis` / `parseGleisSection` call sites in the app working.
String normalizeGleis(String g) => pt.normalizeGleis(g);
({String start, String end})? parseGleisSection(String g) =>
    pt.parseGleisSection(g);

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
/// Default-visible categories when *browsing* a station (Karte tab), rather
/// than arriving from one journey leg. Every kind of transit stop bahnhof.de
/// ships — Gleise plus bus/tram/subway/replacement-bus halts — so a station
/// like Kiel shows its 17 bus stops (11 on the ground floor, 6 down in the
/// ZOB) instead of an empty basement. Amenities (lifts, lockers, stairs, WCs,
/// parking) stay hidden until the rider enables them in the legend, keeping
/// the first view uncluttered. Types absent at a station are simply no-ops.
const kTransitStopTypes = {
  'PLATFORM',
  'PLATFORM_SECTOR_CUBE',
  'BUS',
  'CITY_TRAIN', // bahnhof.de's key for S-Bahn / tram halts
  'SUBWAY',
  'RAIL_REPLACEMENT_TRANSPORT',
};

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

  /// The train's composition fetched at a stop that HAS Wagenreihung data (its
  /// origin), used as a fallback to still draw the train where the per-stop
  /// vehicle-sequence endpoint serves nothing — a regional train's TERMINUS /
  /// Ausstieg 404s, so we place this known composition on the platform instead
  /// of a bare line. [secondaryFallbackCoachSequence] is the Ausstieg train's.
  final CoachSequence? fallbackCoachSequence;
  final CoachSequence? secondaryFallbackCoachSequence;

  /// Product (ICE/IC/RE…) of the primary/secondary train, for a realistic
  /// generic-body length when there's no composition at all.
  final String? product;
  final String? secondaryProduct;

  /// The train this map was opened for, e.g. "RE 7" — shown in the banner so
  /// the map says which train it is. Null for a plain station lookup.
  final String? trainLabel;

  /// This station's OpenStreetMap platform/rail geometry, once Overpass has
  /// answered — the accurate track centre-line the platform train rides. Null
  /// while the (async, best-effort) fetch is pending or it failed/unavailable;
  /// the train then falls back to the bahnhof.de cube-straight placement.
  final OsmPlatformGeometry? osmGeometry;

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
    this.fallbackCoachSequence,
    this.secondaryFallbackCoachSequence,
    this.product,
    this.secondaryProduct,
    this.trainLabel,
    this.osmGeometry,
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
    CoachSequence? fallbackCoachSequence,
    CoachSequence? secondaryFallbackCoachSequence,
    String? product,
    String? secondaryProduct,
    String? trainLabel,
    OsmPlatformGeometry? osmGeometry,
    bool clearOsmGeometry = false,
    bool clearHighlight = false,
    bool clearSection = false,
    bool clearTransferNote = false,
    bool clearSecondary = false,
    bool clearCoachSequence = false,
    bool clearFallback = false,
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
      fallbackCoachSequence: clearFallback
          ? null
          : (fallbackCoachSequence ?? this.fallbackCoachSequence),
      secondaryFallbackCoachSequence: (clearFallback || clearSecondary)
          ? null
          : (secondaryFallbackCoachSequence ??
              this.secondaryFallbackCoachSequence),
      product: clearFallback ? null : (product ?? this.product),
      secondaryProduct: (clearFallback || clearSecondary)
          ? null
          : (secondaryProduct ?? this.secondaryProduct),
      trainLabel:
          clearTrainLabel ? null : (trainLabel ?? this.trainLabel),
      osmGeometry:
          clearOsmGeometry ? null : (osmGeometry ?? this.osmGeometry),
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
    // A bus stop has no Gleise — its "Gleis" is the bay letter on a pole, and
    // marking the right pole is the whole point of that map (#55).
    for (final p in m.pois) {
      if (p.type == 'BUS' && normalizeGleis(p.name) == g) return p;
    }
    return null;
  }

  /// Role to highlight [poi] as on the map: primary, secondary, or none.
  GleisRole roleForPoi(MapPoi poi) {
    if (!poi.isPlatform && poi.type != 'BUS') return GleisRole.none;
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

  /// The real OSM rail spine the train at [g] rides, derived from this station's
  /// fetched Overpass geometry (the accurate track centre-line — see
  /// core/osm_rail.dart). Null while the fetch is pending/failed or the Gleis
  /// can't be resolved, in which case every caller falls back to the existing
  /// bahnhof.de cube-straight placement. Threaded into the pure platform_train
  /// functions as `osmRail:`.
  List<LatLng>? _osmRailFor(String? g) {
    final m = map;
    final osm = osmGeometry;
    if (m == null || g == null || osm == null) return null;
    final cubeSide = pt.platformCubeSide(m, g);
    if (cubeSide.length < 2) return null;
    // The station's Gleis markers, so the rail side can be decided from the OSM
    // island pairing instead of the (shared, ambiguous) sector cubes.
    final gleisPoi = <String, LatLng>{
      for (final p in m.platforms) normalizeGleis(p.name): p.latLng,
    };
    final rail = osmRailForGleis(
      platforms: osm.platforms,
      rails: osm.rails,
      gleis: g,
      cubeSide: cubeSide,
      gleisPoi: gleisPoi,
    );
    return rail.length >= 2 ? rail : null;
  }

  // The section line and platform-train placement both delegate to the pure
  // `core/platform_train.dart` module — the SAME implementation the route map's
  // parked trains use, so the Bahnhofskarte and Streckenverlauf can never drift.
  List<({String letter, LatLng pos})> _sectionLineFor(
      MapPoi? plat, ({String start, String end})? range, String? g) {
    final m = map;
    if (m == null || plat == null || g == null) return const [];
    return pt.platformSectionLine(m, plat, range, g, osmRail: _osmRailFor(g));
  }

  /// The boarding (Einstieg) train drawn to scale, top-down, on its platform.
  List<({List<LatLng> outline, Coach coach, bool boarding})>
      get boardingTrainCars => _trainCarsFor(
          highlightGleis, highlightSection, coachSequence, fallbackCoachSequence);

  /// The Ausstieg train on a transfer map — the arriving train on its Gleis.
  List<({List<LatLng> outline, Coach coach, bool boarding})>
      get secondaryTrainCars => _trainCarsFor(secondaryGleis, secondarySection,
          secondaryCoachSequence, secondaryFallbackCoachSequence);

  /// Per-car train at [g]: the exact per-stop Wagenreihung when we have it,
  /// else the train's known composition ([fallback]) placed to scale on this
  /// platform — for stops the vehicle-sequence endpoint doesn't serve (a
  /// regional train's Ausstieg/terminus). Empty only when we know neither.
  List<({List<LatLng> outline, Coach coach, bool boarding})> _trainCarsFor(
      String? g,
      ({String start, String end})? section,
      CoachSequence? cs,
      CoachSequence? fallback) {
    final m = map;
    if (m == null || g == null) return const [];
    final osmRail = _osmRailFor(g);
    if (cs != null) {
      return pt.platformTrainCars(
          m, gleis: g, section: section, cs: cs, osmRail: osmRail);
    }
    if (fallback != null) {
      return pt.platformTrainFromComposition(
          m, gleis: g, section: section, cs: fallback, osmRail: osmRail);
    }
    return const [];
  }

  /// A single curved train BODY along the boarding Gleis, drawn ONLY when we
  /// have NO composition at all (e.g. an ÖBB RJ the DB coach API never carries)
  /// — so the map still shows a *train*, not a bare line. Sized to a realistic
  /// per-product length, NOT the whole platform. Empty once any per-car train
  /// (exact or composition fallback) is drawn.
  List<LatLng> get boardingGenericBody => _genericBodyFor(highlightGleis,
      highlightSection, boardingTrainCars.isEmpty, product);

  /// Same, for the Ausstieg (arriving) train's Gleis on a transfer map.
  List<LatLng> get secondaryGenericBody => _genericBodyFor(secondaryGleis,
      secondarySection, secondaryTrainCars.isEmpty, secondaryProduct);

  List<LatLng> _genericBodyFor(String? g, ({String start, String end})? section,
      bool noCars, String? prod) {
    final m = map;
    if (m == null || g == null || !noCars) return const [];
    final dims = TrainDimensions.forProduct(prod);
    return pt.platformGenericBody(
      m,
      gleis: g,
      section: section,
      lengthM: dims.totalLengthM,
      highSpeed: _highSpeedLabel,
      osmRail: _osmRailFor(g),
    );
  }

  /// Best-effort high-speed guess from the train label when we have no
  /// Wagenreihung to tell us — only affects the body's width/nose slightly.
  bool get _highSpeedLabel {
    final l = trainLabel?.toUpperCase() ?? '';
    return l.startsWith('ICE') || l.startsWith('ECE');
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

  /// Optional ORIGIN refs for the train(s): the stop that HAS Wagenreihung data
  /// (the train's origin departure), used to fetch the known composition as a
  /// fallback for stops the per-station vehicle-sequence endpoint doesn't serve
  /// (a regional train's terminus/Ausstieg 404s). [_fallbackRef] is the Einstieg
  /// train; [_secondaryFallbackRef] is the Ausstieg train on a transfer.
  ({String category, String trainNumber, String originEva, DateTime? departureTime})?
      _fallbackRef;
  ({String category, String trainNumber, String originEva, DateTime? departureTime})?
      _secondaryFallbackRef;

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
      CoachSequence? fallbackCoachSequence,
      CoachSequence? secondaryFallbackCoachSequence,
      ({String category, String trainNumber, String originEva, DateTime? departureTime})?
          fallbackRef,
      ({String category, String trainNumber, String originEva, DateTime? departureTime})?
          secondaryFallbackRef,
      String? product,
      String? secondaryProduct,
      String? trainLabel,
      Set<String>? primaryTypes}) async {
    // No explicit types → browsing this station: show every transit stop, not
    // just Gleise. A journey passes its own (e.g. just the boarding Gleise).
    _primaryTypes = primaryTypes ?? kTransitStopTypes;
    _coachRef = coachRef;
    _coachRefSecondary = secondaryCoachRef;
    _fallbackRef = fallbackRef;
    _secondaryFallbackRef = secondaryFallbackRef;
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
      // The known composition (from the train's origin) to fall back to where
      // this stop's per-station Wagenreihung 404s (regional Ausstieg/terminus).
      fallbackCoachSequence: fallbackCoachSequence,
      secondaryFallbackCoachSequence: secondaryFallbackCoachSequence,
      product: product,
      secondaryProduct: secondaryProduct,
      clearFallback: fallbackCoachSequence == null &&
          secondaryFallbackCoachSequence == null &&
          fallbackRef == null &&
          secondaryFallbackRef == null &&
          product == null &&
          secondaryProduct == null,
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
    // Slug entry is always a browse (no journey context) → show all stops.
    _primaryTypes = kTransitStopTypes;
    _coachRef = null;
    _coachRefSecondary = null;
    _fallbackRef = null;
    _secondaryFallbackRef = null;
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

    // The fallback compositions come from each train's ORIGIN departure (a stop
    // the vehicle-sequence endpoint always serves) — so we can still draw the
    // train where THIS stop's per-station sequence 404s (regional terminus).
    Future<CoachSequence?> fetchOrigin(
        ({String category, String trainNumber, String originEva, DateTime? departureTime})?
            r) async {
      if (r == null || r.trainNumber.isEmpty || r.originEva.isEmpty) return null;
      try {
        return await svc.getCoachSequenceForDeparture(
          category: r.category,
          trainNumber: r.trainNumber,
          stationEva: r.originEva,
          departureTime: r.departureTime,
        );
      } catch (_) {
        return null;
      }
    }

    final results = await Future.wait([
      fetch(_coachRef),
      fetch(_coachRefSecondary),
      fetchOrigin(_fallbackRef),
      fetchOrigin(_secondaryFallbackRef),
    ]);
    final primary = results[0];
    final secondary = results[1];
    final primaryFallback = results[2];
    final secondaryFallback = results[3];
    if (primary == null &&
        secondary == null &&
        primaryFallback == null &&
        secondaryFallback == null) {
      return;
    }
    state = state.copyWith(
      // Don't clobber a successfully-fetched exact per-stop sequence with null.
      coachSequence: primary,
      secondaryCoachSequence: secondary,
      // The origin composition is a fallback only — never overwrites a non-null
      // value we already had with null (copyWith keeps the existing one).
      fallbackCoachSequence: primaryFallback,
      secondaryFallbackCoachSequence: secondaryFallback,
    );
  }

  Future<void> _load(Future<StationMap> Function() fetch) async {
    // A new station's map → drop the previous station's OSM geometry so the
    // train never rides the wrong station's rail while the new fetch is pending.
    state = state.copyWith(
        isLoading: true, clearError: true, clearOsmGeometry: true);
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
      // Fetch this station's OSM platform/rail geometry (Overpass) so the
      // platform train rides the real, accurate track curve instead of the
      // straight cube fallback. Best-effort and non-blocking: if it never
      // arrives or fails, the train still draws from the cubes.
      _loadOsmGeometry(map);
      // Then attach the platform train(s) for this stop (non-blocking visually).
      final st = state.station;
      if (st != null) await _loadCoachSequences(st);
    } on StationMapException catch (e) {
      // Known/expected failure (bad slug, no map data) — message is user-safe.
      AppLog.log('map load failed (StationMapException): ${e.message}',
          tag: 'map');
      // bahnhof.de only maps railway stations. A bus or tram stop lands here
      // every time — and that is exactly the stop where the rider needs to know
      // which side of the street to stand on, so build the map from OSM instead
      // of showing an error (#55).
      if (await _loadBusStopMap()) return;
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

  /// Build this stop's map from OpenStreetMap when bahnhof.de has none.
  ///
  /// A stop like "Gravelottestraße" is two to four poles — one per direction,
  /// sometimes lettered. The timetable names only the stop, so the rider had no
  /// way to tell which side of the street to wait on. OSM maps every pole, and
  /// the bay letter it carries (`local_ref`) is the same letter vendo puts in a
  /// bus leg's `gleis` — so the pole the rider needs gets the green Einstieg
  /// marker like a Gleis would (#55).
  ///
  /// Returns false when there's nothing to build from (no coordinates, no OSM
  /// data, Overpass unreachable) — then the caller keeps its error state.
  Future<bool> _loadBusStopMap() async {
    final station = state.station;
    final lat = station?.latitude, lon = station?.longitude;
    if (station == null || lat == null || lon == null) return false;
    final center = LatLng(lat, lon);
    final bays = await OsmBusStopService.instance.fetch(center, station.name);
    if (bays.isEmpty) return false;
    // Keep the rider's own stop centred rather than the average pole: the poles
    // of one stop sit metres apart, and the timetable coordinate is the one the
    // route was searched against.
    final map = StationMap(
      slug: 'osm:stop:${station.name.toLowerCase()}',
      center: center,
      levels: const ['GROUND_FLOOR'],
      levelInit: 'GROUND_FLOOR',
      pois: [
        for (final bay in bays)
          MapPoi(
            type: 'BUS',
            name: bay.label,
            detail: [
              if (bay.bay != null) bay.name,
              ?bay.directionLabel,
              if (bay.shelter) 'mit Wartehäuschen',
            ].join(' · '),
            level: 'GROUND_FLOOR',
            latitude: bay.latLng.latitude,
            longitude: bay.latLng.longitude,
          ),
      ],
    );
    AppLog.log(
        'map built from OSM: "${station.name}" ${bays.length} poles '
        '(highlight ${state.highlightGleis ?? '–'})',
        tag: 'map');
    state = state.copyWith(
      map: map,
      selectedLevel: 'GROUND_FLOOR',
      hiddenCategories: const {},
      isLoading: false,
      clearError: true,
    );
    return true;
  }

  /// Fetch [map]'s OSM platform/rail geometry and attach it once it lands,
  /// triggering a rebuild so the platform train re-renders on the real rail.
  /// Reads the in-memory cache synchronously if it's already warm. Guards
  /// against a stale arrival: if the user has since loaded another station, the
  /// result is dropped.
  Future<void> _loadOsmGeometry(StationMap map) async {
    final svc = OsmPlatformService.instance;
    if (svc.isResolved(map.slug)) {
      final cached = svc.cached(map.slug);
      if (cached != null && identical(state.map, map)) {
        state = state.copyWith(osmGeometry: cached);
      }
      return;
    }
    final geom = await svc.fetch(map.slug, map.center);
    // Only apply if this is still the station on screen.
    if (geom != null && identical(state.map, map)) {
      state = state.copyWith(osmGeometry: geom);
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

/// The **Bahnhof tab's** map — the station you browse to yourself, with your
/// floor and your filters, kept as you left it.
final stationMapProvider =
    NotifierProvider<StationMapNotifier, StationMapState>(
        StationMapNotifier.new);

/// The map opened **from a trip** (a stop on the Reiseplan, a Halt in the Zug
/// view): its own instance of the same notifier.
///
/// They used to share one, so opening a Gleis from a journey silently replaced
/// whatever station the Bahnhof tab was showing — go back to the tab and you
/// were somewhere else, on another floor, with a green Einstieg marker from a
/// trip you had just been reading (#54). Nothing about the two is the same
/// question, so nothing about them is shared state now.
final dedicatedStationMapProvider =
    NotifierProvider<StationMapNotifier, StationMapState>(
        StationMapNotifier.new);
