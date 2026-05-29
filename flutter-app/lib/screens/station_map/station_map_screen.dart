import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';

import '../../core/extensions.dart';
import '../../models/departure.dart';
import '../../models/station.dart';
import '../../models/station_map.dart';
import '../../providers/service_providers.dart';
import '../../providers/station_map_provider.dart';
import '../../providers/train_lookup_provider.dart';
import '../../services/location_service.dart';
import '../../theme/app_colors.dart';
import '../../widgets/traewelling_avatar_button.dart';
import '../../widgets/delay_badge.dart';
import '../../widgets/station_search_field.dart';

/// Marker/legend colour per POI type, matching bahnhof.de: tracks red,
/// sectors dark, everything else DB blue.
Color _poiColor(String type) {
  switch (type) {
    case 'PLATFORM':
      return AppColors.dbRed;
    case 'PLATFORM_SECTOR_CUBE':
      return Colors.black54;
    default:
      return AppColors.dbBlue;
  }
}

/// POI categories that have live departures we can show for a specific bay.
const _departureCategories = {
  'PLATFORM',
  'BUS',
  'TRAM',
  'SUBWAY',
  'CITY_TRAIN',
  'RAIL_REPLACEMENT_TRANSPORT',
};

/// Live indoor station map ("Bahnhofskarte"), scraped from bahnhof.de.
///
/// Pick a station, get its Gleise, lifts, stairs, exits etc. plotted on an
/// OpenStreetMap layer with a floor switcher — an open alternative to the
/// official DB app's station map.
class StationMapScreen extends ConsumerStatefulWidget {
  const StationMapScreen({super.key});

  @override
  ConsumerState<StationMapScreen> createState() => _StationMapScreenState();
}

class _StationMapScreenState extends ConsumerState<StationMapScreen> {
  final _mapController = MapController();

  /// POI tapped on the map; shown as an inline card, not a bottom sheet.
  MapPoi? _selectedPoi;

  /// The user's last device fix (blue dot). Null until they tap "Mein Standort".
  UserFix? _userFix;

  /// True while a location request is in flight (spinner on the button).
  bool _locating = false;

  @override
  void dispose() {
    _mapController.dispose();
    super.dispose();
  }

  /// Where the rider needs to get to: the highlighted boarding Gleis if we
  /// came from a journey, otherwise the station centre.
  LatLng _targetFor(StationMap map) =>
      ref.read(stationMapProvider).highlightPoi?.latLng ?? map.center;

