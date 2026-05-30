import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import '../core/app_log.dart';
import '../core/constants.dart';
import '../models/station_map.dart';

/// Scrapes the live indoor-map dataset for a station from bahnhof.de.
///
/// bahnhof.de is a Next.js app that ships the map as a GeoJSON `poi` payload
/// inside the server-rendered RSC stream (`self.__next_f.push([...])`). There
/// is no clean JSON endpoint and the departure board uses encrypted server
/// actions, but the *map* page embeds everything we need on first load, so we
/// fetch the HTML once and pull the JSON straight out of the RSC chunks.
class StationMapService {
  final http.Client _client = http.Client();

  /// Parsed maps keyed by slug (session cache). Re-opening the same station —
  /// the common case when bouncing between stops of a journey — is then instant
  /// instead of re-downloading ~230 KB of HTML and re-parsing it.
  final Map<String, StationMap> _cache = {};

  Map<String, String> get _headers => {
        'User-Agent': ApiConstants.userAgent,
        'Accept': 'text/html,application/xhtml+xml',
        'Accept-Language': 'de-DE,de;q=0.9',
      };

  /// The already-cached map for a station [name], if [prefetch]/[fetchByStationName]
  /// has resolved it this session — else null. Lets a map widget read a stop's
  /// parked-train geometry from the warm cache without re-triggering a fetch on
  /// every rebuild.
  StationMap? cachedByName(String name) {
    final hit = _cache[slugify(name)];
    if (hit != null) return hit;
    final alt = _altSlug(slugify(name));
    return alt != null ? _cache[alt] : null;
  }

  /// Fetch the indoor map for a DB station name, resolving the bahnhof.de slug.
  ///
  /// bahnhof.de slugs are mostly the umlaut-expanded, hyphenated name
  /// ("Köln Hbf" -> `koeln-hbf`), but a few are irregular ("Berlin Hbf" ->
  /// `berlin-hauptbahnhof`, not `berlin-hbf`). We try the obvious slug first,
  /// then swap `hbf` <-> `hauptbahnhof` as a fallback.
  Future<StationMap> fetchByStationName(String name,
      {bool background = false}) async {
    final slug = slugify(name);
    AppLog.log('fetchByStationName "$name" → slug "$slug"', tag: 'map');
    try {
      return await fetchBySlug(slug, background: background);
    } on StationMapException catch (e) {
      // Background prefetch is best-effort: don't pay a SECOND timeout on the
      // alt slug (that's what turned one slow stop into a ~30 s hang).
      if (background) rethrow;
      final alt = _altSlug(slug);
      if (alt != null) {
        AppLog.log('slug "$slug" failed ($e) → retry alt slug "$alt"',
            tag: 'map');
        return await fetchBySlug(alt);
      }
      rethrow;
    }
  }

  /// Warm the session cache for a list of station [names] (fire-and-forget), so
  /// the to-scale parked train on every stop of a route is ready the moment the
  /// rider zooms into that stop. Each station is fetched at most once (the slug
  /// cache dedups re-opens) and failures are swallowed — a missing map just
  /// means no parked train there.
  ///
  /// We fetch a few at a time (the bahnhof.de `/karte` pages are ~230 KB each,
  /// so blasting a 30-stop ICE route at once would hammer the network and the
  /// RSC parser); the bounded window keeps a long route from stalling the
  /// device while still warming the whole trip in the background.
  Future<void> prefetch(Iterable<String> names) async {
    // De-dup by resolved slug so two labels for the same station fetch once.
    final seen = <String>{};
    final todo = <String>[];
    for (final n in names) {
      final s = n.trim();
      if (s.isEmpty) continue;
      final slug = slugify(s);
      if (seen.add(slug)) todo.add(s);
    }
    // SEQUENTIAL, one ~230 KB scrape at a time with a gentle gap — firing a
    // burst (the old window of 4) janked the UI and made bahnhof.de time out en
    // masse on a long route. Background mode uses a short timeout and skips the
    // alt-slug retry, so a dead stop costs ~7 s once, not ~30 s, and never
    // blocks the map (this whole method is fire-and-forget).
    for (final name in todo) {
      if (_cache.containsKey(slugify(name))) continue;
      try {
        await fetchByStationName(name, background: true);
      } catch (_) {/* missing map → just no parked train there */}
      await Future.delayed(const Duration(milliseconds: 150));
    }
  }

  /// hbf <-> hauptbahnhof slug variant, or null if not applicable.
  static String? _altSlug(String slug) {
    if (slug.endsWith('-hbf')) {
      return '${slug.substring(0, slug.length - 4)}-hauptbahnhof';
    }
    if (slug.endsWith('-hauptbahnhof')) {
      return '${slug.substring(0, slug.length - 13)}-hbf';
    }
    return null;
  }

