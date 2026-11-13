import 'dart:convert';
import 'dart:math';

import '../src/core.dart';

/// Checks of group "geo": OpenStreetMap/Overpass, DELFI via Transitous, the
/// regional (Verbund) platform sources and the basemap. Ported from
/// api-tests/healthcheck.py.
final List<Check> geoChecks = [
  Check(
    'osm platform geometry (overpass)',
    checkOsmPlatformGeometry,
    group: 'geo',
  ),
  Check(
    'osm bus stop sides (#55)',
    checkOsmBusStopSides,
    soft: true,
    group: 'geo',
  ),
  Check(
    'delfi stop poles (#55)',
    checkDelfiStopPoles,
    soft: true,
    group: 'geo',
  ),
  Check(
    'regionale Steig-/Gleisquellen HAFAS (16 Verbünde)',
    checkRegionalPlatformSources,
    soft: true,
    group: 'geo',
  ),
  Check(
    'regionale Steig-/Gleisquellen EFA (BW/BY/NRW/SN)',
    checkEfaPlatformSources,
    soft: true,
    group: 'geo',
  ),
  Check(
    'basemap (OpenFreeMap Positron vector)',
    checkBasemapTiles,
    soft: true,
    group: 'geo',
  ),
  Check(
    'basemap offline style bundle (#29)',
    checkBasemapOfflineBundle,
    soft: true,
    group: 'geo',
  ),
];

/// The UA the app's Overpass / Transitous services send.
const _osmUa = 'BesserBahn/1.0 (+https://bahn.chuk.dev)';

/// Same mirror fallthrough as the app (services/osm_platform_service.dart):
/// the main instance 504s under load, so try mirrors before failing.
const _overpassEndpoints = [
  'https://overpass-api.de/api/interpreter',
  'https://overpass.openstreetmap.fr/api/interpreter',
  'https://overpass.kumi.systems/api/interpreter',
];

double _rad(double deg) => deg * pi / 180.0;

/// Python-style list repr (`['a', 'b']`) so messages read as before.
String _pyList(Iterable<Object?> xs) =>
    '[${xs.map((x) => x is String ? "'$x'" : '$x').join(', ')}]';

Future<Resp> _overpass(String ql) async {
  String? last;
  for (final endpoint in _overpassEndpoints) {
    try {
      final r = await post(
        endpoint,
        body: {'data': ql},
        headers: {'User-Agent': _osmUa, 'Accept': '*/*'},
      );
      if (r.status == 200) return r;
      last = '$endpoint HTTP ${r.status}';
    } on RequestException {
      last = '$endpoint RequestException';
    }
  }
  throw CheckError('all Overpass mirrors unavailable (last: $last)');
}

/// OpenStreetMap platform + rail geometry via Overpass — the accurate track
/// centre-line the platform train rides (services/osm_platform_service.dart →
/// core/osm_rail.dart). Same Overpass QL as the app around Hamburg Hbf:
/// `public_transport=platform` ways/relations carrying a `ref` (the Gleis pair)
/// + every `railway=rail` way, `out geom;`.
Future<String> checkOsmPlatformGeometry() async {
  // ~600 m bbox around Hamburg Hbf (10.006909, 53.552733), matching the app.
  const lat = 53.552733, lon = 10.006909, r = 600.0;
  const dLat = r / 111320.0;
  final dLon = r / (111320.0 * cos(_rad(lat)));
  final bbox = '${lat - dLat},${lon - dLon},${lat + dLat},${lon + dLon}';
  final ql =
      '[out:json][timeout:25];('
      'way["public_transport"="platform"]["ref"]($bbox);'
      'relation["public_transport"="platform"]["ref"]($bbox);'
      'way["railway"="rail"]($bbox);'
      ');out geom;';
  final resp = await _overpass(ql);
  final elements = maps(resp.jsonMap()['elements']);
  if (elements.isEmpty) {
    throw CheckError('Overpass returned no elements near Hamburg Hbf');
  }
  bool hasGeom(Map<String, dynamic> el) {
    final geom = maps(el['geometry']);
    return geom.length >= 2 &&
        geom.first.containsKey('lat') &&
        geom.first.containsKey('lon');
  }

  final platforms = <String>[];
  var rails = 0;
  for (final el in elements) {
    final tags = mapOf(el, 'tags');
    final ref = tags['ref'];
    if (tags['railway'] == 'rail') {
      if (hasGeom(el)) rails++;
    } else if (tags['public_transport'] == 'platform' &&
        ref is String &&
        ref.isNotEmpty) {
      // A relation's geometry lives in its member ways, not at top level.
      if (el['type'] == 'relation') {
        if (listOf(el, 'members').isNotEmpty) platforms.add(ref);
      } else if (hasGeom(el)) {
        platforms.add(ref);
      }
    }
  }
  if (platforms.isEmpty) {
    throw CheckError('no public_transport=platform ways with a ref (Gleis)');
  }
  if (rails < 1) throw CheckError('no railway=rail ways with inlined geometry');
  // The Gleis-7 island ("7;8") is what the preview/port is verified against.
  if (!platforms.any((p) => p.split(';').contains('7'))) {
    throw CheckError(
      'no platform ref includes Gleis 7 (got ${_pyList(platforms.take(6))})',
    );
  }
  final uniq = platforms.toSet().toList()..sort();
  return '${platforms.length} platform refs (e.g. ${_pyList(uniq.take(5))}), '
      '$rails rail ways';
}

