import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../core/app_log.dart';
import '../core/stop_poles.dart';

/// Stop poles and their departures from **DELFI** — the nationwide German
/// timetable dataset — through the free Transitous/MOTIS API.
///
/// This is the complete half of the picture (#55): every pole of every stop,
/// with exact coordinates, plus which line leaves from it and where it goes.
/// OpenStreetMap supplies the signed bay code on top (see [OsmBusStopService]);
/// DELFI's own codes are internal numbering ("11" for the pole signed "A5") and
/// are only used when OSM has nothing.
///
/// Keyless and public. Best-effort throughout: any failure yields an empty
/// list, and the map falls back to whatever OSM knows.
class TransitStopService {
  TransitStopService._();
  static final TransitStopService instance = TransitStopService._();

  static const _base = 'https://api.transitous.org/api/v1';
  static const _userAgent = 'BesserBahn/1.0 (+https://bahn.chuk.dev)';
  static const _timeout = Duration(seconds: 15);

  /// Half-width of the bbox we ask for, in metres — same reasoning as the
  /// Overpass radius: a bus station's bays spread out around the coordinate.
  static const _boxM = 250.0;

  /// Departures pulled to attribute directions to poles. Enough to cover every
  /// bay of a busy station over the next stretch without paging.
  static const _departures = 100;

  final http.Client _client = http.Client();

  final Map<String, List<StopPole>> _cache = {};
  final Map<String, Future<List<StopPole>>> _inflight = {};

  static String _key(LatLng c) =>
      '${c.latitude.toStringAsFixed(4)},${c.longitude.toStringAsFixed(4)}';

  List<StopPole>? cached(LatLng center) => _cache[_key(center)];

  /// Poles around [center]. Never throws.
  Future<List<StopPole>> fetch(LatLng center) {
    final key = _key(center);
    final done = _cache[key];
    if (done != null) return Future.value(done);
    final pending = _inflight[key];
    if (pending != null) return pending;
    final f = _fetch(key, center);
    _inflight[key] = f;
    return f;
  }

  Future<List<StopPole>> _fetch(String key, LatLng center) async {
    try {
      final stops = await _stopsInBox(center);
      if (stops.isEmpty) return _settle(key, const []);
      // Directions come from the departure board of the nearest pole: MOTIS
      // answers with the whole stop group, so one request covers every bay.
      final directions = await _directionsFor(stops.first.id);
      final poles = <StopPole>[];
      for (final s in stops) {
        if (metresBetween(center, s.latLng) > _poleRadiusM) continue;
        poles.add(StopPole(
          latLng: s.latLng,
          name: s.name,
          bay: s.track,
          directions: directions[s.id] ?? const [],
        ));
      }
      AppLog.log('DELFI poles at $key: ${poles.length}', tag: 'osm');
      return _settle(key, poles);
    } catch (e) {
      AppLog.log('DELFI poles $key failed: $e', tag: 'osm');
      return _settle(key, const []);
    }
  }

  /// Same radius rule as the OSM side, so the two agree on what belongs to this
  /// stop before they are merged.
  static const double _poleRadiusM = 160;

  Future<List<_MotisStop>> _stopsInBox(LatLng c) async {
    final dLat = _boxM / 111320.0;
    final dLon = _boxM / (111320.0 * 0.6); // ~cos(53°), Germany
    final uri = Uri.parse('$_base/map/stops').replace(queryParameters: {
      'min': '${c.latitude - dLat},${c.longitude - dLon}',
      'max': '${c.latitude + dLat},${c.longitude + dLon}',
    });
    final res = await _client
        .get(uri, headers: {'User-Agent': _userAgent, 'Accept': '*/*'})
        .timeout(_timeout);
    if (res.statusCode != 200) {
      AppLog.log('DELFI map/stops HTTP ${res.statusCode}', tag: 'osm');
      return const [];
    }
    final data = json.decode(utf8.decode(res.bodyBytes));
    if (data is! List) return const [];
    final out = <_MotisStop>[];
    for (final e in data) {
      if (e is! Map<String, dynamic>) continue;
      final id = e['stopId'] as String?;
      final lat = (e['lat'] as num?)?.toDouble();
      final lon = (e['lon'] as num?)?.toDouble();
      if (id == null || lat == null || lon == null) continue;
      final modes = (e['modes'] as List<dynamic>? ?? const [])
          .whereType<String>()
          .toSet();
      // Rail platforms have their own (much better) map; this is for the stops
      // that have none.
      if (!modes.any((m) => const {'BUS', 'TRAM', 'COACH', 'FERRY'}.contains(m))) {
        continue;
      }
      out.add(_MotisStop(
        id: id,
        name: (e['name'] as String?) ?? '',
        latLng: LatLng(lat, lon),
        track: trackOf(id),
      ));
    }
    out.sort((a, b) =>
        metresBetween(c, a.latLng).compareTo(metresBetween(c, b.latLng)));
    return out;
  }

  /// Line + headsign per pole id, from one departure board.
  Future<Map<String, List<String>>> _directionsFor(String stopId) async {
    final uri = Uri.parse('$_base/stoptimes').replace(queryParameters: {
      'stopId': stopId,
      'time': DateTime.now().toUtc().toIso8601String(),
      'n': '$_departures',
    });
    final res = await _client
        .get(uri, headers: {'User-Agent': _userAgent, 'Accept': '*/*'})
        .timeout(_timeout);
    if (res.statusCode != 200) return const {};
    return parseStopTimes(json.decode(utf8.decode(res.bodyBytes)));
  }

  List<StopPole> _settle(String key, List<StopPole> poles) {
    _cache[key] = poles;
    _inflight.remove(key);
    return poles;
  }

  /// The bay code inside a DELFI stop id (`…:49079::A4` → `A4`), or null.
  static String? trackOf(String stopId) {
    final i = stopId.lastIndexOf('::');
    if (i < 0) return null;
    final t = stopId.substring(i + 2).trim();
    return t.isEmpty ? null : t;
  }

  /// MOTIS `/stoptimes` JSON → pole id ⇒ ["14 → Laboe", …].
  ///
  /// Exposed for tests. Deduplicated and ordered as encountered, i.e. soonest
  /// departure first, which is the order a waiting rider cares about.
  static Map<String, List<String>> parseStopTimes(dynamic body) {
    if (body is! Map<String, dynamic>) return const {};
    final times = body['stopTimes'];
    if (times is! List) return const {};
    final out = <String, List<String>>{};
    for (final st in times) {
      if (st is! Map<String, dynamic>) continue;
      final place = st['place'];
      if (place is! Map<String, dynamic>) continue;
      final id = place['stopId'] as String?;
      if (id == null) continue;
      final headsign = (st['headsign'] as String?)?.trim();
      if (headsign == null || headsign.isEmpty) continue;
      final line = (st['routeShortName'] as String?)?.trim();
      final label =
          line == null || line.isEmpty ? headsign : '$line → $headsign';
      final list = out.putIfAbsent(id, () => <String>[]);
      if (!list.contains(label)) list.add(label);
    }
    return out;
  }
}

class _MotisStop {
  final String id;
  final String name;
  final LatLng latLng;
  final String? track;
  const _MotisStop({
    required this.id,
    required this.name,
    required this.latLng,
    this.track,
  });
}