  /// Fetch the indoor map for a bahnhof.de slug (e.g. `hamburg-hbf`).
  /// [background] = a best-effort prefetch: shorter timeout so a slow stop
  /// fails fast instead of holding a connection for the full foreground budget.
  Future<StationMap> fetchBySlug(String slug, {bool background = false}) async {
    final hit = _cache[slug];
    if (hit != null) {
      AppLog.log('map cache hit "$slug" (instant)', tag: 'map');
      return hit;
    }
    final uri = Uri.parse('https://www.bahnhof.de/$slug/karte');
    // Hard timeout: without it a stalled connection leaves the map spinner
    // hanging forever (no response ever arrives). Surface it as a load error.
    final res = await AppLog.timed(
      'GET $uri',
      () => _client.get(uri, headers: _headers).timeout(
            Duration(seconds: background ? 7 : 12),
            onTimeout: () => throw StationMapException(
                'Zeitüberschreitung beim Laden der Karte für "$slug".'),
          ),
      tag: 'map',
    );
    AppLog.log(
        'GET $slug → HTTP ${res.statusCode}, ${res.bodyBytes.length} bytes',
        tag: 'map');
    if (res.statusCode != 200) {
      throw StationMapException('Bahnhof "$slug" nicht gefunden '
          '(HTTP ${res.statusCode}).');
    }
    final map = _parse(slug, res.body);
    _cache[slug] = map;
    return map;
  }

  /// Resolve a DB station name to a bahnhof.de slug.
  ///
  /// bahnhof.de slugs are the station name, umlaut-expanded and hyphenated
  /// (e.g. "Hamburg Hbf" -> "hamburg-hbf", "Büchen" -> "buechen").
  static String slugify(String name) {
    var s = name.toLowerCase();
    const umlauts = {'ä': 'ae', 'ö': 'oe', 'ü': 'ue', 'ß': 'ss'};
    umlauts.forEach((k, v) => s = s.replaceAll(k, v));
    s = s.replaceAll(RegExp(r'[^a-z0-9]+'), '-');
    s = s.replaceAll(RegExp(r'-{2,}'), '-');
    return s.replaceAll(RegExp(r'^-|-$'), '');
  }

  StationMap _parse(String slug, String html) {
    final blob = _decodeRscBlob(html);
    AppLog.log(
        'parse "$slug": html ${html.length}b → RSC blob ${blob.length}b'
        '${blob.contains('"poi":') ? '' : ' · NO "poi": key!'}',
        tag: 'map');

    // Map centre sits immediately before the `poi` object.
    final loc = RegExp(
            r'"location":\{"longitude":([-0-9.]+),"latitude":([-0-9.]+)\},"poi":\{')
        .firstMatch(blob);

    // Floors and the initial floor bahnhof.de selects.
    final lvl = RegExp(r'"levels":(\[[^\]]+\]),"levelInit":"([^"]+)"')
        .firstMatch(blob);

    final poiObj = _extractPoiObject(blob);
    if (poiObj == null) {
      AppLog.log(
          'parse "$slug": poi object NOT extractable from blob '
          '(${blob.length}b) → throwing "keine Kartendaten"',
          tag: 'map');
      throw StationMapException(
          'Für "$slug" sind keine Kartendaten verfügbar.');
    }

    final pois = <MapPoi>[];
    poiObj.forEach((category, features) {
      if (features is List) {
        for (final f in features) {
          if (f is Map<String, dynamic>) {
            pois.add(MapPoi.fromFeature(category, f));
          }
        }
      }
    });

    final levels = lvl != null
        ? (json.decode(lvl.group(1)!) as List).cast<String>()
        : pois.map((p) => p.level).whereType<String>().toSet().toList();

    final center = loc != null
        ? LatLng(double.parse(loc.group(2)!), double.parse(loc.group(1)!))
        : (pois.isNotEmpty ? pois.first.latLng : const LatLng(51.0, 10.0));

    final anchors = _extractAnchors(blob);
    AppLog.log(
        'parse "$slug" OK: ${pois.length} POIs, ${levels.length} levels, '
        '${pois.where((p) => p.isPlatform).length} platforms, '
        '${pois.where((p) => p.isPlatformSector).length} sector-cubes, '
        '${anchors.length} anchors',
        tag: 'map');
    return StationMap(
      slug: slug,
      center: center,
      levels: levels,
      levelInit: lvl?.group(2) ?? (levels.isNotEmpty ? levels.first : ''),
      pois: pois,
      platformAnchors: anchors,
    );
  }