/// Bus-stop poles + their directions via Overpass — the data behind "which side
/// of the street does my bus leave from?" (services/osm_bus_stop_service.dart,
/// #55). Probed at Gravelottestraße in Kiel. Soft: the app degrades to no bus
/// map if Overpass is down.
Future<String> checkOsmBusStopSides() async {
  const lat = 54.325005, lon = 10.113323;
  const ql =
      '[out:json][timeout:25];'
      'node["highway"~"bus_stop|tram_stop"](around:250,$lat,$lon)->.s;'
      '.s out tags center;'
      'rel(bn.s)["type"="route"]["route"~"bus|tram|trolleybus"];'
      'out body;';
  final resp = await _overpass(ql);
  final elements = maps(resp.jsonMap()['elements']);
  final nodes = <Object?, Map<String, dynamic>>{
    for (final el in elements)
      if (el['type'] == 'node') el['id']: el,
  };
  final rels = elements.where((el) => el['type'] == 'relation').toList();
  final poles = nodes.values
      .where(
        (n) => '${mapOf(n, 'tags')['name'] ?? ''}'.startsWith('Gravelotte'),
      )
      .toList();
  if (poles.length < 2) {
    throw CheckError(
      'expected several poles for one stop, got ${poles.length}',
    );
  }
  bool truthy(Object? v) => v != null && v != '' && v != false;
  if (!poles.any((p) => truthy(mapOf(p, 'tags')['local_ref']))) {
    throw CheckError('no pole carries a local_ref bay letter');
  }
  // Direction attribution needs BOTH the relation's `to` and its member list.
  var attributed = 0;
  for (final rel in rels) {
    if (!truthy(mapOf(rel, 'tags')['to'])) continue;
    for (final m in maps(rel['members'])) {
      if (m['type'] == 'node' && nodes.containsKey(m['ref'])) attributed++;
    }
  }
  if (attributed < 1) {
    throw CheckError(
      'no route relation names a direction for a pole '
      '(members or `to` missing → no Fahrtrichtung)',
    );
  }
  final bays =
      poles
          .map((p) => mapOf(p, 'tags')['local_ref'])
          .whereType<String>()
          .toSet()
          .toList()
        ..sort();
  return '${poles.length} poles for one stop (bays ${_pyList(bays)}), '
      '$attributed pole↔direction links';
}

/// Metres between two (lat, lon) pairs — equirectangular, fine at pole
/// distances (mirrors core/stop_poles.dart's metresBetween).
double _metres((double, double) a, (double, double) b) {
  final dLat = (a.$1 - b.$1) * 111320.0;
  final dLon = (a.$2 - b.$2) * 111320.0 * cos(_rad(a.$1));
  return sqrt(dLat * dLat + dLon * dLon);
}

