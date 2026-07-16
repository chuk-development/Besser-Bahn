import 'dart:convert';
import 'package:flutter/foundation.dart' show compute, visibleForTesting;
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import '../core/app_log.dart';
import '../core/constants.dart';
import '../models/station_map.dart';
import 'offline_store.dart';

/// Scrapes the live indoor-map dataset for a station from bahnhof.de.
///
/// bahnhof.de is a Next.js app that ships the map as a GeoJSON `poi` payload
/// inside the server-rendered React-Server-Components stream. There is no
/// public JSON/GeoJSON endpoint — verified by capturing every request the
/// `/karte` page makes: only tile PNGs hit `maps.reisenden.info`, the POIs are
/// rendered server-side and the `rimapsapi` POI paths are 401 (key-gated). So
/// we still pull the JSON out of the RSC payload, but we fetch the *raw* RSC
/// flight stream instead of the full HTML document:
///
///   * Request the page with the `RSC: 1` header → the server returns the
///     `text/x-component` flight stream (~15-20 % smaller than the HTML and,
///     crucially, NOT wrapped in `self.__next_f.push([...])` chunks). The poi
///     object, levels and lift/escalator arrays sit in it verbatim, so we feed
///     it straight to the regex/balance parser and SKIP the expensive per-char
///     `self.__next_f` reassembly that the HTML path needs.
///   * Parsing runs in a background isolate (`compute`) so a ~190 KB blob never
///     janks the UI / blocks the map.
///
/// The HTML document remains the fallback: if the RSC stream is missing the
/// poi data we re-fetch the page as HTML and reassemble the `__next_f` chunks
/// the old way, so we never regress.
class StationMapService {
  final http.Client _client = http.Client();

  /// Parsed maps keyed by slug (session cache). Re-opening the same station —
  /// the common case when bouncing between stops of a journey — is then instant
  /// instead of re-downloading ~230 KB of HTML and re-parsing it.
  final Map<String, StationMap> _cache = {};

  /// Headers that ask bahnhof.de for the raw RSC flight stream
  /// (`text/x-component`) rather than the full HTML document. The `RSC: 1`
  /// header is what the Next.js app router sends for a soft navigation; the
  /// server then skips the HTML shell and streams just the component tree —
  /// smaller, and not wrapped in `self.__next_f.push` chunks.
  Map<String, String> get _rscHeaders => {
        'User-Agent': ApiConstants.userAgent,
        'Accept': '*/*',
        'Accept-Language': 'de-DE,de;q=0.9',
        'RSC': '1',
      };