  /// Lift/escalator access points that name the Gleise they serve. bahnhof.de
  /// ships a richer `elevator`/`escalator` array (separate from the simplified
  /// `poi` GeoJSON) where each entry has a free-text `description`
  /// ("zu Gleis 7/8 Abschnitt E", "von Gleis 11/12 zu Südsteg") and a
  /// `position`. The track pair in that text is the only link in the data
  /// between a real coordinate and specific Gleise, so we mine it to learn the
  /// platform islands.
  List<PlatformAnchor> _extractAnchors(String blob) {
    final anchors = <PlatformAnchor>[];
    final pair = RegExp(r'(?:Gleis|Gl\.|Bstg\.?\s*\d*\s*Gl\.?)\s*(\d+)\s*/\s*(\d+)');
    for (final key in const ['"elevator":[', '"escalator":[']) {
      final arr = _extractJsonArray(blob, key);
      if (arr == null) continue;
      for (final e in arr) {
        if (e is! Map<String, dynamic>) continue;
        final desc = e['description'];
        final pos = e['position'];
        if (desc is! String || pos is! Map) continue;
        final m = pair.firstMatch(desc);
        final lat = (pos['latitude'] as num?)?.toDouble();
        final lon = (pos['longitude'] as num?)?.toDouble();
        if (m == null || lat == null || lon == null) continue;
        anchors.add(PlatformAnchor(
          gleise: {m.group(1)!, m.group(2)!},
          latitude: lat,
          longitude: lon,
        ));
      }
    }
    return anchors;
  }

  /// Balance-parse a `"<key>":[ ... ]` array out of the blob (key includes the
  /// trailing `[`).
  List? _extractJsonArray(String blob, String keyWithBracket) {
    final i = blob.indexOf(keyWithBracket);
    if (i < 0) return null;
    final open = blob.indexOf('[', i);
    var depth = 0;
    var inString = false;
    var escaped = false;
    for (var k = open; k < blob.length; k++) {
      final c = blob[k];
      if (inString) {
        if (escaped) {
          escaped = false;
        } else if (c == '\\') {
          escaped = true;
        } else if (c == '"') {
          inString = false;
        }
        continue;
      }
      if (c == '"') {
        inString = true;
      } else if (c == '[') {
        depth++;
      } else if (c == ']') {
        depth--;
        if (depth == 0) {
          try {
            return json.decode(blob.substring(open, k + 1)) as List;
          } catch (_) {
            return null;
          }
        }
      }
    }
    return null;
  }

  /// Reassemble the RSC payload by concatenating every
  /// `self.__next_f.push([N,"<json-string>"])` chunk.
  ///
  /// We match only the cheap, fixed prefix with a regex, then scan the quoted
  /// string literal by hand. The previous one-shot regex used a nested
  /// quantifier (`("(?:[^"\\]|\\.)*")`) which backtracks/recurses per character
  /// and blew the stack (`StackOverflowError`) on big pages like Hamburg Hbf
  /// (~228 KB). The manual scan is linear and recursion-free.
  String _decodeRscBlob(String html) {
    final marker = RegExp(r'self\.__next_f\.push\(\[\d+,');
    final buf = StringBuffer();
    for (final m in marker.allMatches(html)) {
      var i = m.end;
      while (i < html.length && html[i] == ' ') {
        i++;
      }
      // Only string-valued chunks carry payload; module tables start with `[`.
      if (i >= html.length || html[i] != '"') continue;
      final start = i;
      i++;
      var escaped = false;
      var closed = false;
      while (i < html.length) {
        final c = html[i];
        if (escaped) {
          escaped = false;
        } else if (c == '\\') {
          escaped = true;
        } else if (c == '"') {
          closed = true;
          break;
        }
        i++;
      }
      if (!closed) continue;
      try {
        buf.write(json.decode(html.substring(start, i + 1)) as String);
      } catch (_) {
        // skip anything that isn't a clean JSON string
      }
    }
    return buf.toString();
  }

  /// Balance-parse the `"poi":{ ... }` object out of the blob.
  Map<String, dynamic>? _extractPoiObject(String blob) {
    // The data `poi` object always starts with an uppercase category key.
    final start = RegExp(r'"poi":\{"[A-Z]').firstMatch(blob);
    if (start == null) return null;

    final open = blob.indexOf('{', start.start);
    var depth = 0;
    var inString = false;
    var escaped = false;
    for (var i = open; i < blob.length; i++) {
      final c = blob[i];
      if (inString) {
        if (escaped) {
          escaped = false;
        } else if (c == '\\') {
          escaped = true;
        } else if (c == '"') {
          inString = false;
        }
        continue;
      }
      if (c == '"') {
        inString = true;
      } else if (c == '{') {
        depth++;
      } else if (c == '}') {
        depth--;
        if (depth == 0) {
          final raw = blob.substring(open, i + 1);
          try {
            return json.decode(raw) as Map<String, dynamic>;
          } catch (_) {
            return null;
          }
        }
      }
    }
    return null;
  }

  void dispose() => _client.close();
}

class StationMapException implements Exception {
  final String message;
  StationMapException(this.message);
  @override
  String toString() => message;
}