/// `datetime.now(timezone.utc).isoformat()` — microseconds and `+00:00`.
String _pyUtcIso(DateTime now) {
  final u = now.toUtc();
  final us = (u.millisecond * 1000 + u.microsecond).toString().padLeft(6, '0');
  return '${ymd(u)}T${two(u.hour)}:${two(u.minute)}:${two(u.second)}.$us'
      '+00:00';
}

/// DELFI stop poles + their departures via the Transitous/MOTIS API — the
/// complete half of "which side of the street does my bus leave from?"
/// (services/transit_stop_service.dart, #55). Probed at ZOB Kiel and at
/// Wittenberger Passau. Soft: free volunteer-run API, the app degrades to
/// OSM-only.
Future<String> checkDelfiStopPoles() async {
  const base = 'https://api.transitous.org/api/v1';
  const headers = {'User-Agent': _osmUa, 'Accept': '*/*'};

  Future<List<Map<String, dynamic>>> stops(
    double lat,
    double lon, {
    double box = 250.0,
  }) async {
    final dLat = box / 111320.0;
    final dLon = box / (111320.0 * 0.6);
    final r = await get(
      '$base/map/stops',
      query: {
        'min': '${lat - dLat},${lon - dLon}',
        'max': '${lat + dLat},${lon + dLon}',
      },
      headers: headers,
    );
    if (r.status != 200) throw CheckError('map/stops HTTP ${r.status}');
    const wanted = {'BUS', 'TRAM', 'COACH', 'FERRY'};
    return maps(
      r.json(),
    ).where((s) => listOf(s, 'modes').any(wanted.contains)).toList();
  }

  double num_(Object? v) => (v as num).toDouble();

  // ZOB Kiel — the bays must come back as separate stops with coordinates.
  final zob = await stops(54.316906, 10.133773);
  if (zob.length < 4) {
    throw CheckError('expected several bays at ZOB Kiel, got ${zob.length}');
  }
  if (!zob.any((s) => '${s['stopId']}'.contains('::'))) {
    throw CheckError('no stop id carries a ::bay suffix (shape changed)');
  }

  // Directions: one departure board covers the whole stop group.
  double d2(Map<String, dynamic> s) =>
      pow(num_(s['lat']) - 54.316906, 2).toDouble() +
      pow(num_(s['lon']) - 10.133773, 2).toDouble();
  final nearest = zob.reduce((a, b) => d2(b) < d2(a) ? b : a);
  final r = await get(
    '$base/stoptimes',
    query: {
      'stopId': nearest['stopId'],
      'time': _pyUtcIso(DateTime.now()),
      'n': 100,
    },
    headers: headers,
  );
  if (r.status != 200) throw CheckError('stoptimes HTTP ${r.status}');
  final perPole = <Object?, Set<String>>{};
  for (final st in maps(r.jsonMap()['stopTimes'])) {
    final headsign = st['headsign'];
    if (headsign is! String || headsign.isEmpty) continue;
    perPole.putIfAbsent(mapOf(st, 'place')['stopId'], () => {}).add(headsign);
  }
  if (perPole.isEmpty) {
    throw CheckError('no departure carries a headsign (no Fahrtrichtung)');
  }

  // Wittenberger Passau B202 — OSM has no local_ref here, so DELFI is the only
  // source that can tell the two sides apart.
  final passau = await stops(54.29053, 10.38333, box: 160.0);
  if (passau.length < 2) {
    throw CheckError(
      'expected both poles at Wittenberger Passau B202, got ${passau.length}',
    );
  }

  // How far the two datasets disagree about the SAME bay, and how close two
  // DIFFERENT bays get. `mergePoles` joins by bay code first for exactly this
  // reason: no distance threshold can separate them at Kiel Hbf.
  final hbf = <String, (double, double)>{};
  for (final s in await stops(54.315502, 10.13069, box: 200.0)) {
    final sid = '${s['stopId']}';
    if (sid.contains('::')) {
      hbf[sid.substring(sid.lastIndexOf('::') + 2).toUpperCase()] = (
        num_(s['lat']),
        num_(s['lon']),
      );
    }
  }
  const osmHbf = <String, (double, double)>{
    'B1': (54.315671, 10.131436),
    'D2': (54.315959, 10.131234),
  };
  final gaps = <String, double>{};
  osmHbf.forEach((bay, at) {
    final d = hbf[bay];
    if (d != null) gaps[bay] = _metres(at, d);
  });
  if (gaps.isEmpty) {
    throw CheckError(
      'Kiel Hbf: DELFI no longer signs its bays with the codes on the signs '
      '(::B1) — merge-by-bay is blind',
    );
  }
  // The trap: the nearest DELFI pole to OSM's B1 must be allowed to be a
  // DIFFERENT bay. If it is, distance alone would mismatch them.
  final nearestToB1 = hbf.entries
      .map((e) => (e.key, _metres(osmHbf['B1']!, e.value)))
      .reduce((a, b) => b.$2 < a.$2 ? b : a);

  return 'ZOB Kiel ${zob.length} bays, ${perPole.length} with directions; '
      'Wittenberger Passau ${passau.length} poles; '
      'Kiel Hbf same-bay gap '
      '${gaps.entries.map((e) => '${e.key} ${e.value.toStringAsFixed(0)} m').join(', ')} '
      '(nearest DELFI pole to OSM B1: ${nearestToB1.$1} at '
      '${nearestToB1.$2.toStringAsFixed(0)} m)';
}

