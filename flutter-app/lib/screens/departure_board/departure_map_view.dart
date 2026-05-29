import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/tile_cache.dart';
import '../../models/departure.dart';
import '../../models/station.dart';
import '../../models/station_map.dart';
import '../../providers/departure_board_provider.dart';
import '../../providers/service_providers.dart';
import '../../widgets/bay_departures_sheet.dart';

/// Live station map for one station name, fetched once and cached. Keyed by the
/// station's display name (what bahnhof.de's scraper resolves a slug from).
final _departureMapProvider =
    FutureProvider.autoDispose.family<StationMap, String>((ref, name) {
  // Keep the scrape alive briefly so toggling list↔map doesn't refetch.
  ref.keepAlive();
  return ref.read(stationMapServiceProvider).fetchByStationName(name);
});

/// Map counterpart of the departure board: the station's Gleise / transit bays
/// plotted on the real DB floor plan, each badged with the next train/bus that
/// leaves from it. Tap a bay to open its full departure list. The reverse of
/// the "tap a platform on the Karte → see departures" flow.
class DepartureMapView extends ConsumerStatefulWidget {
  const DepartureMapView({super.key});

  @override
  ConsumerState<DepartureMapView> createState() => _DepartureMapViewState();
}

class _DepartureMapViewState extends ConsumerState<DepartureMapView> {
  final _mapController = MapController();

  /// Floor the user picked; null = use the auto-chosen best floor.
  String? _level;

  @override
  void dispose() {
    _mapController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final board = ref.watch(departureBoardProvider);
    final station = board.station;
    if (station == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text('Bahnhof eingeben, um die Karte zu sehen.',
              textAlign: TextAlign.center),
        ),
      );
    }

    final mapAsync = ref.watch(_departureMapProvider(station.name));
    return mapAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text('Karte nicht verfügbar.\n$e',
              textAlign: TextAlign.center),
        ),
      ),
      data: (map) =>
          _buildMap(context, map, station, board.filteredDepartures),
    );
  }

  Widget _buildMap(BuildContext context, StationMap map, Station station,
      List<Departure> departures) {
    final level = _level ?? _bestLevel(map, departures);
    final pois = map
        .poisOnLevel(level)
        .where((p) => kDepartureCategories.contains(p.type))
        .toList();

    return Stack(
      children: [
        FlutterMap(
          mapController: _mapController,
          options: MapOptions(
            initialCenter: map.center,
            initialZoom: 17.5,
            minZoom: 13,
            maxZoom: 19,
          ),
          children: [
            TileCache.outdoorLayer(context),
            if (level.isNotEmpty)
              TileLayer(
                urlTemplate: StationMap.indoorTileUrl(level),
                tileSize: 256,
                minNativeZoom: 14,
                maxNativeZoom: 18,
                maxZoom: 20,
                tileProvider: TileCache.provider(
                  headers: {'Referer': 'https://www.bahnhof.de/'},
                ),
                userAgentPackageName: 'de.chuk.besserebahn',
                errorTileCallback: (_, __, ___) {},
              ),
            MarkerLayer(markers: _markers(context, pois, station, departures)),
            const RichAttributionWidget(
              alignment: AttributionAlignment.bottomLeft,
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
            levels: _levelsWithBays(map),
            selected: level,
            onSelect: (l) => setState(() => _level = l),
          ),
        ),
        Positioned(
          right: 8,
          top: 8,
          child: FloatingActionButton.small(
            heroTag: 'dep-map-center',
            tooltip: 'Zentrieren',
            onPressed: () => _mapController.move(map.center, 17.5),
            child: const Icon(Icons.my_location),
          ),
        ),
        const Positioned(
          left: 0,
          right: 0,
          bottom: 10,
          child: Center(child: _Hint()),
        ),
      ],
    );
  }

  List<Marker> _markers(BuildContext context, List<MapPoi> pois,
      Station station, List<Departure> departures) {
    final compact = MediaQuery.of(context).size.shortestSide < 600;
    return [
      for (final poi in pois)
        () {
          final matched = departuresForPoi(poi, departures);
          // Next departure decides the colour; greyed out when nothing leaves
          // here in the current board window.
          final next = matched.isNotEmpty ? matched.first : null;
          final color = next != null
              ? bayProductColor(next.line.product)
              : Colors.blueGrey.shade300;
          final label = poi.isPlatform
              ? poi.name
              : (poi.name.isNotEmpty ? poi.name : bayModeLabel(poi.type));
          return Marker(
            point: poi.latLng,
            width: compact ? 46 : 54,
            height: compact ? 30 : 34,
            child: GestureDetector(
              onTap: () => _openBay(poi, station),
              child: _BayMarker(
                label: label,
                count: matched.length,
                color: color,
                compact: compact,
              ),
            ),
          );
        }(),
    ];
  }

  void _openBay(MapPoi poi, Station station) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => BayDeparturesSheet(stationEva: station.id, poi: poi),
    );
  }

  /// Floors that actually carry Gleise / transit bays, top-to-bottom as
  /// delivered by bahnhof.de.
  List<String> _levelsWithBays(StationMap map) => map.levels
      .where((l) => map
          .poisOnLevel(l)
          .any((p) => kDepartureCategories.contains(p.type)))
      .toList();

  /// Best floor to open on: the one whose bays carry the most matched
  /// departures; falls back to the floor with the most bays, then bahnhof.de's
  /// own initial floor.
  String _bestLevel(StationMap map, List<Departure> departures) {
    String? best;
    var bestScore = -1;
    for (final lvl in map.levels) {
      final bays = map
          .poisOnLevel(lvl)
          .where((p) => kDepartureCategories.contains(p.type))
          .toList();
      if (bays.isEmpty) continue;
      var score = 0;
      for (final p in bays) {
        score += departuresForPoi(p, departures).length;
      }
      // Tie-break on bay count so an empty board still lands on the tracks.
      final composite = score * 1000 + bays.length;
      if (composite > bestScore) {
        bestScore = composite;
        best = lvl;
      }
    }
    if (best != null) return best;
    return map.levelInit.isNotEmpty
        ? map.levelInit
        : (map.levels.isNotEmpty ? map.levels.first : '');
  }
}