  /// Request the device location and frame it together with the target so the
  /// rider sees where they are and roughly which way to walk.
  Future<void> _locateMe(StationMap map) async {
    setState(() => _locating = true);
    try {
      final fix = await ref.read(locationServiceProvider).currentFix();
      if (!mounted) return;
      setState(() => _userFix = fix);
      _mapController.fitCamera(
        CameraFit.bounds(
          bounds: LatLngBounds.fromPoints([fix.latLng, _targetFor(map)]),
          padding: const EdgeInsets.all(72),
          maxZoom: 18.5,
        ),
      );
    } on LocationException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message)),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Standort konnte nicht ermittelt werden.')),
        );
      }
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  void _recenter(StationMap map) {
    final s = ref.read(stationMapProvider);
    final hl = s.highlightPoi;
    final section = s.highlightSectionLine;
    // Boarding section known → frame the whole section range on the platform.
    if (section.isNotEmpty) {
      final pts = [
        ...section.map((e) => e.pos),
        if (hl != null) hl.latLng,
      ];
      _mapController.fitCamera(
        CameraFit.bounds(
          bounds: LatLngBounds.fromPoints(pts),
          padding: const EdgeInsets.all(64),
          maxZoom: 18.5,
        ),
      );
    } else if (hl != null) {
      // Prefer the highlighted boarding Gleis (journey context) over the centre.
      _mapController.move(hl.latLng, 18.5);
    } else {
      _mapController.move(map.center, 17.5);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(stationMapProvider);
    final notifier = ref.read(stationMapProvider.notifier);
    final map = state.map;

    // Re-centre whenever a new station finishes loading.
    ref.listen(stationMapProvider.select((s) => s.map), (prev, next) {
      if (next != null && next != prev) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _recenter(next));
      }
    });

    return Scaffold(
      appBar: AppBar(
        title: Text(state.station?.name ?? 'Bahnhofskarte'),
        actions: [
          const TraewellingAvatarButton(),
          if (map != null)
            IconButton(
              tooltip: 'Zentrieren',
              icon: const Icon(Icons.my_location),
              onPressed: () => _recenter(map),
            ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: StationSearchField(
              hint: 'Bahnhof suchen...',
              prefixIcon: Icons.location_city,
              initialStation: state.station,
              onSelected: (s) => notifier.loadForStation(s),
            ),
          ),
          if (state.highlightGleis != null && map != null)
            _BoardingBanner(
              gleis: state.highlightGleis!,
              section: state.highlightSection,
            ),
          Expanded(child: _buildBody(context, state, notifier)),
        ],
      ),
    );
  }

  Widget _buildBody(
    BuildContext context,
    StationMapState state,
    StationMapNotifier notifier,
  ) {
    if (state.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.error != null) {
      return _Message(
        icon: Icons.map_outlined,
        title: 'Keine Karte',
        subtitle: state.error!,
      );
    }
    final map = state.map;
    if (map == null) {
      return const _Message(
        icon: Icons.location_city,
        title: 'Bahnhof wählen',
        subtitle: 'Suche einen Bahnhof, um seine Karte mit Gleisen, '
            'Aufzügen und Ausgängen zu sehen.',
      );
    }

    return Stack(
      children: [
        FlutterMap(
          mapController: _mapController,
          options: MapOptions(
            initialCenter: map.center,
            initialZoom: 17.5,
            minZoom: 13,
            maxZoom: 19,
            // Tapping empty map dismisses the inline POI card.
            onTap: (_, __) {
              if (_selectedPoi != null) setState(() => _selectedPoi = null);
            },
          ),
          children: [
            // Clean, low-clutter light base map (CartoDB Positron): streets
            // and place labels only, no shop/restaurant POIs competing with
            // our station markers. Free, no API key.
            TileLayer(
              urlTemplate:
                  'https://{s}.basemaps.cartocdn.com/light_all/{z}/{x}/{y}{r}.png',
              subdomains: const ['a', 'b', 'c', 'd'],
              retinaMode: RetinaMode.isHighDensity(context),
              userAgentPackageName: 'de.chuk.besserebahn',
              maxZoom: 20,
            ),
            // Real Deutsche Bahn indoor floor plan for the selected floor —
            // the actual building outline, platform halls and track geometry,
            // straight from the tile service bahnhof.de itself renders. The
            // `ValueKey(level)` forces a fresh layer (and tile fetch) whenever
            // the user switches floors. Tiles are 512px retina for a logical
            // 256 tileSize, so we render at 256 and let flutter_map upscale.
            if (state.selectedLevel != null &&
                state.selectedLevel!.isNotEmpty)
              TileLayer(
                // No ValueKey on the level: keep ONE persistent layer and just
                // swap urlTemplate when the floor changes. flutter_map updates
                // the tiles in place and Flutter's image cache keeps already-
                // fetched floors in memory, so re-visiting a floor is instant
                // (no flash, no re-download) while the page stays open.
                urlTemplate: StationMap.indoorTileUrl(state.selectedLevel!),
                tileSize: 256,
                minNativeZoom: 14,
                maxNativeZoom: 18,
                maxZoom: 20,
                tileProvider: NetworkTileProvider(
                  // Not const: flutter_map mutates this map to add a
                  // User-Agent (putIfAbsent), which throws on an
                  // unmodifiable/const map.
                  headers: {'Referer': 'https://www.bahnhof.de/'},
                ),
                userAgentPackageName: 'de.chuk.besserebahn',
                // Indoor tiles only cover the station; missing tiles
                // elsewhere should just be transparent, not error pins.
                errorTileCallback: (_, __, ___) {},
              ),
            // Boarding section: amber line + labelled markers along the
            // platform from the first to the last sector of the highlighted
            // range (e.g. C–G), interpolated onto the boarding Gleis.
            if (state.highlightSectionLine.length >= 2)
              PolylineLayer(
                polylines: [
                  Polyline(
                    points: state.highlightSectionLine
                        .map((e) => e.pos)
                        .toList(),
                    color: Colors.amber.shade700,
                    strokeWidth: 7,
                    borderColor: Colors.white,
                    borderStrokeWidth: 2,
                  ),
                ],
              ),
            MarkerLayer(
                markers:
                    _markers(context, state.visiblePois, state.station)),
            if (state.highlightSectionLine.isNotEmpty)
              MarkerLayer(markers: _sectionMarkers(state.highlightSectionLine)),
            // "Mein Standort": the direction line to the target, the GPS
            // accuracy circle, and the blue dot — drawn on top of the POIs.
            if (_userFix != null) ...[
              PolylineLayer(
                polylines: [
                  Polyline(
                    points: [_userFix!.latLng, _targetFor(map)],
                    color: AppColors.dbBlue.withAlpha(180),
                    strokeWidth: 4,
                    pattern: StrokePattern.dotted(),
                  ),
                ],
              ),
              CircleLayer(
                circles: [
                  CircleMarker(
                    point: _userFix!.latLng,
                    radius: _userFix!.accuracy,
                    useRadiusInMeter: true,
                    color: AppColors.dbBlue.withAlpha(30),
                    borderColor: AppColors.dbBlue.withAlpha(90),
                    borderStrokeWidth: 1,
                  ),
                ],
              ),
              MarkerLayer(markers: [_userMarker(_userFix!.latLng)]),
            ],
            const RichAttributionWidget(
              alignment: AttributionAlignment.bottomLeft,
              // The default flutter_map logo is a package asset that isn't
              // bundled → it spams "Unable to load AssetManifest.bin". Disable.
              showFlutterMapAttribution: false,
              attributions: [
                TextSourceAttribution('© OpenStreetMap'),
                TextSourceAttribution('© CARTO'),
                TextSourceAttribution('Bahnhofsplan © DB InfraGO'),
              ],
            ),
          ],
        ),
        Positioned(
          left: 8,
          top: 8,
          bottom: 8,
          child: _LevelSwitcher(
            map: map,
            selected: state.selectedLevel,
            onSelect: notifier.selectLevel,
          ),
        ),
        Positioned(
          right: 8,
          bottom: 8,
          child: _Legend(
            categories: map.categoriesOnLevel(state.selectedLevel ?? ''),
            hidden: state.hiddenCategories,
            onToggle: notifier.toggleCategory,
          ),
        ),
        // "Mein Standort" button — request GPS and frame you + your target.
        Positioned(
          right: 8,
          top: 8,
          child: FloatingActionButton.small(
            heroTag: 'locate-me',
            tooltip: 'Mein Standort',
            onPressed: _locating ? null : () => _locateMe(map),
            child: _locating
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.near_me),
          ),
        ),
        // How far you still have to walk to the target.
        if (_userFix != null)
          Positioned(
            left: 0,
            right: 0,
            bottom: 16,
            child: Center(child: _DistanceChip(metres: _distanceToTarget(map))),
          ),
        // Inline POI card — shown over the map (not a bottom sheet).
        if (_selectedPoi != null)
          Positioned(
            left: 60,
            right: 60,
            top: 8,
            child: _PoiCard(
              poi: _selectedPoi!,
              onClose: () => setState(() => _selectedPoi = null),
            ),
          ),
      ],
    );
  }

  List<Marker> _markers(
      BuildContext context, List<MapPoi> pois, Station? station) {
    final highlight = ref.read(stationMapProvider).highlightGleis;
    // Phones get smaller markers — the desktop sizes crowd a small screen.
    final compact = MediaQuery.of(context).size.shortestSide < 600;
    return [
      for (final poi in pois)
        Marker(
          point: poi.latLng,
          width: poi.isPlatform ? (compact ? 38 : 46) : (compact ? 27 : 34),
          height: compact ? 27 : 34,
          child: GestureDetector(
            // Gleise / transit bays open their live departures straight away;
            // everything else shows the small inline info card.
            onTap: () {
              if (station != null && _departureCategories.contains(poi.type)) {
                setState(() => _selectedPoi = null);
                _showBayDepartures(poi, station);
              } else {
                setState(() => _selectedPoi = poi);
              }
            },
            child: _PoiMarker(
              poi: poi,
              compact: compact,
              selected: identical(poi, _selectedPoi),
              boarding: poi.isPlatform &&
                  highlight != null &&
                  normalizeGleis(poi.name) == highlight,
            ),
          ),
        ),
    ];
  }

  /// Amber labelled chips for the interpolated boarding-section letters,
  /// drawn on top of the section line so the rider sees exactly where to wait.
  List<Marker> _sectionMarkers(List<({String letter, LatLng pos})> section) {
    return [
      for (final s in section)
        Marker(
          point: s.pos,
          width: 26,
          height: 26,
          child: Container(
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: Colors.amber.shade700,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 2),
              boxShadow: const [
                BoxShadow(color: Colors.amber, blurRadius: 8, spreadRadius: 1),
              ],
            ),
            child: Text(
              s.letter,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.bold),
            ),
          ),
        ),
    ];
  }

  /// Straight-line distance (metres) from the user's fix to the target.
  double _distanceToTarget(StationMap map) =>
      const Distance().as(LengthUnit.Meter, _userFix!.latLng, _targetFor(map));

  /// The classic "blue dot" for the user's own position.
  Marker _userMarker(LatLng pos) => Marker(
        point: pos,
        width: 22,
        height: 22,
        child: Container(
          decoration: BoxDecoration(
            color: AppColors.dbBlue,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 3),
            boxShadow: const [
              BoxShadow(color: Colors.black26, blurRadius: 4, spreadRadius: 1),
            ],
          ),
        ),
      );

  void _showBayDepartures(MapPoi poi, Station station) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _BayDeparturesSheet(stationEva: station.id, poi: poi),
    );
  }
}