/// Every regional authority's own HAFAS the app consults, as
/// flutter-app/lib/services/regional_profiles.dart lists them: (id, label,
/// endpoint, client id, client name, aid, probe stop). 1.34 / 4000100 is what
/// the whole cluster accepts, and what the app sends.
const _regionalProfiles =
    <(String, String, String, String, String, String, String)>[
      (
        'kvb',
        'KVB Köln',
        'https://auskunft.kvb.koeln/gate',
        'HAFAS',
        'webapp',
        'Rt6foY5zcTTRXMQs',
        'Köln Hbf',
      ),
      (
        'avv',
        'AVV Aachen',
        'https://auskunft.avv.de/bin/mgate.exe',
        'AVV_AACHEN',
        'webapp',
        '4vV1AcH3N511icH',
        'Aachen Bushof',
      ),
      (
        'bvg',
        'BVG Berlin',
        'https://bvg.hafas.cloud/apps/gate',
        'VBB',
        'webapp',
        'dVg4TZbW8anjx9ztPwe2uk4LVRi9wO',
        'Berlin Alexanderplatz',
      ),
      (
        'rsag',
        'RSAG Rostock',
        'https://fahrplan.rsag-online.de/bin/mgate.exe',
        'RSAG',
        'webapp',
        'tF5JTs25rzUhGrrl',
        'Rostock Hbf',
      ),
      (
        'invg',
        'INVG Ingolstadt',
        'https://fpa.invg.de/bin/mgate.exe',
        'INVG',
        'invgPROD-APPSTORE-LIVE',
        'GITvwi3BGOmTQ2a5',
        'Ingolstadt Hbf',
      ),
      (
        'vos',
        'VOS Osnabrück',
        'https://fahrplan.vos.info/bin/mgate.exe',
        'SWO',
        'webapp',
        'PnYowCQP7Tp1V',
        'Osnabrück Hbf',
      ),
      (
        'vsn',
        'VSN Südniedersachsen',
        'https://fahrplaner.vsninfo.de/hafas/mgate.exe',
        'VSN',
        'vsn',
        'Mpf5UPC0DmzV8jkg',
        'Göttingen Hbf',
      ),
      (
        'nvv',
        'NVV Nordhessen',
        'https://auskunft.nvv.de/auskunft/bin/app/mgate.exe',
        'NVV',
        'NVVMobilPROD_APPSTORE',
        'Kt8eNOH7qjVeSxNA',
        'Kassel Hbf',
      ),
      (
        'sbahn-muenchen',
        'MVV München',
        'https://s-bahn-muenchen.hafas.de/bin/540/mgate.exe',
        'DB-REGIO-MVV',
        'MuenchenNavigator',
        'd491MVVhz9ZZts23',
        'München Hbf',
      ),
      (
        'nahsh',
        'NAH.SH',
        'https://nahsh.hafas.cloud/gate',
        'NAHSH',
        'NAHSHPROD',
        'r0Ot9FLFNAFxijLW',
        'Kiel Hauptbahnhof',
      ),
      (
        'vbb',
        'VBB',
        'https://fahrinfo.vbb.de/bin/mgate.exe',
        'VBB',
        'VBB WebApp',
        'hafas-vbb-webapp',
        'Berlin Hbf',
      ),
      (
        'vbn',
        'VBN',
        'https://fahrplaner.vbn.de/bin/mgate.exe',
        'VBN',
        'vbn',
        'kaoxIXLn03zCr2KR',
        'Bremen Hbf',
      ),
      (
        'rmv',
        'RMV',
        'https://www.rmv.de/auskunft/bin/jp/mgate.exe',
        'RMV',
        'webapp',
        'x0k4ZR33ICN9CWmj',
        'Frankfurt (Main) Hauptbahnhof',
      ),
      (
        'insa',
        'INSA Sachsen-Anhalt',
        'https://reiseauskunft.insa.de/bin/mgate.exe',
        'NASA',
        'nasaPROD',
        'nasa-apps',
        'Magdeburg Hbf',
      ),
      (
        'vmt',
        'VMT Thüringen',
        'https://vmt.eks-prod-euc1.hafas.cloud/bin/mgate.exe',
        'VMT',
        'webapp',
        'web-vmt-qdr6c6y8s4cvfmfw',
        'Erfurt Hbf',
      ),
      (
        'saarfahrplan',
        'saarVV',
        'https://saarfahrplan.de/bin/mgate.exe',
        'ZPS-SAAR',
        'Saarfahrplan',
        'yCW9qZFSye1wIv3gCzm5r7d2kJ3LIF',
        'Saarbrücken Hbf',
      ),
    ];

