import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../core/tile_cache.dart';
import '../../models/station.dart';
import '../../models/station_map.dart';
import '../../providers/service_providers.dart';
import '../../providers/station_map_provider.dart';
import '../../services/location_service.dart';
import '../../theme/app_colors.dart';
import '../../widgets/bay_departures_sheet.dart';
import '../../widgets/app_menu_button.dart';
import '../../widgets/station_search_field.dart';

/// Highlight colour for a journey role: Einstieg green, Ausstieg red, Umstieg
/// amber. Null = not a highlight. One source for markers + section bands.
Color? roleColor(GleisRole role) => switch (role) {
      GleisRole.board => const Color(0xFF2E9E5B),
      GleisRole.alight => Colors.red,
      GleisRole.transfer => Colors.amber.shade700,
      GleisRole.none => null,
    };

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

/// Live indoor station map ("Bahnhofskarte"), scraped from bahnhof.de.
///
/// Pick a station, get its Gleise, lifts, stairs, exits etc. plotted on an
/// OpenStreetMap layer with a floor switcher — an open alternative to the
/// official DB app's station map.
class StationMapScreen extends ConsumerStatefulWidget {
  /// Opened for one specific station from a journey/stop (pushed full-screen):
  /// hide the station search field and the app overflow menu — the screen is
  /// just this station's map, not a place to browse other stations or settings.
  final bool dedicated;