/// Compact info card shown over the map when a POI is tapped.
class _PoiCard extends StatelessWidget {
  final MapPoi poi;
  final VoidCallback onClose;

  const _PoiCard({required this.poi, required this.onClose});

  @override
  Widget build(BuildContext context) {
    final meta = _CategoryMeta.of(poi.type);
    final inactive = poi.status != null && poi.status != 'ACTIVE';
    return Card(
      elevation: 4,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: _poiColor(poi.type),
                    borderRadius: BorderRadius.circular(7),
                  ),
                  child: Icon(meta.icon, color: Colors.white, size: 18),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        poi.isPlatform ? 'Gleis ${poi.name}' : poi.name,
                        style: Theme.of(context).textTheme.titleSmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        poi.detail?.isNotEmpty == true
                            ? poi.detail!
                            : meta.label,
                        style: Theme.of(context).textTheme.bodySmall,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                if (inactive)
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 4),
                    child: Icon(Icons.warning_amber,
                        color: AppColors.warning, size: 18),
                  ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: onClose,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Bottom sheet listing the live departures from one Gleis / transit bay.
/// Tapping a departure opens its full run on the train screen.
class _BayDeparturesSheet extends ConsumerStatefulWidget {
  final String stationEva;
  final MapPoi poi;

  const _BayDeparturesSheet({required this.stationEva, required this.poi});