/// Hint chip floating over the map.
class _Hint extends StatelessWidget {
  const _Hint();

  @override
  Widget build(BuildContext context) {
    return Card(
      color: Theme.of(context).colorScheme.surface.withAlpha(235),
      elevation: 2,
      shape: const StadiumBorder(),
      child: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        child: Text('Tippe ein Gleis für seine Abfahrten',
            style: TextStyle(fontSize: 12)),
      ),
    );
  }
}

/// A Gleis / bay pin: coloured by the next departure's product, with the track
/// label and a count of upcoming departures.
class _BayMarker extends StatelessWidget {
  final String label;
  final int count;
  final Color color;
  final bool compact;

  const _BayMarker({
    required this.label,
    required this.count,
    required this.color,
    required this.compact,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      alignment: Alignment.center,
      children: [
        Container(
          padding: EdgeInsets.symmetric(horizontal: compact ? 7 : 9, vertical: 3),
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(7),
            border: Border.all(color: Colors.white, width: 1.5),
            boxShadow: const [
              BoxShadow(color: Colors.black26, blurRadius: 3, spreadRadius: 0.5),
            ],
          ),
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.fade,
            softWrap: false,
            style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
              fontSize: compact ? 12 : 13,
            ),
          ),
        ),
        if (count > 0)
          Positioned(
            top: -7,
            right: -7,
            child: Container(
              constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 3),
              decoration: BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
                border: Border.all(color: color, width: 1.5),
              ),
              child: Text(
                count > 9 ? '9+' : '$count',
                style: TextStyle(
                  color: color,
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Compact vertical floor switcher (only floors that carry bays).
class _LevelSwitcher extends StatelessWidget {
  final List<String> levels;
  final String selected;
  final ValueChanged<String> onSelect;

  const _LevelSwitcher({
    required this.levels,
    required this.selected,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    if (levels.length < 2) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Card(
      elevation: 3,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final lvl in levels)
              InkWell(
                onTap: () => onSelect(lvl),
                child: Container(
                  width: 40,
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  alignment: Alignment.center,
                  color: lvl == selected
                      ? theme.colorScheme.primaryContainer
                      : null,
                  child: Text(
                    _levelLabel(lvl),
                    style: TextStyle(
                      fontWeight:
                          lvl == selected ? FontWeight.bold : FontWeight.normal,
                      fontSize: 12,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// Short tag for a bahnhof.de floor id (GROUND_FLOOR → "EG", BASEMENT_… →
  /// "U1", UPPER_… → "O1"), best-effort.
  String _levelLabel(String level) {
    final u = level.toUpperCase();
    if (u.contains('GROUND')) return 'EG';
    final basement = RegExp(r'BASEMENT_FLOOR_(\d+)').firstMatch(u);
    if (basement != null) return 'U${basement.group(1)}';
    final upper = RegExp(r'(?:UPPER|FLOOR)_(\d+)').firstMatch(u);
    if (upper != null) return 'O${upper.group(1)}';
    return level.length > 3 ? level.substring(0, 3) : level;
  }
}
