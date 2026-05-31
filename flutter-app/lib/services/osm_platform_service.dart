import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../core/app_log.dart';
import '../core/constants.dart';

/// One station's OpenStreetMap platform + rail geometry, the accurate source for
/// WHERE each track is (verified against satellite — see
/// docs/platform-train-osm.md). Fed to `osmRailForGleis` to build the real rail
/// spine a platform train rides.
class OsmPlatformGeometry {
  /// `public_transport=platform` AREA loops tagged with their Gleis pair
  /// (`ref` = "7;8"), as the polygon's vertices.
  final List<({String ref, List<LatLng> pts})> platforms;

  /// `railway=rail` ways near the platforms, each a vertex list.
  final List<List<LatLng>> rails;

  const OsmPlatformGeometry({required this.platforms, required this.rails});

  bool get isEmpty => platforms.isEmpty || rails.isEmpty;
}

/// Fetches and caches a station's OSM platform/rail geometry from Overpass.
///
/// MUST soft-fail: any error/timeout returns null so the caller falls back to
/// the existing bahnhof.de cube placement — the platform train keeps working
/// exactly as before when Overpass is down. Results are cached per station slug
/// in memory (the geometry is identical every load and tiny), so a station is
/// fetched at most once per app run.
class OsmPlatformService {
  OsmPlatformService._();
  static final OsmPlatformService instance = OsmPlatformService._();

  /// Public Overpass endpoints, tried in order — the main instance 504s under
  /// load, so we fall through to mirrors before giving up. Keyless.
  static const _endpoints = [
    'https://overpass-api.de/api/interpreter',
    'https://overpass.kumi.systems/api/interpreter',
    'https://maps.mail.ru/osm/tools/overpass/api/interpreter',
  ];

  /// Search radius around the station centre — comfortably covers a big Hbf's
  /// platform fan without dragging in a whole city's tracks.
  static const _radiusM = 600.0;

  /// Short — a slow/missing Overpass must never stall the map; we just fall back.
  static const _timeout = Duration(seconds: 12);

  final http.Client _client = http.Client();

  /// slug → resolved geometry (or null = "fetched and there was nothing/failed",
  /// cached so we don't re-hammer Overpass for a station with no data).
  final Map<String, OsmPlatformGeometry?> _cache = {};

  /// In-flight fetches, so concurrent callers for the same station share one
  /// request instead of firing duplicates.
  final Map<String, Future<OsmPlatformGeometry?>> _inflight = {};

  /// The geometry already in cache for [slug], if any. Synchronous — lets a
  /// provider read what's warm without awaiting (it kicks off [fetch] otherwise).
  OsmPlatformGeometry? cached(String slug) => _cache[slug];

  /// Whether [slug] has been fetched (success OR settled-failure) — so the
  /// caller knows not to await again.
  bool isResolved(String slug) => _cache.containsKey(slug);

  /// Fetch (or return the cached) OSM geometry around [center] for [slug].
  /// Returns null on any failure/timeout/empty result — never throws.
  Future<OsmPlatformGeometry?> fetch(String slug, LatLng center) {
    if (_cache.containsKey(slug)) return Future.value(_cache[slug]);
    final pending = _inflight[slug];
    if (pending != null) return pending;
    final f = _fetch(slug, center);
    _inflight[slug] = f;
    return f;
  }

  Future<OsmPlatformGeometry?> _fetch(String slug, LatLng center) async {
    try {
      // bbox ~radius around the centre (equirectangular metres → degrees).
      final dLat = _radiusM / 111320.0;
      final dLon =
          _radiusM / (111320.0 * math.cos(center.latitude * math.pi / 180));
      final s = center.latitude - dLat,
          w = center.longitude - dLon,
          n = center.latitude + dLat,
          e = center.longitude + dLon;
      final bbox = '$s,$w,$n,$e';
      // platform AREAS carrying a ref (the Gleis pair) + every rail way; `out
      // geom` inlines each way's node coordinates so we don't resolve nodes.
      final ql = '[out:json][timeout:25];'
          '('
          'way["public_transport"="platform"]["ref"]($bbox);'
          'way["railway"="rail"]($bbox);'
          ');'
          'out geom;';
      // Try each Overpass mirror until one answers 200; a 504/timeout on the
      // main instance falls through instead of failing the whole fetch.
      http.Response? resp;
      for (final endpoint in _endpoints) {
        try {
          final r = await _client
              .post(
                Uri.parse(endpoint),
                headers: {
                  'User-Agent': ApiConstants.userAgent,
                  'Content-Type': 'application/x-www-form-urlencoded',
                },
                body: {'data': ql},
              )
              .timeout(_timeout);
          if (r.statusCode == 200) {
            resp = r;
            break;
          }
          AppLog.log('OSM overpass "$slug" $endpoint HTTP ${r.statusCode}',
              tag: 'osm');
        } catch (e) {
          AppLog.log('OSM overpass "$slug" $endpoint error: $e', tag: 'osm');
        }
      }
      if (resp == null) return _settle(slug, null);
      final decoded = json.decode(resp.body) as Map<String, dynamic>;
      final elements = (decoded['elements'] as List?) ?? const [];
      final platforms = <({String ref, List<LatLng> pts})>[];
      final rails = <List<LatLng>>[];
      for (final el in elements) {
        if (el is! Map) continue;
        final geom = el['geometry'] as List?;
        if (geom == null || geom.isEmpty) continue;
        final pts = [
          for (final g in geom)
            if (g is Map && g['lat'] != null && g['lon'] != null)
              LatLng((g['lat'] as num).toDouble(), (g['lon'] as num).toDouble())
        ];
        if (pts.length < 2) continue;
        final tags = (el['tags'] as Map?) ?? const {};
        final ref = tags['ref'];
        if (tags['public_transport'] == 'platform' && ref is String) {
          platforms.add((ref: ref, pts: pts));
        } else if (tags['railway'] == 'rail') {
          rails.add(pts);
        }
      }
      final geometry = OsmPlatformGeometry(platforms: platforms, rails: rails);
      AppLog.log(
          'OSM overpass "$slug": ${platforms.length} platforms, '
          '${rails.length} rails',
          tag: 'osm');
      // Empty (no platforms or no rails) is treated as "nothing usable" → null,
      // so the caller falls back to cubes; but we still cache it as resolved.
      return _settle(slug, geometry.isEmpty ? null : geometry);
    } catch (e) {
      AppLog.log('OSM overpass "$slug" failed: $e', tag: 'osm');
      return _settle(slug, null);
    } finally {
      _inflight.remove(slug);
    }
  }

  OsmPlatformGeometry? _settle(String slug, OsmPlatformGeometry? g) {
    _cache[slug] = g;
    return g;
  }
}