  @override
  ConsumerState<_BayDeparturesSheet> createState() =>
      _BayDeparturesSheetState();
}

class _BayResult {
  final List<Departure> deps;
  final bool matchedBay; // true = filtered to this bay; false = all departures
  const _BayResult(this.deps, this.matchedBay);
}

class _BayDeparturesSheetState extends ConsumerState<_BayDeparturesSheet> {
  late Future<_BayResult> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<_BayResult> _load() async {
    final hafas = ref.read(hafasServiceProvider);

    // Universal stop resolution: a bay may physically belong to a different
    // stop than the searched station (e.g. a ZOB or U-Bahn with its own EVA).
    // Resolve the nearest stop to the POI's coordinates and query *its* board,
    // so this works for any station without a hand-maintained mapping.
    var eva = widget.stationEva;
    final poi = widget.poi;
    // Only transit bays may belong to a different stop (ZOB, U-Bahn). Train
    // Gleise always belong to the searched rail station, so don't re-resolve
    // them (a nearby bus stop would otherwise hijack them).
    if (!poi.isPlatform) {
      try {
        final near = await hafas.nearbyStations(
          latitude: poi.latitude,
          longitude: poi.longitude,
          results: 1,
          distance: 150,
        );
        if (near.isNotEmpty && near.first.id.isNotEmpty) {
          eva = near.first.id;
        }
      } catch (_) {/* keep searched-station eva */}
    }

    final all = await hafas.getDepartures(eva, results: 100);

    // 1) Restrict to the POI's transport mode FIRST — otherwise a bus bay
    //    labelled "1/3" would wrongly match railway platform "1" (a train).
    final products = _modeProducts(widget.poi);
    final modeDeps = products.isEmpty
        ? all
        : all.where((d) => products.contains(d.line.product)).toList();

    // 2) Within that mode, match the specific bay/track.
    final matched = modeDeps.where(_matchesBay).toList();
    if (matched.isNotEmpty) return _BayResult(matched, true);

    // 3) Bay label couldn't be matched (e.g. multi-level ZOB uses a different
    //    numbering than the operator) → show all departures of the SAME mode,
    //    never a different mode, so a bus bay never shows trains.
    return _BayResult(modeDeps, false);
  }

  /// Departure products that belong to this POI's mode.
  Set<String> _modeProducts(MapPoi poi) {
    switch (poi.type) {
      case 'BUS':
      case 'RAIL_REPLACEMENT_TRANSPORT':
        return {'bus'};
      case 'TRAM':
        return {'tram'};
      case 'SUBWAY':
        return {'subway'};
      case 'CITY_TRAIN':
        return {'suburban'};
      case 'PLATFORM': // a Gleis carries trains (incl. S-Bahn)
        return {'nationalExpress', 'national', 'regional', 'suburban'};
      default:
        return {};
    }
  }

  /// Normalise a track/bay label to its base id, dropping the platform
  /// SECTION suffix that the departure board adds but the map omits:
  /// "6A-C" → "6", "1 A - D" → "1", "13D-F" → "13", "A2" → "A2".
  /// This is what makes the match work for trains at every station.
  String _normGleis(String g) {
    g = g.trim();
    if (g.isEmpty) return g;
    if (RegExp(r'^\d').hasMatch(g)) {
      return RegExp(r'^\d+').firstMatch(g)!.group(0)!; // leading track number
    }
    return g.split(RegExp(r'\s+')).first.toUpperCase(); // e.g. bus bay "A2"
  }