Future<Map<String, dynamic>> _hafas(
  String endpoint,
  String clientId,
  String clientName,
  String aid,
  String meth,
  Map<String, dynamic> req,
) async {
  final r = await post(
    endpoint,
    headers: {'Content-Type': 'application/json', 'User-Agent': dbnavUa},
    body: jsonEncode({
      'lang': 'de',
      'svcReqL': [
        {'cfg': {}, 'meth': meth, 'req': req},
      ],
      'client': {
        'id': clientId,
        'type': 'IPH',
        'name': clientName,
        'v': '4000100',
      },
      'ver': '1.34',
      'auth': {'type': 'AID', 'aid': aid},
    }),
  );
  // dart:io — like the app's package:http — does not follow a redirect on a
  // POST. Python's requests did, and so hid that bvg + nahsh had moved their
  // gate (2026-11: 307 → *.hafas.cloud) while the app still posts to the old
  // URL. Name the new location instead of following it.
  if (r.status == 307 ||
      r.status == 308 ||
      r.status == 301 ||
      r.status == 302) {
    throw _Moved(r.header('location') ?? '?');
  }
  r.raiseForStatus();
  final d = r.jsonMap();
  final err = d['err'];
  if (err != null && err != '' && err != 'OK') throw CheckError('$meth $err');
  final svcL = maps(d['svcResL']);
  final svc = svcL.isNotEmpty ? svcL.first : <String, dynamic>{};
  if (svc['err'] != 'OK') throw CheckError('$meth ${svc['err']}');
  final res = svc['res'];
  return res is Map<String, dynamic> ? res : <String, dynamic>{};
}

/// The backend answered with a redirect: its gate moved.
class _Moved implements Exception {
  final String location;
  _Moved(this.location);
  @override
  String toString() => 'moved to $location';
}

String? _hafasPlatform(Map<String, dynamic> stop, String key) {
  final flat = stop['dPlatf$key'];
  if (flat is String && flat.trim().isNotEmpty) return flat.trim();
  final obj = stop['dPltf$key'];
  if (obj is Map) {
    final txt = obj['txt'];
    if (txt is String && txt.isNotEmpty) return txt.trim();
  }
  return null;
}