  const StationMapScreen({super.key, this.dedicated = false});

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
    // Transfer: frame both the Ausstieg and Einstieg Gleise together.
    final sec = s.secondaryHighlightPoi;
    if (hl != null && sec != null) {
      _mapController.fitCamera(
        CameraFit.bounds(
          bounds: LatLngBounds.fromPoints([hl.latLng, sec.latLng]),
          padding: const EdgeInsets.all(72),
          maxZoom: 18.5,
        ),
      );
      return;
    }
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
          // Browse mode (Karte tab) keeps the app overflow menu; the dedicated
          // per-journey map drops it — no settings/split-ticket/debug here.
          if (!widget.dedicated) const AppMenuButton(),
          if (map != null)
            IconButton(
              tooltip: 'Auf Karte zentrieren',
              // A framing/centre glyph — distinct from the "Mein Standort" GPS
              // crosshair so the two buttons no longer look identical.
              icon: const Icon(Icons.center_focus_strong),
              onPressed: () => _recenter(map),
            ),
        ],
      ),
      body: Column(
        children: [
          // Station search only in browse mode. The dedicated map already knows
          // its station (shown in the AppBar title) — a search box there is
          // misleading, it isn't for picking a different station.
          if (!widget.dedicated)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: StationSearchField(
                hint: 'Bahnhof suchen...',
                prefixIcon: Icons.location_city,
                initialStation: state.station,
                onSelected: (s) => notifier.loadForStation(s),
              ),
            ),
          // Transfer: one legend with colour-matched Ausstieg/Einstieg chips
          // (red/green = exactly the map colours). Otherwise the single
          // boarding banner.
          if (state.secondaryGleis != null && map != null)
            _transferLegend(context, state)
          else if (state.highlightGleis != null && map != null)
            _BoardingBanner(
              gleis: state.highlightGleis!,
              section: state.highlightSection,
              role: state.highlightRole,
              note: state.transferNote,
            ),
          Expanded(child: _buildBody(context, state, notifier)),
        ],
      ),
    );
  }

  /// "Gleis 7 G-I" / "Gleis 14" label for a banner chip.
  String _gleisLabel(String? g, ({String start, String end})? s) {
    if (g == null) return '';
    return s == null ? 'Gleis $g' : 'Gleis $g ${s.start}-${s.end}';
  }

  /// Colour-matched transfer legend: red Ausstieg → green Einstieg, so the
  /// banner and the map markers read as the same thing.
  Widget _transferLegend(BuildContext context, StationMapState state) {
    Widget chip(IconData icon, String role, String gleis, Color color) {
      return Expanded(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18, color: Colors.white),
              const SizedBox(width: 6),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(role,
                        style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 11,
                            fontWeight: FontWeight.w600)),
                    Text(gleis,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.bold)),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
      child: Row(
        children: [
          chip(Icons.logout, 'Ausstieg',
              _gleisLabel(state.secondaryGleis, state.secondarySection),
              roleColor(GleisRole.alight)!),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 6),
            child: Icon(Icons.arrow_forward, size: 18),
          ),
          chip(Icons.login, 'Einstieg',
              _gleisLabel(state.highlightGleis, state.highlightSection),
              roleColor(GleisRole.board)!),
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
      // No indoor station plan (typical for bus stops, tram halts and stations
      // bahnhof.de hides). If we at least know where the stop IS, don't dead-end
      // on an error — drop to a plain OSM map with a pin on its coordinates.
      final st = state.station;
      if (st != null && st.hasLocation) {
        return _FallbackLocationMap(
          station: st,
          note: state.highlightGleis != null
              ? 'Gleis ${state.highlightGleis}'
              : null,
        );
      }
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
              tileProvider: TileCache.provider(),
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
                tileProvider: TileCache.provider(
                  headers: {'Referer': 'https://www.bahnhof.de/'},
                ),
                userAgentPackageName: 'de.chuk.besserebahn',
                // Indoor tiles only cover the station; missing tiles
                // elsewhere should just be transparent, not error pins.
                errorTileCallback: (_, __, ___) {},
              ),
            // Section bands: a coloured line + labelled markers along the
            // platform for the highlighted range (e.g. G–I). Primary =
            // Einstieg (green); on a transfer, secondary = Ausstieg (red).
            if (state.highlightSectionLine.length >= 2)
              PolylineLayer(
                polylines: [
                  Polyline(
                    points:
                        state.highlightSectionLine.map((e) => e.pos).toList(),
                    color: roleColor(state.highlightRole) ?? Colors.amber.shade700,
                    strokeWidth: 7,
                    borderColor: Colors.white,
                    borderStrokeWidth: 2,
                  ),
                ],
              ),
            if (state.secondarySectionLine.length >= 2)
              PolylineLayer(
                polylines: [
                  Polyline(
                    points:
                        state.secondarySectionLine.map((e) => e.pos).toList(),
                    color: roleColor(state.secondaryRole) ?? Colors.red,
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
              MarkerLayer(
                  markers: _sectionMarkers(state.highlightSectionLine,
                      roleColor(state.highlightRole) ?? Colors.amber.shade700)),
            if (state.secondarySectionLine.isNotEmpty)
              MarkerLayer(
                  markers: _sectionMarkers(state.secondarySectionLine,
                      roleColor(state.secondaryRole) ?? Colors.red)),
            // "Ausstieg"/"Einstieg" labels floating above the two Gleise so
            // the map itself says which is which.
            if (state.secondaryGleis != null)
              MarkerLayer(markers: _roleTagMarkers(state)),
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
          // Centre vertically and let the switcher size to its floor count —
          // no full-height stretch.
          child: Align(
            alignment: Alignment.centerLeft,
            child: _LevelSwitcher(
              map: map,
              selected: state.selectedLevel,
              onSelect: notifier.selectLevel,
            ),
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
                : const Icon(Icons.my_location),
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
    final mapState = ref.read(stationMapProvider);
    // Transfer mode (two Gleise highlighted) → grey out the OTHER red platform
    // pills so the red Ausstieg highlight actually stands out.
    final transferMode = mapState.secondaryGleis != null;
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
              if (station != null && kDepartureCategories.contains(poi.type)) {
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
              highlightRole: mapState.roleForPoi(poi),
              dimmed: transferMode &&
                  poi.isPlatform &&
                  mapState.roleForPoi(poi) == GleisRole.none,
            ),
          ),
        ),
    ];
  }

  /// Amber labelled chips for the interpolated boarding-section letters,
  /// drawn on top of the section line so the rider sees exactly where to wait.
  List<Marker> _sectionMarkers(
      List<({String letter, LatLng pos})> section, Color color) {
    return [
      for (final s in section)
        Marker(
          point: s.pos,
          width: 26,
          height: 26,
          child: Container(
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 2),
              boxShadow: [
                BoxShadow(color: color, blurRadius: 8, spreadRadius: 1),
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

  /// Floating "Ausstieg" (red) / "Einstieg" (green) labels above the two
  /// highlighted Gleise, so the map is self-explanatory.
  List<Marker> _roleTagMarkers(StationMapState s) {
    final out = <Marker>[];
    void add(MapPoi? poi, GleisRole role, String text) {
      final c = roleColor(role);
      if (poi == null || c == null) return;
      out.add(Marker(
        point: poi.latLng,
        width: 100,
        height: 64,
        alignment: Alignment.bottomCenter,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 20),
          child: Align(
            alignment: Alignment.bottomCenter,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: c,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: Colors.white, width: 1.5),
                boxShadow: [
                  BoxShadow(color: c.withAlpha(120), blurRadius: 6),
                ],
              ),
              child: Text(text,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.bold)),
            ),
          ),
        ),
      ));
    }

    add(s.secondaryHighlightPoi, s.secondaryRole, 'Ausstieg');
    add(s.highlightPoi, s.highlightRole, 'Einstieg');
    return out;
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
      builder: (_) => BayDeparturesSheet(stationEva: station.id, poi: poi),
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