  /// Headers for the HTML fallback fetch.
  Map<String, String> get _htmlHeaders => {
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
    // Background prefetch (the route map warms every stop) stays SILENT on
    // success — otherwise ~4 lines × 20+ stops floods the debug log so you
    // can't scroll. Only the foreground Karte-tab open logs.
    if (!background) AppLog.log('fetchByStationName "$name" → slug "$slug"', tag: 'map');
    try {
      return await fetchBySlug(slug, background: background);
    } on StationMapException catch (e) {
      // Background prefetch is best-effort: don't pay a SECOND timeout on the
      // alt slug (that's what turned one slow stop into a ~30 s hang).
      if (background) rethrow;
      // Only a genuine NOT-FOUND (wrong slug) is worth swapping
      // hbf<->hauptbahnhof. A timeout/network blip is transient: retrying a
      // DIFFERENT slug there just 404s and mis-reports the real station as
      // "nicht gefunden" — and worse, caches that bogus 404 — so a perfectly
      // valid stop (Kiel Hbf) shows "gibt es nicht", then loads fine on the
      // next try. Rethrow the transient error so the UI offers a retry instead.
      if (e.transient) rethrow;
      final alt = _altSlug(slug);
      if (alt != null) {
        AppLog.log('slug "$slug" not found ($e) → retry alt slug "$alt"',
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
  /// Slugs known to have NO usable map (404 or no poi data). Static so the
  /// verdict survives across map opens this session — once we learn a small
  /// halt has no platform plan, we never scrape it again (instant fail, no
  /// network), instead of retrying it every time the rider pans over it.
  static final Set<String> _noMap = {};

  Future<StationMap> fetchBySlug(String slug, {bool background = false}) async {
    final hit = _cache[slug];
    if (hit != null) return hit;
    try {
      return (await fetchRawBySlug(slug, background: background)).map;
    } catch (e) {
      // Offline (or bahnhof.de is unreachable) — replay an offline package's
      // copy if the rider downloaded one, rather than showing a bare error at
      // the exact moment they're standing on the platform looking for their
      // coach. `_noMap` verdicts are permanent and intentionally not overridden.
      final body = await OfflineStore.instance.readStationMap(slug);
      if (body != null) {
        try {
          final map = parsePersistedBody(slug, body);
          AppLog.log('station map "$slug" served from offline package',
              tag: 'offline');
          return map;
        } catch (_) {/* unusable payload → surface the original failure */}
      }
      rethrow;
    }
  }

  /// Fetch a station map AND hand back the exact body it was parsed from, so the
  /// offline package (#29) can persist those bytes and replay them via
  /// [parsePersistedBody] with no network. [StationMap] has no `toJson`, so
  /// storing the scraped body is the only way to keep a station map offline
  /// without duplicating the parser's model as a serialisation.
  ///
  /// Always hits the network — the session cache holds parsed maps, not bodies.
  Future<({String body, StationMap map})> fetchRawBySlug(String slug,
      {bool background = false}) async {
    if (_noMap.contains(slug)) {
      // Already known to have no map — fail instantly, no network.
      throw StationMapException('Bahnhof "$slug" hat keine Karte.',
          transient: false);
    }
    final uri = Uri.parse('https://www.bahnhof.de/$slug/karte');
    // 8s in background: a slow-but-reachable stop (Kiel needed ~8s on a
    // congested connection) should still succeed, not get cut at 5s and show no
    // train. With bounded concurrency the wait overlaps across stops anyway.
    final timeout = Duration(seconds: background ? 8 : 12);
    final sw = Stopwatch()..start();

    // Fast path: ask for the raw RSC flight stream. ~15-20 % smaller than the
    // HTML and parse-friendlier (no __next_f reassembly).
    final res = await _client.get(uri, headers: _rscHeaders).timeout(
          timeout,
          onTimeout: () => throw StationMapException(
              'Zeitüberschreitung beim Laden der Karte für "$slug".'),
        );
    if (res.statusCode != 200) {
      // 404 etc. = this station has no /karte page. Permanent, remember it.
      _noMap.add(slug);
      throw StationMapException(
          'Bahnhof "$slug" nicht gefunden (HTTP ${res.statusCode}).',
          transient: false);
    }

    // Parse off the UI isolate — a ~190 KB blob's regex/balance scan would
    // otherwise jank the map. `compute` ships only the (slug, body) strings out
    // and a plain-data StationMap back, both isolate-sendable.
    try {
      final map = await compute(_parseInIsolate, _ParseInput(slug, res.body));
      if (!background) {
        _logParsed(slug, 'rsc', map, sw.elapsedMilliseconds, res.bodyBytes.length);
      }
      _cache[slug] = map;
      return (body: res.body, map: map);
    } on StationMapException {
      // RSC stream lacked the poi data (unexpected server shape) — fall back to
      // the full HTML document and reassemble the __next_f chunks the old way,
      // so we never regress versus the original scrape.
      if (!background) {
        AppLog.log('rsc parse for "$slug" had no poi → HTML fallback', tag: 'map');
      }
      final html = await _client.get(uri, headers: _htmlHeaders).timeout(
            timeout,
            onTimeout: () => throw StationMapException(
                'Zeitüberschreitung beim Laden der Karte für "$slug".'),
          );
      if (html.statusCode != 200) {
        _noMap.add(slug);
        throw StationMapException(
            'Bahnhof "$slug" nicht gefunden (HTTP ${html.statusCode}).',
            transient: false);
      }
      try {
        final map = await compute(_parseInIsolate, _ParseInput(slug, html.body));
        if (!background) {
          _logParsed(
              slug, 'html', map, sw.elapsedMilliseconds, html.bodyBytes.length);
        }
        _cache[slug] = map;
        return (body: html.body, map: map);
      } on StationMapException {
        // No poi in the HTML either → this station genuinely has no map data.
        _noMap.add(slug);
        throw StationMapException(
            'Für "$slug" sind keine Kartendaten verfügbar.',
            transient: false);
      }
    }
  }

  /// One-line summary of what a parsed station map actually contains — the key
  /// diagnostic when a stop "has no train": it tells you at a glance whether the
  /// scrape found platforms (Gleise), sector cubes (A/B/C…) and lift/escalator
  /// anchors, or came back empty. `platformTrainCars` needs platforms + ≥2
  /// sector cubes; anchors only help disambiguate multi-island stations.
  void _logParsed(String slug, String via, StationMap map, int ms, int bytes) {
    final cubes = map.pois.where((p) => p.isPlatformSector).length;
    AppLog.log(
        'map "$slug" ($via ${ms}ms ${(bytes / 1024).round()}KB): '
        '${map.platforms.length} platforms, $cubes sector-cubes, '
        '${map.platformAnchors.length} anchors, ${map.levels.length} levels',
        tag: 'map');
  }

  /// Replay a body persisted by [fetchRawBySlug] — the offline path. Warms the
  /// session cache so everything downstream (`cachedByName`, `fetchByStationName`)
  /// serves it exactly like a live fetch.
  ///
  /// Runs the parse inline rather than via `compute`: an offline replay happens
  /// once per station while a screen is already waiting, and spawning an isolate
  /// per stop costs more than the parse itself.
  StationMap parsePersistedBody(String slug, String body) {
    final map = _parseBody(slug, body);
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

  void dispose() => _client.close();
}

/// Payload for the parse isolate — just the two strings (isolate-sendable).
class _ParseInput {
  final String slug;
  final String body;
  const _ParseInput(this.slug, this.body);
}

/// `compute` entry point: parse a bahnhof.de RSC body into a [StationMap] on a
/// background isolate. Top-level so it can be sent to the isolate. Throws
/// [StationMapException] when the body carries no poi data (caller then retries
/// via the HTML fallback).
StationMap _parseInIsolate(_ParseInput input) => _parseBody(input.slug, input.body);

/// Parse a raw bahnhof.de RSC/HTML body into a [StationMap] — the same routine
/// the service runs, exposed so tests can verify parsing against a saved
/// fixture deterministically (no network).
@visibleForTesting
StationMap parseStationMapBody(String slug, String body) =>
    _parseBody(slug, body);

StationMap _parseBody(String slug, String body) {
  // The body is either the raw RSC flight stream (from the `RSC: 1` fetch — the
  // poi JSON sits in it verbatim) or the full HTML document (fallback, where
  // the poi JSON is split across `self.__next_f.push([...])` chunks). Only the
  // HTML case needs reassembly; for the flight stream we parse it directly,
  // skipping the per-char chunk scan entirely.
  final blob =
      body.contains('self.__next_f.push') ? _decodeRscBlob(body) : body;

  // Map centre sits immediately before the `poi` object.
  final loc = RegExp(
          r'"location":\{"longitude":([-0-9.]+),"latitude":([-0-9.]+)\},"poi":\{')
      .firstMatch(blob);

  // Floors and the initial floor bahnhof.de selects.
  final lvl =
      RegExp(r'"levels":(\[[^\]]+\]),"levelInit":"([^"]+)"').firstMatch(blob);

  final poiObj = _extractPoiObject(blob);
  if (poiObj == null) {
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

class StationMapException implements Exception {
  final String message;

  /// Whether retrying could help. `true` for timeout / network blips (worth a
  /// retry when the rider revisits the stop); `false` for a permanent verdict —
  /// the station simply has no map (404 / no poi data), so we must NOT keep
  /// trying to fetch it forever.
  final bool transient;

  StationMapException(this.message, {this.transient = true});
  @override
  String toString() => message;
}