/// Every regional authority's own backend, which the app trusts over DB for the
/// platform a bus/tram really leaves from
/// (flutter-app/lib/services/regional_profiles.dart). Per backend: the LocMatch
/// → StationBoard shape the app sends and that departures carry the planned
/// platform. Tolerant of individual outages; a majority going dark is a real
/// failure — the protocol moved.
Future<String> checkRegionalPlatformSources() async {
  final ok = <String>[], dead = <String>[], moves = <String>[];
  final relocated = <String>[];
  for (final (pid, _, endpoint, cid, cname, aid, probe) in _regionalProfiles) {
    try {
      final res = await _hafas(endpoint, cid, cname, aid, 'LocMatch', {
        'input': {
          'loc': {'type': 'S', 'name': '$probe?'},
          'maxLoc': 5,
          'field': 'S',
        },
      });
      final locs = maps(mapOf(res, 'match')['locL']);
      if (locs.isEmpty) throw CheckError('kein Halt');
      final now = DateTime.now();
      final board = await _hafas(endpoint, cid, cname, aid, 'StationBoard', {
        'type': 'DEP',
        'date': '${now.year}${two(now.month)}${two(now.day)}',
        'time': '090000',
        'stbLoc': {'extId': locs.first['extId']},
        'maxJny': 60,
      });
      final jny = maps(board['jnyL']);
      final withPf = jny
          .where((j) => _hafasPlatform(mapOf(j, 'stbStop'), 'S') != null)
          .length;
      if (jny.isEmpty) throw CheckError('leere Tafel');
      ok.add('$pid($withPf/${jny.length})');
      for (final j in jny) {
        final st = mapOf(j, 'stbStop');
        final s = _hafasPlatform(st, 'S'), r = _hafasPlatform(st, 'R');
        // Only real moves — "7" → "7 D-G" is the carriage sector being filled
        // in, which the app deliberately does not report.
        if (s != null && r != null && s != r && !r.startsWith(s)) {
          moves.add('$pid $s→$r');
        }
      }
    } on _Moved catch (e) {
      // Not fatal either, but the app needs the new URL.
      dead.add('$pid: $e');
      relocated.add('$pid→${e.location}');
    } catch (e) {
      // One dead backend is not fatal.
      dead.add('$pid: ${clip(e, 40)}');
    }
  }
  final total = _regionalProfiles.length;
  if (ok.length < total ~/ 2) {
    throw CheckError(
      'only ${ok.length}/$total regional backends answered — protocol '
      'changed? ${_pyList(dead.take(4))}',
    );
  }
  var note = '${ok.length}/$total live';
  if (dead.isNotEmpty) {
    note += '; down: ${dead.map((d) => d.split(':').first).join(', ')}';
  }
  if (relocated.isNotEmpty) {
    note += '; umgezogen (App-URL anpassen): ${relocated.join(', ')}';
  }
  if (moves.isNotEmpty) {
    note += '; ${moves.length} echte Gleis-/Steigwechsel z.B. ${moves.first}';
  }
  return note;
}

/// EFA/Mentz backends — the states HAFAS never covered. `plannedPlatformName`
/// vs `platformName` is the same planned/live pair HAFAS calls dPlatfS/dPlatfR.
const _efaProfiles = <(String, String, String, String)>[
  (
    'vvs',
    'VVS Stuttgart',
    'https://www3.vvs.de/mngvvs',
    'Stuttgart Hauptbahnhof',
  ),
  (
    'mvv',
    'MVV München',
    'https://efa.mvv-muenchen.de/ng',
    'München Hauptbahnhof',
  ),
  (
    'vvo',
    'VVO Dresden',
    'https://efa.vvo-online.de/VMSSL3',
    'Dresden Hauptbahnhof',
  ),
  ('vrr', 'VRR', 'https://efa.vrr.de/vrr', 'Essen Hauptbahnhof'),
  ('vrn', 'VRN', 'https://www.vrn.de/mngvrn', 'Mannheim Hauptbahnhof'),
  ('efa-bw', 'bwegt', 'https://www.efa-bw.de/nvbw', 'Stuttgart Hauptbahnhof'),
  (
    'defas',
    'Bayern-Fahrplan',
    'https://mobile.defas-fgi.de/beg',
    'München Hauptbahnhof',
  ),
];