  /// Does a departure leave from this POI's bay/track?
  bool _matchesBay(Departure d) {
    final raw = (d.platform ?? '').trim();
    if (raw.isEmpty) return false;
    final base = _normGleis(raw);
    if (widget.poi.isPlatform) {
      return _normGleis(widget.poi.name) == base;
    }
    // Transit bay: the base id must appear as a whole token in the bay label
    // (so "C2" doesn't match "C20", and "1" matches "Bussteig [H]1/[H]3").
    final hay = '${widget.poi.detail ?? ''} ${widget.poi.name}';
    bool token(String t) =>
        t.isNotEmpty &&
        RegExp('(^|[^0-9A-Za-z])${RegExp.escape(t)}([^0-9A-Za-z]|\$)')
            .hasMatch(hay);
    return token(base) || token(raw);
  }

  /// German label for the POI's mode, for the "all departures" fallback header.
  String get _modeLabel {
    switch (widget.poi.type) {
      case 'BUS':
        return 'Bus';
      case 'RAIL_REPLACEMENT_TRANSPORT':
        return 'SEV';
      case 'TRAM':
        return 'Tram';
      case 'SUBWAY':
        return 'U-Bahn';
      case 'CITY_TRAIN':
        return 'S-Bahn';
      case 'PLATFORM':
        return 'Zug';
      default:
        return '';
    }
  }

  void _openTrain(Departure d) {
    ref.read(trainLookupProvider.notifier).lookupByTripId(d.tripId);
    Navigator.of(context).pop();
    context.go('/train');
  }

