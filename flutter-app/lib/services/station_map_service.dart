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

  Map<String, String> get _headers => {
        'User-Agent': ApiConstants.userAgent,
        'Accept': 'text/html,application/xhtml+xml',
        'Accept-Language': 'de-DE,de;q=0.9',
      };

  /// Fetch the indoor map for a DB station name, resolving the bahnhof.de slug.
  ///
  /// bahnhof.de slugs are mostly the umlaut-expanded, hyphenated name
  /// ("Köln Hbf" -> `koeln-hbf`), but a few are irregular ("Berlin Hbf" ->
  /// `berlin-hauptbahnhof`, not `berlin-hbf`). We try the obvious slug first,
  /// then swap `hbf` <-> `hauptbahnhof` as a fallback.
  Future<StationMap> fetchByStationName(String name) async {
    final slug = slugify(name);
    AppLog.log('fetchByStationName "$name" → slug "$slug"', tag: 'map');
    try {
      return await fetchBySlug(slug);
    } on StationMapException catch (e) {
      final alt = _altSlug(slug);
      if (alt != null) {
        AppLog.log('slug "$slug" failed ($e) → retry alt slug "$alt"',
            tag: 'map');
        return await fetchBySlug(alt);
      }
      rethrow;
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
  Future<StationMap> fetchBySlug(String slug) async {
    final uri = Uri.parse('https://www.bahnhof.de/$slug/karte');
    final res = await AppLog.timed(
      'GET $uri',
      () => _client.get(uri, headers: _headers),
      tag: 'map',
    );
    AppLog.log(
        'GET $slug → HTTP ${res.statusCode}, ${res.bodyBytes.length} bytes',
        tag: 'map');
    if (res.statusCode != 200) {
      throw StationMapException('Bahnhof "$slug" nicht gefunden '
          '(HTTP ${res.statusCode}).');
    }
    return _parse(slug, res.body);
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
  String _decodeRscBlob(String html) {
    final re = RegExp(r'self\.__next_f\.push\(\[\d+,("(?:[^"\\]|\\.)*")\]\)',
        dotAll: true);
    final buf = StringBuffer();
    for (final m in re.allMatches(html)) {
      try {
        buf.write(json.decode(m.group(1)!) as String);
      } catch (_) {
        // skip non-string chunks (e.g. module tables)
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