/// The EFA/Mentz half of the regional platform sources (RegionalBackend.efa):
/// XML_STOPFINDER_REQUEST → XML_DM_REQUEST, rapidJSON. Every backend must still
/// answer with departures carrying BOTH `plannedPlatformName` and
/// `platformName`.
Future<String> checkEfaPlatformSources() async {
  final ok = <String>[], dead = <String>[], moved = <String>[];
  const headers = {'Accept': 'application/json', 'User-Agent': dbnavUa};
  for (final (pid, _, base, probe) in _efaProfiles) {
    try {
      final sf = await get(
        '$base/XML_STOPFINDER_REQUEST',
        query: {
          'outputFormat': 'rapidJSON',
          'name_sf': probe,
          'type_sf': 'any',
          'version': '10.2.10.139',
          'coordOutputFormat': 'WGS84[DD.ddddd]',
        },
        headers: headers,
      );
      sf.raiseForStatus();
      final all = maps(sf.jsonMap()['locations']);
      final stopsOnly = all.where((l) => l['type'] == 'stop').toList();
      final locs = stopsOnly.isNotEmpty ? stopsOnly : all;
      if (locs.isEmpty) throw CheckError('stopfinder leer');
      final dm = await get(
        '$base/XML_DM_REQUEST',
        query: {
          'outputFormat': 'rapidJSON',
          'name_dm': locs.first['id'],
          'type_dm': 'stop',
          'mode': 'direct',
          'useRealtime': '1',
          'limit': '30',
          'version': '10.2.10.139',
        },
        headers: headers,
      );
      dm.raiseForStatus();
      final dmJson = dm.jsonMap();
      final events = maps(dmJson['stopEvents']);
      if (events.isEmpty) {
        // "invalid date" (-4001) = the backend's timetable period ran out.
        final msgs = maps(
          dmJson['systemMessages'],
        ).where((m) => m['type'] == 'error').map((m) => m['text']).toList();
        throw CheckError(
          msgs.isNotEmpty ? 'leere Tafel ${_pyList(msgs)}' : 'leere Tafel',
        );
      }
      var both = 0;
      for (final e in events) {
        final props = mapOf(mapOf(e, 'location'), 'properties');
        final planned = props['plannedPlatformName'];
        final live = props['platformName'];
        if (planned is String &&
            planned.isNotEmpty &&
            live is String &&
            live.isNotEmpty) {
          both++;
          if (planned != live && !live.startsWith(planned)) {
            moved.add('$pid $planned→$live');
          }
        }
      }
      if (both == 0) {
        throw CheckError(
          'kein Halt nennt geplant UND live (plannedPlatformName weg?)',
        );
      }
      ok.add('$pid($both/${events.length})');
    } catch (e) {
      // One dead backend is not fatal.
      dead.add('$pid: ${clip(e, 40)}');
    }
  }
  final total = _efaProfiles.length;
  if (ok.length < total ~/ 2) {
    throw CheckError(
      'only ${ok.length}/$total EFA backends answered — rapidJSON shape '
      'changed? ${_pyList(dead.take(3))}',
    );
  }
  var note = '${ok.length}/$total live (${ok.join(', ')})';
  if (dead.isNotEmpty) {
    note += '; down: ${dead.map((d) => d.split(':').first).join(', ')}';
  }
  if (moved.isNotEmpty) {
    note += '; ${moved.length} echte Wechsel z.B. ${moved.first}';
  }
  return note;
}

const _positron = 'https://tiles.openfreemap.org/styles/positron';

/// Outdoor base map: OpenFreeMap "Positron" VECTOR tiles. The style JSON must
/// resolve and its source must advertise .pbf tiles. Soft: on loss the app
/// falls back to the CARTO raster.
Future<String> checkBasemapTiles() async {
  const hdr = {'User-Agent': dbnavUa};
  final style = await get(_positron, headers: hdr);
  style.raiseForStatus();
  final src = mapOf(mapOf(style.jsonMap(), 'sources'), 'openmaptiles');
  final srcUrl = src['url'];
  if ((srcUrl == null || srcUrl == '') && listOf(src, 'tiles').isEmpty) {
    throw CheckError('positron style lost its openmaptiles vector source');
  }
  // Resolve the source TileJSON → it must advertise pbf tile URLs.
  final tj = await get('$srcUrl', headers: hdr);
  tj.raiseForStatus();
  final tiles = listOf(tj.jsonMap(), 'tiles');
  if (tiles.isEmpty || !'${tiles.first}'.contains('.pbf')) {
    throw CheckError('openmaptiles TileJSON has no .pbf tile urls');
  }
  return 'OpenFreeMap Positron ok (vector tiles: '
      '${'${tiles.first}'.split('/data/').last})';
}