  @override
  Widget build(BuildContext context) {
    final bayLabel =
        widget.poi.isPlatform ? 'Gleis ${widget.poi.name}' : (widget.poi.detail ?? widget.poi.name);
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      maxChildSize: 0.9,
      builder: (context, scrollController) {
        return FutureBuilder<_BayResult>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            final res = snap.data;
            final deps = res?.deps ?? const <Departure>[];
            final title = (res?.matchedBay ?? true)
                ? 'Abfahrten $bayLabel'
                : 'Abfahrten ${widget.poi.name == 'Bus' ? 'Bus' : bayLabel}';
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                  child: Text(title,
                      style: Theme.of(context).textTheme.titleMedium),
                ),
                if (res != null && !res.matchedBay)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: Text(
                      'Steig „$bayLabel“ ließ sich nicht eindeutig zuordnen – '
                      'alle $_modeLabel-Abfahrten (Steig je Zeile):',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                Expanded(
                  child: deps.isEmpty
                      ? const Center(
                          child: Padding(
                            padding: EdgeInsets.all(24),
                            child: Text('Aktuell keine Abfahrten.',
                                textAlign: TextAlign.center),
                          ),
                        )
                      : ListView.separated(
                          controller: scrollController,
                          itemCount: deps.length,
                          separatorBuilder: (_, __) =>
                              const Divider(height: 1),
                          itemBuilder: (_, i) => _DepartureRow(
                            dep: deps[i],
                            showBay: !(res?.matchedBay ?? true),
                            onTap: () => _openTrain(deps[i]),
                          ),
                        ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

class _DepartureRow extends StatelessWidget {
  final Departure dep;
  final VoidCallback onTap;
  final bool showBay;
  const _DepartureRow(
      {required this.dep, required this.onTap, this.showBay = false});

  @override
  Widget build(BuildContext context) {
    final time = (dep.when ?? dep.plannedWhen)?.hhmm ?? '';
    final bay = dep.platform;
    final sub = [
      if (dep.line.displayName.isNotEmpty) dep.line.displayName,
      if (showBay && bay != null && bay.isNotEmpty) 'Steig $bay',
    ].join('  ·  ');
    return ListTile(
      onTap: onTap,
      leading: _LineChip(dep: dep),
      title: Text(dep.direction,
          maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: sub.isNotEmpty ? Text(sub) : null,
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(time,
              style: const TextStyle(fontWeight: FontWeight.w600)),
          DelayBadge(delaySeconds: dep.delay, cancelled: dep.cancelled),
        ],
      ),
    );
  }
}

/// Small coloured product chip (ICE red, S green, U blue, Bus violet …).
class _LineChip extends StatelessWidget {
  final Departure dep;
  const _LineChip({required this.dep});

  @override
  Widget build(BuildContext context) {
    final color = _productColor(dep.line.product);
    final label = dep.line.productName.isNotEmpty
        ? dep.line.productName
        : dep.line.displayName;
    return Container(
      width: 44,
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(6),
      ),
      alignment: Alignment.center,
      child: Text(
        label.length > 5 ? label.substring(0, 5) : label,
        style: const TextStyle(
            color: Colors.white, fontWeight: FontWeight.bold, fontSize: 11),
        maxLines: 1,
      ),
    );
  }

  Color _productColor(String product) {
    switch (product) {
      case 'nationalExpress':
        return AppColors.dbRed;
      case 'national':
        return const Color(0xFFEC6608);
      case 'regional':
        return const Color(0xFF646973);
      case 'suburban':
        return const Color(0xFF008D4F);
      case 'subway':
        return const Color(0xFF1455C0);
      case 'tram':
        return const Color(0xFFBE1414);
      case 'bus':
        return const Color(0xFFA9469B);
      case 'ferry':
        return const Color(0xFF0087B8);
      default:
        return Colors.blueGrey;
    }
  }
}

/// The pin drawn for a POI on the map.
class _PoiMarker extends StatelessWidget {
  final MapPoi poi;
  final bool selected;

  /// Phone-sized rendering (smaller glyphs/labels).
  final bool compact;

  /// The boarding Gleis for the journey the user came from — emphasised.
  final bool boarding;

  const _PoiMarker(
      {required this.poi,
      this.compact = false,
      this.selected = false,
      this.boarding = false});

  Border get _border => Border.all(
        color: boarding
            ? Colors.amber
            : (selected ? Colors.amberAccent : Colors.white),
        width: boarding ? 3 : (selected ? 2.5 : 1.5),
      );

  List<BoxShadow>? get _glow => boarding
      ? [const BoxShadow(color: Colors.amber, blurRadius: 12, spreadRadius: 2)]
      : null;

  @override
  Widget build(BuildContext context) {
    final meta = _CategoryMeta.of(poi.type);

    // Gleise get a labelled pill so the track number is readable at a glance.
    if (poi.isPlatform) {
      return Container(
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: AppColors.dbRed,
          borderRadius: BorderRadius.circular(8),
          border: _border,
          boxShadow: _glow,
        ),
        child: Text(
          poi.name,
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: compact ? 11 : 13,
          ),
        ),
      );
    }

    // Sector cubes are small, label-only chips. Boarding-range sectors are
    // filled amber to read as the highlighted band along the platform.
    if (poi.isPlatformSector) {
      return Container(
        width: compact ? 18 : 22,
        height: compact ? 18 : 22,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: boarding ? Colors.amber.shade700 : Colors.black54,
          shape: BoxShape.circle,
          border: _border,
          boxShadow: _glow,
        ),
        child: Text(
          poi.name,
          style: TextStyle(
              color: Colors.white,
              fontSize: compact ? 9 : 11,
              fontWeight: FontWeight.bold),
        ),
      );
    }

    // Official bahnhof.de style: a blue rounded square with a white glyph.
    return Container(
      decoration: BoxDecoration(
        color: AppColors.dbBlue,
        borderRadius: BorderRadius.circular(7),
        border: _border,
      ),
      padding: EdgeInsets.all(compact ? 4 : 5),
      child: Icon(meta.icon, color: Colors.white, size: compact ? 13 : 16),
    );
  }
}

/// Vertical floor selector. Each floor shows what's on it (a train icon +
/// track range if it has Gleise, otherwise its dominant category icon), so it's
/// obvious which floor has the real trains — there's no single "main" floor
/// (e.g. Berlin Hbf has long-distance Gleise on both +2 and -2).
class _LevelSwitcher extends StatelessWidget {
  final StationMap map;
  final String? selected;
  final ValueChanged<String> onSelect;

  const _LevelSwitcher({
    required this.map,
    required this.selected,
    required this.onSelect,
  });

  /// Per-floor summary: representative icon + tooltip describing contents.
  ({IconData icon, String tooltip}) _summary(String level) {
    final pois = map.poisOnLevel(level);
    final tracks = pois
        .where((p) => p.isPlatform)
        .map((p) => int.tryParse(p.name))
        .whereType<int>()
        .toList()
      ..sort();
    if (tracks.isNotEmpty) {
      final range = tracks.first == tracks.last
          ? 'Gleis ${tracks.first}'
          : 'Gleise ${tracks.first}–${tracks.last}';
      return (icon: Icons.train, tooltip: range);
    }
    // No Gleise: pick the most common other category for a hint.
    if (pois.isEmpty) return (icon: Icons.layers_clear, tooltip: 'leer');
    final counts = <String, int>{};
    for (final p in pois) {
      counts[p.type] = (counts[p.type] ?? 0) + 1;
    }
    final top = counts.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
    final meta = _CategoryMeta.of(top);
    return (icon: meta.icon, tooltip: meta.label);
  }