/// The pin drawn for a POI on the map.
class _PoiMarker extends StatelessWidget {
  final MapPoi poi;
  final bool selected;

  /// Phone-sized rendering (smaller glyphs/labels).
  final bool compact;

  /// How this Gleis is highlighted for the journey: Einstieg (green), Ausstieg
  /// (red), Umstieg (amber), or none.
  final GleisRole highlightRole;

  /// A non-highlighted platform during a transfer — drawn neutral grey so the
  /// red Ausstieg / green Einstieg pills pop.
  final bool dimmed;

  const _PoiMarker(
      {required this.poi,
      this.compact = false,
      this.selected = false,
      this.highlightRole = GleisRole.none,
      this.dimmed = false});

  /// Highlight colour per role — null when this POI isn't highlighted.
  Color? get _hlColor => roleColor(highlightRole);

  bool get _hl => _hlColor != null;

  Border get _border => Border.all(
        color: _hlColor ?? (selected ? Colors.amberAccent : Colors.white),
        width: _hl ? 3 : (selected ? 2.5 : 1.5),
      );

  List<BoxShadow>? get _glow => _hl
      ? [BoxShadow(color: _hlColor!, blurRadius: 12, spreadRadius: 2)]
      : null;

  @override
  Widget build(BuildContext context) {
    final meta = _CategoryMeta.of(poi.type);

    // Gleise get a labelled pill so the track number is readable at a glance.
    if (poi.isPlatform) {
      return Container(
        alignment: Alignment.center,
        decoration: BoxDecoration(
          // Highlighted Gleise fill fully with their role colour (green
          // Einstieg / red Ausstieg); others grey out in transfer mode.
          color: _hl
              ? _hlColor!
              : (dimmed ? Colors.blueGrey.shade300 : AppColors.dbRed),
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
          color: _hl ? _hlColor! : Colors.black54,
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
    // A compact vertical strip sized to the floor count — rounded ends, hugging
    // its content so it never stretches down the whole map edge.
    return Material(
      elevation: 3,
      color: Theme.of(context).colorScheme.surface,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(3),
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
  final GleisRole role;
  final String? note;
  const _BoardingBanner({
    required this.gleis,
    this.section,
    this.role = GleisRole.board,
    this.note,
  });

  @override
  Widget build(BuildContext context) {
    final sec = section;
    final sectionText = sec == null
        ? ''
        : sec.start == sec.end
            ? ', Abschnitt ${sec.start}'
            : ', Abschnitt ${sec.start}–${sec.end}';

    // Wording, icon and colour follow what the Gleis is FOR — so the arrival
    // station reads "Ausstieg", not "Einstieg". The colour MUST match the
    // map marker (via roleColor): Einstieg green, Ausstieg red, Umstieg amber.
    // Previously the banner had these swapped (board red / alight green) so the
    // banner contradicted the highlighted track below it.
    final (String lead, IconData icon) = switch (role) {
      GleisRole.alight => ('Dein Ausstieg: ', Icons.logout),
      GleisRole.transfer => ('Umstieg: ', Icons.swap_calls),
      GleisRole.board => ('Dein Einstieg: ', Icons.login),
      GleisRole.none => ('', Icons.place),
    };
    final color = roleColor(role) ?? AppColors.dbRed;

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withAlpha(30),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color, width: 1),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  if (lead.isNotEmpty) TextSpan(text: lead),
                  TextSpan(
                    text: 'Gleis $gleis$sectionText',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const TextSpan(text: ' (auf der Karte markiert)'),
                  if (note != null && note!.isNotEmpty)
                    TextSpan(
                      text: '\n$note',
                      style: const TextStyle(fontSize: 12),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Fallback for stations with no indoor plan (bus stops, tram halts, hidden
/// stations): a plain OpenStreetMap with a single pin on the stop's
/// coordinates, plus the same "Mein Standort" framing as the full map — so the
/// rider can still see where the stop is and walk to it.
class _FallbackLocationMap extends ConsumerStatefulWidget {
  final Station station;

  /// Optional hint shown in the info banner (e.g. the boarding Gleis).
  final String? note;

  const _FallbackLocationMap({required this.station, this.note});

  @override
  ConsumerState<_FallbackLocationMap> createState() =>
      _FallbackLocationMapState();
}

class _FallbackLocationMapState extends ConsumerState<_FallbackLocationMap> {
  final _mapController = MapController();
  UserFix? _userFix;
  bool _locating = false;

  LatLng get _target =>
      LatLng(widget.station.latitude!, widget.station.longitude!);

  @override
  void dispose() {
    _mapController.dispose();
    super.dispose();
  }

  Future<void> _locateMe() async {
    setState(() => _locating = true);
    try {
      final fix = await ref.read(locationServiceProvider).currentFix();
      if (!mounted) return;
      setState(() => _userFix = fix);
      _mapController.fitCamera(
        CameraFit.bounds(
          bounds: LatLngBounds.fromPoints([fix.latLng, _target]),
          padding: const EdgeInsets.all(72),
          maxZoom: 17.5,
        ),
      );
    } on LocationException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Standort konnte nicht ermittelt werden.')));
      }
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  double get _distanceToTarget =>
      const Distance().as(LengthUnit.Meter, _userFix!.latLng, _target);

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        FlutterMap(
          mapController: _mapController,
          options: MapOptions(
            initialCenter: _target,
            initialZoom: 16.5,
            minZoom: 10,
            maxZoom: 19,
          ),
          children: [
            TileLayer(
              urlTemplate:
                  'https://{s}.basemaps.cartocdn.com/light_all/{z}/{x}/{y}{r}.png',
              subdomains: const ['a', 'b', 'c', 'd'],
              retinaMode: RetinaMode.isHighDensity(context),
              userAgentPackageName: 'de.chuk.besserebahn',
              tileProvider: TileCache.provider(),
              maxZoom: 20,
            ),
            if (_userFix != null) ...[
              PolylineLayer(
                polylines: [
                  Polyline(
                    points: [_userFix!.latLng, _target],
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
            ],
            MarkerLayer(
              markers: [
                // The stop itself — a labelled DB-red location pin.
                Marker(
                  point: _target,
                  width: 160,
                  height: 64,
                  alignment: Alignment.topCenter,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.location_on,
                          color: AppColors.dbRed, size: 40),
                      Flexible(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(6),
                            boxShadow: const [
                              BoxShadow(color: Colors.black26, blurRadius: 4),
                            ],
                          ),
                          child: Text(
                            widget.station.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 11, fontWeight: FontWeight.bold),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (_userFix != null)
                  Marker(
                    point: _userFix!.latLng,
                    width: 22,
                    height: 22,
                    child: Container(
                      decoration: BoxDecoration(
                        color: AppColors.dbBlue,
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 3),
                        boxShadow: const [
                          BoxShadow(
                              color: Colors.black26,
                              blurRadius: 4,
                              spreadRadius: 1),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
            const RichAttributionWidget(
              alignment: AttributionAlignment.bottomLeft,
              showFlutterMapAttribution: false,
              attributions: [
                TextSourceAttribution('© OpenStreetMap'),
                TextSourceAttribution('© CARTO'),
              ],
            ),
          ],
        ),
        // Tell the rider this is a location fallback, not the full plan.
        Positioned(
          left: 12,
          right: 12,
          top: 12,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: AppColors.dbBlue.withAlpha(235),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                const Icon(Icons.place, color: Colors.white, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.note != null
                        ? 'Kein Bahnhofsplan · Lage der Haltestelle (${widget.note})'
                        : 'Kein Bahnhofsplan · Lage der Haltestelle',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
        ),
        Positioned(
          right: 8,
          top: 60,
          child: FloatingActionButton.small(
            heroTag: 'locate-me-fallback',
            tooltip: 'Mein Standort',
            onPressed: _locating ? null : _locateMe,
            child: _locating
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.my_location),
          ),
        ),
        if (_userFix != null)
          Positioned(
            left: 0,
            right: 0,
            bottom: 16,
            child: Center(child: _DistanceChip(metres: _distanceToTarget)),
          ),
      ],
    );
  }
}
