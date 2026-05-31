import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../core/app_log.dart';

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

  /// Overpass etiquette: identify the app. A browser/curl/empty UA is 406'd by
  /// overpass-api.de's WAF — a descriptive UA is what makes the primary work.
  static const _userAgent = 'BesserBahn/1.0 (+https://bahn.chuk.dev)';

  /// Search radius around the station centre — comfortably covers a big Hbf's
  /// platform fan without dragging in a whole city's tracks.
  static const _radiusM = 600.0;

  /// Generous — a big Hbf (Hamburg: 230+ rails) is a large response and the only
  /// reliable mirror can take >10 s; too short and it times out and falls back to
  /// the cube line. Still non-blocking, so a long wait never stalls the map.
  static const _timeout = Duration(seconds: 20);

  /// Transient failures (every mirror errored/timed out) get this many retries
  /// across views before we give up for the session — so a flaky first fetch for
  /// a big station doesn't strand it on the cube line permanently.
  static const _maxAttempts = 4;

  final http.Client _client = http.Client();

  /// slug → resolved geometry (or null = "fetched a 200 with nothing usable").
  /// ONLY a real response settles the cache; a transient all-mirrors failure is
  /// NOT cached (see [_attempts]) so the next view retries.
  final Map<String, OsmPlatformGeometry?> _cache = {};

  /// slug → count of transient (all-mirrors-failed) attempts so far.
  final Map<String, int> _attempts = {};

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
      // Platforms are mapped two ways across stations: as a single tagged WAY
      // (Hamburg: ref "7;8") or as a multipolygon RELATION whose member ways
      // hold the geometry and whose `ref` carries the Gleis pair (Kiel: "3;4",
      // while the member ways only carry section labels like "A1"/"6b"). Fetch
      // both; relation members come inlined with `out geom`.
      final ql = '[out:json][timeout:25];'
          '('
          'way["public_transport"="platform"]["ref"]($bbox);'
          'relation["public_transport"="platform"]["ref"]($bbox);'
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
                  // A DESCRIPTIVE app User-Agent is mandatory: overpass-api.de's
                  // WAF answers 406 to browser/curl/empty UAs (verified), which
                  // is exactly why the fast primary failed on-device and only the
                  // slow mirror was left. Identifying the app fixes it.
                  'User-Agent': _userAgent,
                  'Accept': '*/*',
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
      if (resp == null) return _transient(slug);
      final decoded = json.decode(resp.body) as Map<String, dynamic>;
      final elements = (decoded['elements'] as List?) ?? const [];
      final platforms = <({String ref, List<LatLng> pts})>[];
      final rails = <List<LatLng>>[];
      for (final el in elements) {
        if (el is! Map) continue;
        final tags = (el['tags'] as Map?) ?? const {};
        final ref = tags['ref'];
        if (tags['railway'] == 'rail') {
          final pts = _coords(el['geometry'] as List?);
          if (pts.length >= 2) rails.add(pts);
        } else if (tags['public_transport'] == 'platform' && ref is String) {
          // A way carries its own geometry; a relation's geometry is its member
          // ways stitched end-to-end into one ring.
          final pts = el['type'] == 'relation'
              ? _stitchRing([
                  for (final m in (el['members'] as List?) ?? const [])
                    if (m is Map && m['type'] == 'way')
                      _coords(m['geometry'] as List?)
                ])
              : _coords(el['geometry'] as List?);
          if (pts.length >= 2) platforms.add((ref: ref, pts: pts));
        }
      }
      final geometry = OsmPlatformGeometry(platforms: platforms, rails: rails);
      AppLog.log(
          'OSM overpass "$slug": ${platforms.length} platforms, '
          '${rails.length} rails',
          tag: 'osm');
      // Empty (no platforms or no rails) is treated as "nothing usable" → null,
      // so the caller falls back to cubes; but we still cache it as resolved.
      _attempts.remove(slug);
      return _settle(slug, geometry.isEmpty ? null : geometry);
    } catch (e) {
      AppLog.log('OSM overpass "$slug" failed: $e', tag: 'osm');
      return _transient(slug);
    } finally {
      _inflight.remove(slug);
    }
  }

  OsmPlatformGeometry? _settle(String slug, OsmPlatformGeometry? g) {
    _cache[slug] = g;
    return g;
  }

  /// A transient all-mirrors failure: return null but DON'T cache it, so the
  /// next view retries — up to [_maxAttempts], after which we give up (cache
  /// null) for the session so a truly unreachable station stops re-hammering.
  OsmPlatformGeometry? _transient(String slug) {
    final n = (_attempts[slug] ?? 0) + 1;
    _attempts[slug] = n;
    return n >= _maxAttempts ? _settle(slug, null) : null;
  }
}

/// Overpass `geometry` array ([{lat,lon}, …]) → LatLng list.
List<LatLng> _coords(List? geom) => [
      for (final g in geom ?? const [])
        if (g is Map && g['lat'] != null && g['lon'] != null)
          LatLng((g['lat'] as num).toDouble(), (g['lon'] as num).toDouble())
    ];

/// Stitch a multipolygon relation's member [ways] into one ordered ring by
/// chaining ways that share an endpoint (handling reversed direction). OSM
/// shares node coordinates exactly between connected ways; we compare with a
/// tiny epsilon. Returns the longest chain we can assemble from the first way.
List<LatLng> _stitchRing(List<List<LatLng>> ways) {
  final segs = [for (final w in ways) if (w.length >= 2) List<LatLng>.from(w)];
  if (segs.isEmpty) return const [];
  bool near(LatLng a, LatLng b) =>
      (a.latitude - b.latitude).abs() < 1e-7 &&
      (a.longitude - b.longitude).abs() < 1e-7;
  final chain = segs.removeAt(0);
  var changed = true;
  while (segs.isNotEmpty && changed) {
    changed = false;
    for (var i = 0; i < segs.length; i++) {
      final w = segs[i];
      if (near(w.first, chain.last)) {
        chain.addAll(w.skip(1));
      } else if (near(w.last, chain.last)) {
        chain.addAll(w.reversed.skip(1));
      } else if (near(w.last, chain.first)) {
        chain.insertAll(0, w.take(w.length - 1));
      } else if (near(w.first, chain.first)) {
        chain.insertAll(0, w.reversed.skip(1).toList().reversed);
      } else {
        continue;
      }
      segs.removeAt(i);
      changed = true;
      break;
    }
  }
  return chain;
}