  @override
  Widget build(BuildContext context) {
    if (map.levels.length <= 1) return const SizedBox.shrink();
    return Card(
      elevation: 3,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final lvl in map.levels)
              _LevelButton(
                label: _levelLabel(lvl),
                summary: _summary(lvl),
                active: lvl == selected,
                onTap: () => onSelect(lvl),
              ),
          ],
        ),
      ),
    );
  }
}

class _LevelButton extends StatelessWidget {
  final String label;
  final ({IconData icon, String tooltip}) summary;
  final bool active;
  final VoidCallback onTap;

  const _LevelButton({
    required this.label,
    required this.summary,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = active ? Colors.white : Theme.of(context).iconTheme.color;
    return Tooltip(
      message: '${_levelLong(label)} · ${summary.tooltip}',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(7),
        child: Container(
          width: 34,
          padding: const EdgeInsets.symmetric(vertical: 4),
          alignment: Alignment.center,
          margin: const EdgeInsets.symmetric(vertical: 1),
          decoration: BoxDecoration(
            color: active ? AppColors.dbRed : Colors.transparent,
            borderRadius: BorderRadius.circular(7),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(summary.icon, size: 13, color: color),
              const SizedBox(height: 1),
              Text(
                label,
                style: TextStyle(
                  color: color,
                  fontWeight: active ? FontWeight.bold : FontWeight.normal,
                  fontSize: 10,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Human floor name for tooltips, e.g. "-2" -> "Ebene -2", "EG" -> "Erdgeschoss".
String _levelLong(String shortLabel) {
  if (shortLabel == 'EG') return 'Erdgeschoss';
  return 'Ebene $shortLabel';
}

/// Tappable category legend / filter. Collapsed to a small pill by default so
/// it doesn't cover the map on a phone; tap to expand the full list.
class _Legend extends StatefulWidget {
  final Set<String> categories;
  final Set<String> hidden;
  final ValueChanged<String> onToggle;

  const _Legend({
    required this.categories,
    required this.hidden,
    required this.onToggle,
  });

  @override
  State<_Legend> createState() => _LegendState();
}

class _LegendState extends State<_Legend> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final sorted = widget.categories.toList()
      ..sort((a, b) =>
          _CategoryMeta.of(a).label.compareTo(_CategoryMeta.of(b).label));
    if (sorted.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);

    if (!_expanded) {
      // Collapsed: a compact "Legende" pill.
      return Material(
        elevation: 3,
        color: theme.cardColor,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: () => setState(() => _expanded = true),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.layers, size: 15, color: theme.iconTheme.color),
                const SizedBox(width: 5),
                const Text('Legende',
                    style:
                        TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
              ],
            ),
          ),
        ),
      );
    }

    return Card(
      elevation: 3,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 220, maxWidth: 168),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header doubles as the collapse control.
            InkWell(
              onTap: () => setState(() => _expanded = false),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 6, 6, 2),
                child: Row(
                  children: [
                    const Text('Legende',
                        style: TextStyle(
                            fontSize: 11, fontWeight: FontWeight.bold)),
                    const Spacer(),
                    Icon(Icons.close,
                        size: 15, color: theme.colorScheme.onSurfaceVariant),
                  ],
                ),
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final cat in sorted)
                      _LegendRow(
                        meta: _CategoryMeta.of(cat),
                        color: _poiColor(cat),
                        active: !widget.hidden.contains(cat),
                        onTap: () => widget.onToggle(cat),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LegendRow extends StatelessWidget {
  final _CategoryMeta meta;
  final Color color;
  final bool active;
  final VoidCallback onTap;

  const _LegendRow({
    required this.meta,
    required this.color,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Opacity(
        opacity: active ? 1 : 0.35,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Match the on-map marker: small coloured square + white glyph.
              Container(
                width: 17,
                height: 17,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Icon(meta.icon, color: Colors.white, size: 11),
              ),
              const SizedBox(width: 7),
              Flexible(
                child: Text(meta.label,
                    style: const TextStyle(fontSize: 11),
                    overflow: TextOverflow.ellipsis),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Small pill showing how far the user still is from the target, drawn over
/// the map when "Mein Standort" is active.
class _DistanceChip extends StatelessWidget {
  final double metres;
  const _DistanceChip({required this.metres});

  String get _label {
    if (metres >= 1000) {
      return '≈ ${(metres / 1000).toStringAsFixed(1).replaceAll('.', ',')} km';
    }
    return '≈ ${metres.round()} m';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: AppColors.dbBlue,
        borderRadius: BorderRadius.circular(20),
        boxShadow: const [
          BoxShadow(color: Colors.black26, blurRadius: 6, spreadRadius: 1),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.directions_walk, color: Colors.white, size: 16),
          const SizedBox(width: 6),
          Text(
            '$_label bis zum Ziel',
            style: const TextStyle(
                color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13),
          ),
        ],
      ),
    );
  }
}

class _Message extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;

  const _Message({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: Colors.grey),
            const SizedBox(height: 16),
            Text(title, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(subtitle, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}

/// German floor label, e.g. GROUND_FLOOR -> "EG", BASEMENT_FLOOR_1 -> "-1".
String _levelLabel(String level) {
  if (level == 'GROUND_FLOOR') return 'EG';
  final upper = RegExp(r'UPPER_FLOOR_(\d+)').firstMatch(level);
  if (upper != null) return '${upper.group(1)}.';
  final base = RegExp(r'BASEMENT_FLOOR_(\d+)').firstMatch(level);
  if (base != null) return '-${base.group(1)}';
  return level;
}

/// Icon, colour and German label per bahnhof.de POI category.
class _CategoryMeta {
  final IconData icon;
  final Color color;
  final String label;
  const _CategoryMeta(this.icon, this.color, this.label);

  static _CategoryMeta of(String type) =>
      _byType[type] ??
      _CategoryMeta(Icons.place, Colors.blueGrey, _humanize(type));

  static String _humanize(String type) => type
      .toLowerCase()
      .split('_')
      .map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}')
      .join(' ');

  static const _byType = {
    'PLATFORM': _CategoryMeta(Icons.train, AppColors.dbRed, 'Gleis'),
    'PLATFORM_SECTOR_CUBE':
        _CategoryMeta(Icons.crop_square, Colors.black54, 'Abschnitt'),
    'ELEVATOR': _CategoryMeta(Icons.elevator, Color(0xFF2980B9), 'Aufzug'),
    'ESCALATOR':
        _CategoryMeta(Icons.escalator, Color(0xFF2980B9), 'Rolltreppe'),
    'STAIR': _CategoryMeta(Icons.stairs, Color(0xFF7F8C8D), 'Treppe'),
    'RAMP': _CategoryMeta(Icons.accessible_forward, Color(0xFF16A085), 'Rampe'),
    'TOILET': _CategoryMeta(Icons.wc, Color(0xFF8E44AD), 'WC'),
    'TOILET_HANDICAPPED':
        _CategoryMeta(Icons.accessible, Color(0xFF8E44AD), 'Barrierefreies WC'),
    'ENTRANCE_EXIT':
        _CategoryMeta(Icons.door_front_door, Color(0xFF27AE60), 'Ein-/Ausgang'),
    'LOCKER': _CategoryMeta(Icons.lock, Color(0xFFF39C12), 'Schließfach'),
    'BUS': _CategoryMeta(Icons.directions_bus, Color(0xFFD35400), 'Bus'),
    'SUBWAY': _CategoryMeta(Icons.subway, Color(0xFF2C3E50), 'U-Bahn'),
    'CITY_TRAIN': _CategoryMeta(Icons.tram, Color(0xFF27AE60), 'S-Bahn'),
    'PARKING_AREA':
        _CategoryMeta(Icons.local_parking, Color(0xFF34495E), 'Parkplatz'),
    'PARKING_DECK':
        _CategoryMeta(Icons.local_parking, Color(0xFF34495E), 'Parkhaus'),
    'BIKE_PARKING_AREA':
        _CategoryMeta(Icons.pedal_bike, Color(0xFF16A085), 'Fahrradparken'),
    'RAIL_REPLACEMENT_TRANSPORT':
        _CategoryMeta(Icons.directions_bus, Color(0xFFE67E22), 'SEV'),
  };
}

/// Banner shown when the map was opened from a journey: tells the user which
/// Gleis to board at (highlighted on the map below).
class _BoardingBanner extends StatelessWidget {
  final String gleis;
  final ({String start, String end})? section;
  const _BoardingBanner({required this.gleis, this.section});

  @override
  Widget build(BuildContext context) {
    final sec = section;
    final sectionText = sec == null
        ? ''
        : sec.start == sec.end
            ? ', Abschnitt ${sec.start}'
            : ', Abschnitt ${sec.start}–${sec.end}';
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.dbRed.withAlpha(30),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.dbRed, width: 1),
      ),
      child: Row(
        children: [
          const Icon(Icons.directions_walk, color: AppColors.dbRed, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  const TextSpan(text: 'Dein Einstieg: '),
                  TextSpan(
                    text: 'Gleis $gleis$sectionText',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const TextSpan(text: ' (auf der Karte markiert)'),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
