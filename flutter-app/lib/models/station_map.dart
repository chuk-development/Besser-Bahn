import 'package:latlong2/latlong.dart';

/// A single point-of-interest on a station indoor map (Gleis, lift, stairs ...).
///
/// Sourced from the GeoJSON `poi` payload embedded in the bahnhof.de
/// `/{slug}/karte` page (Next.js RSC stream).
class MapPoi {
  /// Category, e.g. PLATFORM, PLATFORM_SECTOR_CUBE, ELEVATOR, ESCALATOR,
  /// STAIR, TOILET, ENTRANCE_EXIT, BUS, SUBWAY, CITY_TRAIN ...
  final String type;

  /// Display name (e.g. Gleis "11", sector "A", or a lift label).
  final String name;

  /// Longer description if present (bahnhof.de `detail`).
  final String? detail;

  /// Operational status (e.g. ACTIVE, INACTIVE) where provided.
  final String? status;

  /// Floor this POI lives on (e.g. GROUND_FLOOR, BASEMENT_FLOOR_1).
  final String? level;

  final double latitude;
  final double longitude;

  const MapPoi({
    required this.type,
    required this.name,
    required this.latitude,
    required this.longitude,
    this.detail,
    this.status,
    this.level,
  });

  LatLng get latLng => LatLng(latitude, longitude);

  bool get isPlatform => type == 'PLATFORM';
  bool get isPlatformSector => type == 'PLATFORM_SECTOR_CUBE';

  factory MapPoi.fromFeature(String type, Map<String, dynamic> feature) {
    final geometry = feature['geometry'] as Map<String, dynamic>?;
    final coords = (geometry?['coordinates'] as List?) ?? const [];
    final props = (feature['properties'] as Map<String, dynamic>?) ?? const {};

    // GeoJSON order is [longitude, latitude].
    final lon = (coords.isNotEmpty ? coords[0] : 0) as num;
    final lat = (coords.length > 1 ? coords[1] : 0) as num;

    return MapPoi(
      type: (props['type'] as String?) ?? type,
      name: (props['name'] as String?) ?? '',
      detail: props['detail'] as String?,
      status: props['status'] as String?,
      level: props['level'] as String?,
      longitude: lon.toDouble(),
      latitude: lat.toDouble(),
    );
  }
}

/// A lift/escalator access point whose bahnhof.de description names the track
/// pair it serves (e.g. "zu Gleis 7/8 Abschnitt E"). These are the ONLY places
/// the data links a real position to specific Gleise, so we use them to learn
/// which platform island a position belongs to (the sector cubes themselves
/// carry no track reference).
class PlatformAnchor {
  /// The track numbers this access point serves, e.g. {"7", "8"}.
  final Set<String> gleise;
  final double latitude;
  final double longitude;

  const PlatformAnchor({
    required this.gleise,
    required this.latitude,
    required this.longitude,
  });

  LatLng get latLng => LatLng(latitude, longitude);
}

/// Full indoor-map dataset for one station, scraped live from bahnhof.de.
class StationMap {
  final String slug;

  /// Map centre supplied by bahnhof.de.
  final LatLng center;

  /// All floors present, top-to-bottom as delivered by bahnhof.de.
  final List<String> levels;

  /// The floor bahnhof.de shows first.
  final String levelInit;

  /// Every POI, flat. Filter by [level] / [type] in the UI.
  final List<MapPoi> pois;

  /// Lift/escalator access points that name the Gleise they serve — used to
  /// group tracks into platform islands and place section markers correctly.
  final List<PlatformAnchor> platformAnchors;

  const StationMap({
    required this.slug,
    required this.center,
    required this.levels,
    required this.levelInit,
    required this.pois,
    this.platformAnchors = const [],
  });

  /// POIs on a given floor.
  List<MapPoi> poisOnLevel(String level) =>
      pois.where((p) => p.level == level).toList();

  /// Distinct categories present on a floor (for legend / filtering).
  Set<String> categoriesOnLevel(String level) =>
      poisOnLevel(level).map((p) => p.type).toSet();

  /// All Gleise (platforms) regardless of floor.
  List<MapPoi> get platforms => pois.where((p) => p.isPlatform).toList();

  /// XYZ raster-tile URL template for the real Deutsche Bahn indoor floor plan
  /// of a given floor [level] (e.g. `GROUND_FLOOR`, `BASEMENT_FLOOR_2`).
  ///
  /// This is the exact tile service bahnhof.de's `/karte` page renders
  /// (a MapLibre GL raster source): standard slippy-map XYZ tiles where the
  /// floor is part of the path, so panning to a station's coordinates reveals
  /// its real building/track geometry. The `ALT`/`PURE` segments are the
  /// provider/variant defaults the bahnhof.de client uses; they are constant
  /// across stations — the geographic tile coordinates select the station.
  ///
  /// No API key, CORS-open (`access-control-allow-origin: *`), tiles are
  /// 512×512 retina PNGs declared at a logical `tileSize` of 256.
  static String indoorTileUrl(String level) =>
      'https://maps.reisenden.info/rimapsapi/0.7/2/map/station/ALT/'
      '$level/PURE/{z}/{x}/{y}.png';

  /// XYZ raster-tile URL template for the outdoor station-area plan, used as a
  /// backdrop around the building. Free, no key.
  static const String outdoorTileUrl =
      'https://maps.reisenden.info/rimapsapi/0.7/2/map/outdoor/{z}/{x}/{y}.png';
}
