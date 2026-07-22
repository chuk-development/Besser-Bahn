import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../core/app_log.dart';
import '../core/stop_poles.dart';

/// Bus/tram stop poles around a coordinate, from OpenStreetMap via Overpass.
///
/// OSM is the source of the **signed bay code** (`local_ref`: "A4"), which is
/// the code DB puts in a leg's `gleis` — CoMaps and every other OSM map draws
/// exactly those labels at ZOB Kiel. Its coverage is uneven, so it is merged
/// with the DELFI poles (see [StopPole] and `TransitStopService`).
///
/// Keyless public endpoints tried in order, a descriptive User-Agent
/// (overpass-api.de 406s browser/curl/empty ones), in-memory cache, never
/// throws — a failure means "no extra detail", not a broken map.
class OsmBusStopService {
  OsmBusStopService._();
  static final OsmBusStopService instance = OsmBusStopService._();

  static const _endpoints = [
    'https://overpass-api.de/api/interpreter',
    'https://overpass.openstreetmap.fr/api/interpreter',
    'https://overpass.kumi.systems/api/interpreter',
  ];

  static const _userAgent = 'BesserBahn/1.0 (+https://bahn.chuk.dev)';

  /// A bus station's bays fan out over ~150 m (ZOB Kiel: A1 to A5 is 90 m), and
  /// the timetable coordinate sits somewhere in the middle. 250 m covers that
  /// without dragging in the next stop along the line.
  static const _radiusM = 250;

  static const _timeout = Duration(seconds: 20);

  final http.Client _client = http.Client();

  final Map<String, List<StopPole>> _cache = {};
  final Map<String, Future<List<StopPole>>> _inflight = {};

  static String _key(LatLng c) =>
      '${c.latitude.toStringAsFixed(4)},${c.longitude.toStringAsFixed(4)}';

  List<StopPole>? cached(LatLng center) => _cache[_key(center)];

  /// Poles around [center]. Never throws; empty when Overpass is unreachable.
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
      final lat = center.latitude, lon = center.longitude;
      // The poles, then the route relations they belong to *with their member
      // lists* — that membership is the only way to say which direction leaves
      // from which pole.
      final ql = '[out:json][timeout:25];'
          'node["highway"~"bus_stop|tram_stop"](around:$_radiusM,$lat,$lon)->.s;'
          '.s out tags center;'
          'rel(bn.s)["type"="route"]["route"~"bus|tram|trolleybus"];'
          'out body;';
      http.Response? resp;
      for (final endpoint in _endpoints) {
        try {
          final r = await _client
              .post(
                Uri.parse(endpoint),
                headers: {
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
          AppLog.log('OSM bus stops $endpoint HTTP ${r.statusCode}', tag: 'osm');
        } catch (e) {
          AppLog.log('OSM bus stops $endpoint error: $e', tag: 'osm');
        }
      }
      if (resp == null) return _settle(key, const []);
      final poles = parseResponse(json.decode(resp.body), center);
      AppLog.log('OSM poles at $key: ${poles.length}', tag: 'osm');
      return _settle(key, poles);
    } catch (e) {
      AppLog.log('OSM bus stops $key failed: $e', tag: 'osm');
      return _settle(key, const []);
    }
  }

  List<StopPole> _settle(String key, List<StopPole> poles) {
    _cache[key] = poles;
    _inflight.remove(key);
    return poles;
  }

  /// How far a pole may sit from the timetable coordinate and still belong to
  /// this stop. Generous, because that coordinate is the stop's centre and a
  /// bus station's bays spread out around it.
  static const double poleRadiusM = 160;

  /// Overpass JSON → the poles of the stop at [center].
  ///
  /// Selection is by **distance**, not by name. Names were the first
  /// implementation and they do not survive contact with reality: DB says
  /// "ZOB, Kiel" where OSM says "Kiel ZOB", and "Wittenberger Passau B202,
  /// Martensrade" where OSM says "Wittenberger Passau, B202" — both matched
  /// nothing, so those stops got no map at all (#55).
  ///
  /// Exposed for tests: the direction attribution (relation members → pole) is
  /// the whole point and is worth pinning down without a network round-trip.
  static List<StopPole> parseResponse(dynamic body, LatLng center) {
    if (body is! Map<String, dynamic>) return const [];
    final elements = body['elements'];
    if (elements is! List) return const [];

    final nodes = <int, Map<String, dynamic>>{};
    final relations = <Map<String, dynamic>>[];
    for (final e in elements) {
      if (e is! Map<String, dynamic>) continue;
      if (e['type'] == 'node') {
        nodes[(e['id'] as num).toInt()] = e;
      } else if (e['type'] == 'relation') {
        relations.add(e);
      }
    }

    // node id → the directions of every route calling there.
    final directions = <int, List<String>>{};
    for (final rel in relations) {
      final tags = (rel['tags'] as Map<String, dynamic>?) ?? const {};
      final to = (tags['to'] as String?)?.trim();
      if (to == null || to.isEmpty) continue;
      final ref = (tags['ref'] as String?)?.trim();
      final label = ref == null || ref.isEmpty ? to : '$ref → $to';
      for (final m in (rel['members'] as List<dynamic>? ?? const [])) {
        if (m is! Map<String, dynamic> || m['type'] != 'node') continue;
        final id = (m['ref'] as num?)?.toInt();
        if (id == null || !nodes.containsKey(id)) continue;
        final list = directions.putIfAbsent(id, () => <String>[]);
        if (!list.contains(label)) list.add(label);
      }
    }

    final out = <StopPole>[];
    for (final entry in nodes.entries) {
      final tags = (entry.value['tags'] as Map<String, dynamic>?) ?? const {};
      final lat = (entry.value['lat'] as num?)?.toDouble();
      final lon = (entry.value['lon'] as num?)?.toDouble();
      if (lat == null || lon == null) continue;
      final at = LatLng(lat, lon);
      if (metresBetween(center, at) > poleRadiusM) continue;
      out.add(StopPole(
        latLng: at,
        name: (tags['name'] as String?)?.trim() ?? '',
        bay: (tags['local_ref'] as String?)?.trim(),
        directions: directions[entry.key] ?? const [],
        shelter: tags['shelter'] == 'yes',
      ));
    }
    out.sort((a, b) => (a.bay ?? '~~').compareTo(b.bay ?? '~~'));
    return out;
  }
}