/// The offline travel package (#29) rebuilds the basemap Style from a cached
/// copy of the style bundle (style JSON + source TileJSON + sprite JSON +
/// sprite PNG). Every layer must draw from a vector source, the sprite must
/// serve as JSON + PNG, and a real .pbf must resolve through the {z}/{x}/{y}
/// template the prefetcher builds by hand.
Future<String> checkBasemapOfflineBundle() async {
  const hdr = {'User-Agent': dbnavUa};
  final style = await get(_positron, headers: hdr);
  style.raiseForStatus();
  final s = style.jsonMap();

  final sources = mapOf(s, 'sources');
  final vectorNames = {
    for (final e in sources.entries)
      if (e.value is Map && (e.value as Map)['type'] == 'vector') e.key,
  };
  final layerSources = {
    for (final lyr in maps(s['layers']))
      if (lyr['source'] is String && (lyr['source'] as String).isNotEmpty)
        lyr['source'] as String,
  };
  final nonVector = layerSources.difference(vectorNames).toList()..sort();
  if (nonVector.isNotEmpty) {
    throw CheckError(
      'positron layers now draw from non-vector source(s) ${_pyList(nonVector)} '
      '— basemap_style_cache.dart only wires vector sources',
    );
  }

  final sprite = s['sprite'];
  if (sprite == null || sprite == '') {
    throw CheckError(
      'positron style lost its sprite — map icons would vanish offline',
    );
  }
  final sj = await get('$sprite.json', headers: hdr);
  sj.raiseForStatus();
  final icons = sj.json();
  if (icons is! Map || icons.isEmpty) {
    throw CheckError('sprite index is empty or not a JSON object');
  }
  final sp = await get('$sprite.png', headers: hdr);
  sp.raiseForStatus();
  const png = [0x89, 0x50, 0x4E, 0x47];
  final b = sp.bodyBytes;
  if (b.length < 4 || List.generate(4, (i) => b[i]).join() != png.join()) {
    throw CheckError('sprite atlas is not a PNG');
  }

  final tjResp = await get(
    '${mapOf(sources, 'openmaptiles')['url']}',
    headers: hdr,
  );
  tjResp.raiseForStatus();
  final tj = tjResp.jsonMap();
  final tilesL = listOf(tj, 'tiles');
  final template = tilesL.isNotEmpty ? tilesL.first : null;
  if (template is! String || template.isEmpty) {
    throw CheckError('openmaptiles TileJSON has no tile template');
  }
  for (final token in ['{z}', '{x}', '{y}']) {
    if (!template.contains(token)) {
      throw CheckError(
        'tile template lost $token — prefetchVectorTiles substitutes these '
        'by hand',
      );
    }
  }
  // Berlin Hbf at z12 — the exact tile core/offline_package.dart's
  // tileForLatLng test pins, so the two stay in agreement.
  final url = template
      .replaceAll('{z}', '12')
      .replaceAll('{x}', '2200')
      .replaceAll('{y}', '1343');
  final tile = await get(url, headers: hdr);
  tile.raiseForStatus();
  if (tile.bodyBytes.isEmpty)
    throw CheckError('z12 Berlin vector tile is empty');

  final maxzoom = tj['maxzoom'];
  if (maxzoom == null || (maxzoom as num).toInt() < 11) {
    throw CheckError(
      "openmaptiles maxzoom $maxzoom < the offline corridor's z11",
    );
  }

  return 'style bundle ok — ${layerSources.length} vector source(s), sprite '
      '${icons.length} icons + ${sp.bodyBytes.length ~/ 1024} KB atlas, z12 '
      'Berlin pbf ${tile.bodyBytes.length ~/ 1024} KB, maxzoom $maxzoom';
}
