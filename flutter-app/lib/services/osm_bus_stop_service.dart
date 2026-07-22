import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../core/app_log.dart';

/// One physical bus/tram stop pole — a single side of the street.
///
/// A stop like "Gravelottestraße" exists two, three or four times: once per
/// direction, sometimes once per bay. Timetable data names only the stop, so
/// standing at the wrong pole means watching your bus leave across the road.
/// OSM maps each pole separately, which is what makes the answer possible
/// (#55).
class BusStopBay {
  /// OSM node id — stable identity, used to dedupe.
  final int id;
  final LatLng latLng;

  /// The stop's name ("Gravelottestraße"), as timetables say it.
  final String name;

  /// Bay letter where the operator uses one (OSM `local_ref`, e.g. "A"). This
  /// is the same letter vendo puts in a bus leg's `gleis`/`plattform`, which is
  /// what lets us mark the pole the rider actually needs.
  final String? bay;

  /// Where the buses calling here are heading, most specific first — built from
  /// the route relations this pole belongs to ("14 → Laboe, Hafen").
  final List<String> directions;

  final bool shelter;

  const BusStopBay({
    required this.id,
    required this.latLng,
    required this.name,
    this.bay,
    this.directions = const [],
    this.shelter = false,
  });

  /// One line for the map label: the bay letter if there is one, else the name.
  String get label => bay ?? name;

  /// "Richtung Laboe, Hafen · Rathenow", capped so a busy stop stays readable.
  String? get directionLabel {
    if (directions.isEmpty) return null;
    final shown = directions.take(3).join(' · ');
    return 'Richtung $shown';
  }
}

/// Bus/tram stop poles around a coordinate, from OpenStreetMap via Overpass.
///
/// Same shape as [OsmPlatformService]: keyless public endpoints tried in order,
/// a descriptive User-Agent (overpass-api.de 406s browser/curl/empty ones),
/// in-memory cache, never throws — a failure means "no extra detail", not a
/// broken map.
class OsmBusStopService {
  OsmBusStopService._();
  static final OsmBusStopService instance = OsmBusStopService._();

  static const _endpoints = [
    'https://overpass-api.de/api/interpreter',
    'https://overpass.openstreetmap.fr/api/interpreter',
    'https://overpass.kumi.systems/api/interpreter',
  ];

  static const _userAgent = 'BesserBahn/1.0 (+https://bahn.chuk.dev)';

  /// A stop's poles sit within a few dozen metres of each other; 250 m also
  /// catches the opposite side of a wide junction without pulling in the next
  /// stop along the line.
  static const _radiusM = 250;

  static const _timeout = Duration(seconds: 20);

  final http.Client _client = http.Client();

  /// cache key → poles (empty = "asked, found nothing").
  final Map<String, List<BusStopBay>> _cache = {};
  final Map<String, Future<List<BusStopBay>>> _inflight = {};

  static String _key(LatLng c, String name) =>
      '${c.latitude.toStringAsFixed(4)},'
      '${c.longitude.toStringAsFixed(4)}|${name.toLowerCase()}';

  /// What's already in memory for this stop, or null if it was never asked.
  List<BusStopBay>? cached(LatLng center, String name) =>
      _cache[_key(center, name)];

  /// Poles around [center] belonging to the stop called [name]. Never throws;
  /// returns an empty list when Overpass is unreachable or has nothing.
  Future<List<BusStopBay>> fetch(LatLng center, String name) {
    final key = _key(center, name);
    final done = _cache[key];
    if (done != null) return Future.value(done);
    final pending = _inflight[key];
    if (pending != null) return pending;
    final f = _fetch(key, center, name);
    _inflight[key] = f;
    return f;
  }

  Future<List<BusStopBay>> _fetch(
      String key, LatLng center, String name) async {
    try {
      final lat = center.latitude, lon = center.longitude;
      // The poles, then the route relations they belong to *with their member
      // lists* — that membership is the only way to say which direction leaves
      // from which side.
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
      final bays = parseResponse(json.decode(resp.body), name);
      AppLog.log('OSM bus stops "$name": ${bays.length} poles', tag: 'osm');
      return _settle(key, bays);
    } catch (e) {
      AppLog.log('OSM bus stops "$name" failed: $e', tag: 'osm');
      return _settle(key, const []);
    }
  }

  List<BusStopBay> _settle(String key, List<BusStopBay> bays) {
    _cache[key] = bays;
    _inflight.remove(key);
    return bays;
  }

  /// Overpass JSON → the poles of the stop called [name].
  ///
  /// Exposed for tests: the direction attribution (relation members → pole) is
  /// the whole point and is worth pinning down without a network round-trip.
  static List<BusStopBay> parseResponse(dynamic body, String name) {
    if (body is! Map<String, dynamic>) return const [];
    final elements = body['elements'];
    if (elements is! List) return const [];

    // Timetables spell a stop "Gravelottestraße, Kiel"; OSM tags it
    // "Gravelottestraße" and puts the town elsewhere. Compare on the part
    // before the comma, case- and space-insensitively.
    String norm(String s) =>
        s.split(',').first.toLowerCase().replaceAll(RegExp(r'[\s.-]'), '');
    final wanted = norm(name);

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

    final out = <BusStopBay>[];
    for (final entry in nodes.entries) {
      final tags = (entry.value['tags'] as Map<String, dynamic>?) ?? const {};
      final stopName = (tags['name'] as String?)?.trim() ?? '';
      if (stopName.isEmpty || norm(stopName) != wanted) continue;
      final lat = (entry.value['lat'] as num?)?.toDouble();
      final lon = (entry.value['lon'] as num?)?.toDouble();
      if (lat == null || lon == null) continue;
      out.add(BusStopBay(
        id: entry.key,
        latLng: LatLng(lat, lon),
        name: stopName,
        bay: (tags['local_ref'] as String?)?.trim(),
        directions: directions[entry.key] ?? const [],
        shelter: tags['shelter'] == 'yes',
      ));
    }
    // Bay letter order where there is one, so "A" reads before "B".
    out.sort((a, b) => (a.bay ?? '~').compareTo(b.bay ?? '~'));
    return out;
  }
}
