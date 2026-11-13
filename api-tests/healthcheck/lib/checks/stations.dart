import 'dart:convert';
import 'dart:math';

import '../src/core.dart';

/// Checks of group "stations": bahnhof.de station map + sitemap, the map ↔
/// departures links, the HAFAS mirror, the blocked website journey, the gsd
/// seat map and the bahn.de Wagenreihung. Ported from api-tests/healthcheck.py.
final List<Check> stationsChecks = [
  Check(
    'vendo seat map (gsd free seats)',
    checkVendoSeatMap,
    group: 'stations',
  ),
  Check(
    'wagenreihung wing-train split (RE)',
    checkWagenreihungSplit,
    soft: true,
    group: 'stations',
  ),
  Check(
    'wagenreihung transfer sectors (#27)',
    checkWagenreihungTransferSectors,
    soft: true,
    group: 'stations',
  ),
  // Soft: both need the right train on the board right now (a delayed
  // long-distance run / an S-Bahn in a served network), so a quiet board is a
  // skip, not a broken API.
  Check(
    'wagenreihung time-vs-date key (#32)',
    checkWagenreihungTimeKey,
    soft: true,
    group: 'stations',
  ),
  Check(
    'wagenreihung S-Bahn served (#33)',
    checkWagenreihungSbahn,
    soft: true,
    group: 'stations',
  ),
  Check('bahnhof.de station map (karte)', checkBahnhofMap, group: 'stations'),
  Check(
    'map bay ↔ departures link',
    checkBayDepartureLink,
    soft: true,
    group: 'stations',
  ),
  Check(
    'map Gleis ↔ departures (normalised)',
    checkGleisDepartureLink,
    group: 'stations',
  ),
  Check('bahnhof.de sitemap', checkBahnhofSitemap, group: 'stations'),
  Check(
    'HAFAS rest mirror (flaky)',
    checkHafasRest,
    soft: true,
    group: 'stations',
  ),
  Check(
    'website journey blocked check',
    checkWebsiteJourneyStillBlocked,
    soft: true,
    group: 'stations',
  ),
];

const _verbindungMedia = 'application/x.db.vendo.mob.verbindungssuche.v9+json';

// --- Time helpers -------------------------------------------------------------

/// A DB timestamp with offset ("2026-11-13T15:41:00+01:00"). Python's
/// `fromisoformat` keeps the offset, so `.year/.month/.day` and `.date()` are
/// the date as written — not the UTC date. [date] mirrors that.
class _Ts {
  final String raw;
  final DateTime instant;
  _Ts(this.raw) : instant = DateTime.parse(raw);

  String get date => raw.substring(0, 10);

  /// Python: `dt.astimezone(timezone.utc).isoformat().replace("+00:00","Z")`.
  String get utcZ => _utcZ(instant);
}

String _utcZ(DateTime d) {
  final u = d.toUtc();
  final us = u.millisecond * 1000 + u.microsecond;
  final frac = us == 0 ? '' : '.${us.toString().padLeft(6, '0')}';
  return '${u.year.toString().padLeft(4, '0')}-${two(u.month)}-${two(u.day)}'
      'T${two(u.hour)}:${two(u.minute)}:${two(u.second)}${frac}Z';
}

/// Python `datetime.astimezone().isoformat()`: local wall time + offset,
/// microseconds only when non-zero.
String _isoLocal(DateTime d) {
  final l = d.toLocal();
  final us = l.millisecond * 1000 + l.microsecond;
  final frac = us == 0 ? '' : '.${us.toString().padLeft(6, '0')}';
  final off = l.timeZoneOffset;
  final sign = off.isNegative ? '-' : '+';
  final oh = two(off.inHours.abs());
  final om = two(off.inMinutes.abs() % 60);
  return '${l.year.toString().padLeft(4, '0')}-${two(l.month)}-${two(l.day)}'
      'T${two(l.hour)}:${two(l.minute)}:${two(l.second)}$frac$sign$oh:$om';
}

/// `YYYY-MM-DD` + [days].
String _addDays(String date, int days) {
  final d = DateTime.utc(
    int.parse(date.substring(0, 4)),
    int.parse(date.substring(5, 7)),
    int.parse(date.substring(8, 10)),
  ).add(Duration(days: days));
  return ymd(d);
}

/// Python's `repr` of a list of strings: `['1', '2']`.
String _pyList(Iterable<Object?> xs) =>
    '[${xs.map((x) => x is String ? "'$x'" : '$x').join(', ')}]';

/// Python `urllib.parse.quote` (safe='/').
String _quote(String s) {
  const unreserved =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.-~/';
  final b = StringBuffer();
  for (final byte in utf8.encode(s)) {
    final c = String.fromCharCode(byte);
    if (byte < 128 && unreserved.contains(c)) {
      b.write(c);
    } else {
      b.write('%${byte.toRadixString(16).toUpperCase().padLeft(2, '0')}');
    }
  }
  return b.toString();
}

// --- Wagenreihung -------------------------------------------------------------

/// GET the bahn.de vehicle-sequence endpoint over dart:io — the app's own TLS
/// stack. Akamai refuses every Python fingerprint here; dart:io gets through,
/// so no subprocess is needed any more.
Future<Resp> _wagenreihungGet(Map<String, String> params) => get(
  'https://www.bahn.de/web/api/reisebegleitung/wagenreihung/vehicle-sequence',
  query: params,
  headers: browserHeaders(),
);

/// The train's coach sequence at ONE stop, or null when unserved (404).
Future<Map<String, dynamic>?> _wagenreihung(
  String category,
  Object? number,
  String eva,
  _Ts when,
) async {
  final r = await _wagenreihungGet({
    'administrationId': '80',
    'category': category,
    'date': when.date,
    'evaNumber': eva,
    'number': '$number',
    'time': when.utcZ,
  });
  if (r.status == 404) return null;
  r.raiseForStatus();
  return r.jsonMap('vehicle-sequence');
}

List<Map<String, dynamic>> _vehicles(Map<String, dynamic>? seq) => [
  for (final g in maps(seq?['groups'])) ...maps(g['vehicles']),
];

bool _hasMetres(Map<String, dynamic> v) {
  final p = v['platformPosition'];
  if (p is! Map) return false;
  final end = (p['end'] as num?) ?? 0;
  final start = (p['start'] as num?) ?? 0;
  return end - start > 0;
}

/// Vendo journey search (verbindungssuche v9) from [from] to [to] at [when].
Future<List<Map<String, dynamic>>> _search(
  String from,
  String to,
  String when,
) async {
  final r = await post(
    'https://$mobHost/mob/angebote/fahrplan',
    headers: vendoHeaders(_verbindungMedia),
    body: jsonEncode({
      'autonomeReservierung': false,
      'einstiegsTypList': ['STANDARD'],
      'fahrverguenstigungen': {
        'deutschlandTicketVorhanden': false,
        'nurDeutschlandTicketVerbindungen': false,
      },
      'klasse': 'KLASSE_2',
      'reiseHin': {
        'wunsch': {
          'abgangsLocationId': from,
          'alternativeHalteBerechnung': true,
          'verkehrsmittel': ['ALL'],
          'zeitWunsch': {'reiseDatum': when, 'zeitPunktArt': 'ABFAHRT'},
          'zielLocationId': to,
        },
      },
      'reisendenProfil': {
        'reisende': [
          {
            'ermaessigungen': ['KEINE_ERMAESSIGUNG KLASSENLOS'],
            'reisendenTyp': 'ERWACHSENER',
          },
        ],
      },
      'reservierungsKontingenteVorhanden': false,
    }),
  );
  r.raiseForStatus();
  return maps(r.jsonMap()['verbindungen']);
}

List<Map<String, dynamic>> _abschnitte(Map<String, dynamic> c) =>
    maps(mapOf(c, 'verbindung')['verbindungsAbschnitte']);

// --- Station map --------------------------------------------------------------

/// Indoor station map, fetched the way the app does it: the RAW RSC flight
/// stream (`RSC: 1` → `text/x-component`) instead of the full HTML page. We
/// assert the stream still carries everything StationMapService parses, and
/// that the HTML fallback still works.
Future<String> checkBahnhofMap() async {
  final r = await get(
    'https://www.bahnhof.de/hamburg-hbf/karte',
    headers: {...browserHeaders(), 'Accept': '*/*', 'RSC': '1'},
  );
  r.raiseForStatus();
  final ct = r.header('content-type') ?? '';
  if (!ct.contains('x-component')) {
    throw CheckError('RSC fetch did not return a flight stream (ct=$ct)');
  }
  final stream = r.text;
  if (stream.contains('self.__next_f.push')) {
    throw CheckError(
      'RSC fetch returned HTML-wrapped chunks, not a raw '
      "flight stream (app's fast path would no longer apply)",
    );
  }
  if (!stream.contains('"poi":{"')) {
    throw CheckError('no embedded poi object in RSC flight stream');
  }
  for (final cat in ['"PLATFORM"', 'PLATFORM_SECTOR_CUBE']) {
    if (!stream.contains(cat)) {
      throw CheckError('RSC stream missing $cat category');
    }
  }
  if (!stream.contains('"elevator":[') && !stream.contains('"escalator":[')) {
    throw CheckError('RSC stream missing elevator/escalator anchor arrays');
  }
  // Facility status (#73): the app reads each lift/escalator's live state.
  if (!stream.contains('"state":{"type":"')) {
    throw CheckError(
      'RSC stream missing facility state.type '
      '(elevator/escalator status parsing would break, #73)',
    );
  }
  if (!stream.contains('"levelInit"')) {
    throw CheckError('RSC stream missing levelInit');
  }

  final h = await get(
    'https://www.bahnhof.de/hamburg-hbf/karte',
    headers: browserHeaders(),
  );
  h.raiseForStatus();
  if (!h.text.contains(r'"poi\":{\"') && !h.text.contains('"poi":{"')) {
    throw CheckError('HTML fallback no longer embeds the poi object');
  }
  return 'RSC flight stream ok (${stream.length ~/ 1024} KB, '
      'poi+PLATFORM+SECTOR_CUBE+anchors); HTML fallback intact';
}

/// The station map links a tapped bay to live departures by matching the POI's
/// bay label against the board's `gleis`. Soft: the app falls back to all
/// departures when they don't match.
Future<String> checkBayDepartureLink() async {
  final pos = maps(await vendoBoard(kiel));
  final gleise = {
    for (final e in pos)
      if ((e['gleis'] ?? '') != '') '${e['gleis']}',
  };
  final karte = await get(
    'https://www.bahnhof.de/kiel-hbf/karte',
    headers: browserHeaders(),
  );
  karte.raiseForStatus();
  final bays = {
    for (final m in RegExp(r'\[H\]([0-9A-Za-z]+)').allMatches(karte.text))
      m.group(1)!,
  };
  final shared = gleise.intersection(bays);
  if (shared.isEmpty) {
    throw CheckError(
      'no shared bay labels between map and departures '
      '(app will fall back to all-departures view)',
    );
  }
  final sorted = shared.toList()..sort();
  return '${shared.length} bay labels link map↔departures '
      '(e.g. ${_pyList(sorted.take(4))})';
}

/// Mirror the app: drop the platform section suffix → base track id.
String _normGleis(String g) {
  g = g.trim();
  if (g.isEmpty) return g;
  if (RegExp(r'^\d').hasMatch(g))
    return RegExp(r'^\d+').firstMatch(g)!.group(0)!;
  return g.split(RegExp(r'\s+')).first.toUpperCase();
}

/// Tapping a Gleis on the map links to its departures by matching the POI's
/// track number to the board's `gleis` ("6A-C" vs "6", both normalised).
Future<String> checkGleisDepartureLink() async {
  final pos = maps(await vendoBoard('8002549')); // Hamburg Hbf
  final depG = {
    for (final e in pos)
      if ((e['gleis'] ?? '') != '') _normGleis('${e['gleis']}'),
  };
  final karte = await get(
    'https://www.bahnhof.de/hamburg-hbf/karte',
    headers: browserHeaders(),
  );
  karte.raiseForStatus();
  // Decode the RSC stream (same as the app) before matching.
  final blob = RegExp(
    r'self\.__next_f\.push\(\[\d+,("(?:[^"\\]|\\.)*")\]\)',
    dotAll: true,
  ).allMatches(karte.text).map((m) => jsonDecode(m.group(1)!) as String).join();
  final poiTracks = {
    for (final m in RegExp(
      r'"type":"PLATFORM".{0,200}?"name":"([^"]+)"',
    ).allMatches(blob))
      _normGleis(m.group(1)!),
  }..remove('');
  final shared = depG.intersection(poiTracks);
  if (shared.length < 5) {
    final d = depG.toList()..sort();
    final p = poiTracks.toList()..sort();
    throw CheckError(
      'only ${shared.length} normalised tracks align '
      '(dep=${_pyList(d.take(8))} poi=${_pyList(p.take(8))})',
    );
  }
  return '${shared.length} track ids align map↔departures after normalisation';
}

Future<String> checkBahnhofSitemap() async {
  final r = await get(
    'https://www.bahnhof.de/sitemap.xml',
    headers: browserHeaders(),
  );
  r.raiseForStatus();
  final count = '<loc>https://www.bahnhof.de/'.allMatches(r.text).length;
  if (count < 4000) {
    throw CheckError('sitemap only has $count urls (expected >4000)');
  }
  return '$count sitemap urls';
}

/// Community HAFAS mirror — flaky, treated as a soft/degraded check.
Future<String> checkHafasRest() async {
  final r = await get(
    'https://v6.db.transport.rest/locations',
    query: {'query': 'Koeln', 'results': '1'},
    headers: browserHeaders(),
  );
  if (r.status != 200) {
    throw CheckError('HAFAS mirror down (HTTP ${r.status})');
  }
  final data = r.json();
  if (data is! List || data.isEmpty) {
    throw CheckError('HAFAS mirror returned empty');
  }
  return 'HAFAS mirror up (${(data.first as Map)['name']})';
}

/// The website journey POST is Akamai bot-blocked from non-browser clients. We
/// assert it STAYS blocked — if this starts returning data, we can simplify.
Future<String> checkWebsiteJourneyStillBlocked() async {
  final now = DateTime.now();
  final r = await post(
    'https://www.bahn.de/web/api/angebote/fahrplan',
    headers: {...browserHeaders(), 'Content-Type': 'application/json'},
    body: jsonEncode({
      'abfahrtsHalt': kielLoc,
      'ankunftsHalt': berlinLoc,
      'anfrageZeitpunkt': '${ymd(now)}T${hhmm(now)}',
      'ankunftSuche': 'ABFAHRT',
      'klasse': 'KLASSE_2',
      'produktgattungen': ['ICE', 'EC_IC', 'IR', 'REGIONAL', 'SBAHN'],
      'reisende': [
        {
          'typ': 'ERWACHSENER',
          'ermaessigungen': [
            {'art': 'KEINE_ERMAESSIGUNG', 'klasse': 'KLASSENLOS'},
          ],
          'alter': [],
          'anzahl': 1,
        },
      ],
      'schnelleVerbindungen': true,
    }),
  );
  if (r.status == 200 && r.text.contains('verbindungen')) {
    throw CheckError('website journey POST now WORKS — consider using it');
  }
  final reason = r.text.contains('OPS_BLOCKED')
      ? 'OPS_BLOCKED'
      : 'HTTP ${r.status}';
  return 'still unusable as expected ($reason); use vendo instead';
}

// --- Seat map -----------------------------------------------------------------

final _ssrRe = RegExp(r"id='ssr_data'\s*>(.*?)</script>", dotAll: true);

List<Map<String, dynamic>> _coaches(Map<String, dynamic> ssr) => [
  for (final zt in maps(mapOf(ssr, 'zugfahrt')['zugteile']))
    ...maps(zt['wagen']),
];

bool _isFree(Map<String, dynamic> p) => p['status'] == 1 || p['status'] == 2;

String _gsdUrl(Map<String, dynamic> data) =>
    'https://$mobHost/mob/gsd/gsd_v3?data=${_quote(jsonEncode(data))}';

/// Graphical seat display (gsd) — the 'free seats' feature. Drives `gsd_v3`
/// from a journey leg's train number + boarding/alighting EVA + planned times
/// (no auth). Asserts `ssr_data` → coaches → plaetze {status, nummer}, the
/// per-class scoping (#89) and the per-coach geometry endpoint.
Future<String> checkVendoSeatMap() async {
  final conns = await _search(kielLoc, berlinLoc, _isoLocal(DateTime.now()));
  // Every long-distance leg; some units answer gsd_v3 with 409, so try in turn.
  final candidates = [
    for (final c in conns)
      for (final a in _abschnitte(c))
        if ([
          'ICE',
          'IC',
          'EC',
          'ECE',
        ].contains('${a['produktGattung'] ?? ''}'.toUpperCase()))
          a,
  ];
  if (candidates.isEmpty) {
    throw CheckError('no long-distance leg to derive a seat-map request');
  }

  Resp? g;
  Map<String, dynamic> data = {};
  var fahrtNr = '';
  var tried = 0;
  final skipped = <String>[];
  for (final leg in candidates) {
    fahrtNr = '${leg['zugNummer'] ?? leg['verkehrsmittelNummer'] ?? ''}';
    final abEva = '${mapOf(leg, 'abgangsOrt')['evaNr'] ?? ''}';
    final anEva = '${mapOf(leg, 'ankunftsOrt')['evaNr'] ?? ''}';
    // gsd wants naive local time (no offset suffix).
    final abT = '${leg['abgangsDatum'] ?? ''}'.split('+').first;
    final anT = '${leg['ankunftsDatum'] ?? ''}'.split('+').first;
    if ([fahrtNr, abEva, anEva, abT, anT].any((s) => s.isEmpty)) continue;
    tried++;
    data = {
      'buchungskontext': {
        'quellSystem': 'SIMA',
        'buchungsKontextId': uuid4(),
        'buchungsKontextDaten': {
          'zugnummer': fahrtNr,
          'zugfahrtKey': '',
          'abfahrtHalt': {'locationId': abEva, 'abfahrtZeit': abT},
          'ankunftHalt': {'locationId': anEva, 'ankunftZeit': anT},
          'inventarsystem': 'RIFF',
          'platzbedarfe': [
            {
              'platzprofilCode': 'StandardEinzelperson',
              'anzahl': 1.0,
              'klasse': 'KLASSE_2',
            },
          ],
        },
      },
      'correlationID': corrId(),
      'lang': 'de',
      'theme': 'app',
    };
    final resp = await get(_gsdUrl(data), headers: {'User-Agent': dbnavUa});
    if (resp.status == 200 && resp.text.contains("id='ssr_data'")) {
      g = resp;
      break;
    }
    skipped.add('$fahrtNr:${resp.status}');
  }
  if (g == null) {
    throw CheckError(
      'no train exposed a gsd plan across $tried tried '
      '(e.g. ${skipped.take(5).join(', ')})',
    );
  }
  final m = _ssrRe.firstMatch(g.text);
  if (m == null) throw CheckError('gsd_v3 page has no ssr_data blob');
  final coaches = _coaches(jsonDecode(m.group(1)!) as Map<String, dynamic>);
  if (coaches.isEmpty) throw CheckError('gsd ssr_data has no coaches');
  final plaetze0 = maps(coaches.first['plaetze']);
  if (plaetze0.isEmpty ||
      !plaetze0.first.containsKey('status') ||
      !plaetze0.first.containsKey('nummer')) {
    throw CheckError('coach plaetze missing status/nummer');
  }
  // DB status enum: 0=NICHT_AUSWAEHLBAR, 1=AUSWAEHLBAR, 2=VORGESCHLAGEN.
  final all = [for (final w in coaches) ...maps(w['plaetze'])];
  final free = all.where(_isFree).length;
  final total = all.length;
  final unknown = all.map((p) => p['status']).toSet()
    ..removeAll([0, 1, 2, null]);
  if (unknown.isNotEmpty) {
    final u = unknown.toList()..sort((a, b) => '$a'.compareTo('$b'));
    throw CheckError(
      'gsd seat status encoding changed — unexpected ${_pyList(u)} '
      '(app assumes 0=belegt, 1/2=frei; a new code breaks free-seat counts)',
    );
  }

  // First-class cross-fetch (#89): the same leg in KLASSE_1 must answer, and
  // some seats must read free ONLY there.
  final data1 = jsonDecode(jsonEncode(data)) as Map<String, dynamic>;
  final bk = data1['buchungskontext'] as Map<String, dynamic>;
  ((bk['buchungsKontextDaten'] as Map)['platzbedarfe'] as List)
          .first['klasse'] =
      'KLASSE_1';
  bk['buchungsKontextId'] = uuid4();
  data1['correlationID'] = corrId();
  final r1 = await get(_gsdUrl(data1), headers: {'User-Agent': dbnavUa});
  final m1 = _ssrRe.firstMatch(r1.text);
  int? free1;
  int? onlyK1;
  if (r1.status == 200 && m1 != null) {
    final coaches1 = _coaches(jsonDecode(m1.group(1)!) as Map<String, dynamic>);
    if (coaches1.isEmpty) {
      throw CheckError(
        'gsd KLASSE_1 request returned no coaches — first-class seat '
        'inventory gone; merge would drop first class (#89)',
      );
    }
    free1 = [
      for (final w in coaches1) ...maps(w['plaetze']),
    ].where(_isFree).length;
    Set<String> freeIds(List<Map<String, dynamic>> cs) => {
      for (final w in cs)
        for (final p in maps(w['plaetze']))
          if (_isFree(p)) '${w['nummer']}|${p['nummer']}',
    };
    onlyK1 = freeIds(coaches1).difference(freeIds(coaches)).length;
    if (onlyK1 == 0) {
      throw CheckError(
        'gsd free-seat sets are identical across KLASSE_1/KLASSE_2 — the '
        "per-class scoping the app's two-class merge relies on is gone; a "
        'single-class fetch would now wrongly look complete and #89 could '
        'return undetected',
      );
    }
  } else {
    throw CheckError(
      'gsd KLASSE_1 request failed (HTTP ${r1.status}, '
      'ssr_data=${m1 != null ? 'yes' : 'no'}) — first-class seat map broken '
      '(#89)',
    );
  }

  // Per-coach geometry endpoint.
  final wtyp = '${coaches.first['wagentyp'] ?? ''}';
  if (wtyp.isEmpty)
    throw CheckError('coach missing wagentyp for geometry lookup');
  final w = await get(
    'https://$mobHost/mob/gsd/api/wagentypen/${_quote(wtyp)}',
    headers: {'User-Agent': dbnavUa},
  );
  w.raiseForStatus();
  final teile = maps(w.jsonMap()['wagenteile']);
  if (teile.isEmpty || listOf(teile.first, 'elemente').isEmpty) {
    throw CheckError('wagentyp geometry has no elemente');
  }
  final elemente = maps(teile.first['elemente']);
  final el = elemente.first;
  if (!el.containsKey('x') || !el.containsKey('y') || !el.containsKey('type')) {
    throw CheckError('geometry element missing x/y/type');
  }
  return 'zug $fahrtNr: ${coaches.length} coaches, $free/$total free '
      '(K2), $free1 free (K1), $onlyK1 free only in K1, geometry ok '
      '(${elemente.length} elems)';
}

// --- Wagenreihung checks ------------------------------------------------------

/// Wing-train (Flügelzug) coach data, probed on Hamburg → Kiel (the RE7 splits
/// in Neumünster). The vehicle-sequence endpoint must keep returning
/// per-portion `groups` with `transport.destination.name`, the platform sector
/// metres and per-vehicle metre positions. Soft.
Future<String> checkWagenreihungSplit() async {
  final n = DateTime.now();
  final noon = DateTime(
    n.year,
    n.month,
    n.day + 1,
    12,
    0,
    n.second,
    n.millisecond,
    n.microsecond,
  );
  final conns = await _search(hamburgLoc, kielLoc, _isoLocal(noon));
  Map<String, dynamic>? leg;
  for (final c in conns) {
    for (final a in _abschnitte(c)) {
      if (a['typ'] == 'FAHRZEUG' &&
          ['RE', 'RB', 'IRE'].contains(a['kurztext'])) {
        leg = a;
        break;
      }
    }
    if (leg != null) break;
  }
  if (leg == null) throw CheckError('no RE/RB leg in Hamburg→Kiel results');

  final dep = _Ts('${leg['abgangsDatum']}');
  final halte = maps(leg['halte']);
  final eva =
      '${(halte.isEmpty ? null : mapOf(halte.first, 'ort')['evaNr']) ?? '8002549'}';
  final seq = await _wagenreihung(
    '${leg['kurztext']}',
    leg['zugNummer'],
    eva,
    dep,
  );
  if (seq == null) {
    throw CheckError("vehicle-sequence 404 for the RE leg's own origin");
  }
  final groups = maps(seq['groups']);
  if (groups.isEmpty) throw CheckError('vehicle-sequence returned no groups');

  final sectors = maps(mapOf(seq, 'platform')['sectors']);
  if (sectors.isEmpty ||
      sectors.any((s) => s['start'] is! num || s['end'] is! num)) {
    throw CheckError('platform.sectors missing numeric start/end metres');
  }
  if (!_vehicles(seq).any(_hasMetres)) {
    throw CheckError('no vehicle has a metre platformPosition (start<end)');
  }
  final dests = <String>[];
  for (final g in groups) {
    final t = g['transport'];
    if (t is! Map) throw CheckError("group missing 'transport' object");
    final d = mapOf(t, 'destination')['name'];
    if (d != null && '$d'.isNotEmpty) dests.add('$d');
  }
  if (groups.length > 1 && dests.length < 2) {
    throw CheckError('split train but group destinations missing');
  }
  final tag = groups.length > 1 ? ' SPLIT→${dests.join('/')}' : ' (solo)';
  return '${leg['langtext']}: ${groups.length} portion(s)$tag';
}

/// The two facts the transfer section advice stands on (#27): the endpoint
/// serves a train at an INTERMEDIATE stop keyed by its arrival time, and both
/// tracks of one island platform share the same sector letter→metre table.
/// Soft: needs a same-platform transfer in today's results.
Future<String> checkWagenreihungTransferSectors() async {
  final n = DateTime.now();
  final when = DateTime(n.year, n.month, n.day + 1, 9);
  final conns = await _search(hamburgLoc, munichLoc, _isoLocal(when));

  String? intermediateOk;
  String? frameNote;
  for (final c in conns) {
    final all = _abschnitte(c);
    final legs = all.where((x) => x['typ'] == 'FAHRZEUG').toList();
    for (var i = 0; i + 1 < legs.length; i++) {
      final a = legs[i];
      final b = legs[i + 1];
      final aHalte = maps(a['halte']);
      final bHalte = maps(b['halte']);
      if (aHalte.isEmpty || bHalte.isEmpty) continue;
      final stop = aHalte.last;
      final eva = mapOf(stop, 'ort')['evaNr'];
      if (eva == null ||
          '$eva'.isEmpty ||
          mapOf(bHalte.first, 'ort')['evaNr'] != eva) {
        continue; // change between two different stations
      }
      final arrT = stop['ankunftsDatum'];
      final depT = bHalte.first['abgangsDatum'];
      if (arrT == null || depT == null) continue;
      final stopName = mapOf(stop, 'ort')['name'];
      final arr = await _wagenreihung(
        '${a['kurztext']}',
        a['zugNummer'],
        '$eva',
        _Ts('$arrT'),
      );
      if (arr != null && listOf(mapOf(arr, 'platform'), 'sectors').isNotEmpty) {
        intermediateOk =
            '${a['kurztext']} ${a['zugNummer']} mid-run @ '
            '$stopName Gl.${arr['departurePlatform']}';
      }
      final dep = await _wagenreihung(
        '${b['kurztext']}',
        b['zugNummer'],
        '$eva',
        _Ts('$depT'),
      );
      if (arr == null || dep == null) continue;
      final same = all.any(
        (x) =>
            x['typ'] == 'FUSSWEG' &&
            x['weiterfahrtAmGleichenBahnsteig'] == true,
      );
      final ta = {
        for (final s in maps(mapOf(arr, 'platform')['sectors']))
          '${s['name']}': s,
      };
      final tb = {
        for (final s in maps(mapOf(dep, 'platform')['sectors']))
          '${s['name']}': s,
      };
      final shared = ta.keys.toSet().intersection(tb.keys.toSet());
      if (!(same && shared.length >= 2)) continue;
      var worst = 0.0;
      for (final k in shared) {
        final d = max(
          ((ta[k]!['start'] as num) - (tb[k]!['start'] as num)).abs(),
          ((ta[k]!['end'] as num) - (tb[k]!['end'] as num)).abs(),
        ).toDouble();
        if (d > worst) worst = d;
      }
      final glA = arr['departurePlatform'];
      final glB = dep['departurePlatform'];
      if (glA != glB && worst > 15.0) {
        throw CheckError(
          'same-platform Gl.$glA/$glB at $stopName: sector tables disagree by '
          '${worst.toStringAsFixed(1)} m (>15 m) — the shared-frame assumption '
          'behind #27 no longer holds',
        );
      }
      frameNote =
          'Gl.$glA/$glB @ $stopName: ${shared.length} shared sectors '
          'agree within ${worst.toStringAsFixed(1)} m';
      break;
    }
    if (frameNote != null) break;
  }
  if (intermediateOk == null) {
    throw CheckError(
      "no train's Wagenreihung served at a transfer stop "
      'keyed by arrival time (advice would never fire)',
    );
  }
  return [
    'mid-run sequence ok ($intermediateOk)',
    frameNote ?? 'no same-platform pair to measure today',
  ].join('; ');
}

typedef _Delayed = ({
  String cat,
  Object? num,
  _Ts dp,
  _Ts dl,
  double delay,
  String label,
});

/// Board rows whose realtime departure runs >= [minDelay] behind the planned
/// one, most delayed first.
Future<List<_Delayed>> _delayedBoardTrains(
  String eva,
  Set<String> cats, {
  int minDelay = 5,
}) async {
  final out = <_Delayed>[];
  for (final p in maps(await vendoBoard(eva))) {
    final cat = '${p['kurztext'] ?? ''}'.toUpperCase().trim();
    if (!cats.contains(cat)) continue;
    final plan = p['abgangsDatum'];
    final live = p['ezAbgangsDatum'];
    if (plan == null || live == null || '$plan'.isEmpty || '$live'.isEmpty) {
      continue;
    }
    final dp = _Ts('$plan');
    final dl = _Ts('$live');
    final delay = dl.instant.difference(dp.instant).inSeconds / 60;
    if (delay >= minDelay) {
      out.add((
        cat: cat,
        num: p['zugnummer'],
        dp: dp,
        dl: dl,
        delay: delay,
        label: '${p['mitteltext'] ?? '$cat ${p['zugnummer']}'}',
      ));
    }
  }
  out.sort((a, b) => b.delay.compareTo(a.delay));
  return out;
}

List<Object?> _vehicleIds(Resp r) => [
  for (final g in maps(r.jsonMap()['groups']))
    for (final v in maps(g['vehicles'])) v['vehicleID'],
];

/// WHICH parameter selects the run (#32): `time` is ignored, `date` selects.
/// A delayed train must answer the same composition for planned and live time
/// (same day), and the next day's `date` must not serve it. Soft.
Future<String> checkWagenreihungTimeKey() async {
  var delayed = <_Delayed>[];
  var eva = '';
  for (final e in [koelnHbf, '8000105']) {
    eva = e;
    delayed = [
      ...delayed,
      ...await _delayedBoardTrains(e, {'ICE', 'IC', 'EC'}),
    ];
    if (delayed.isNotEmpty) break;
  }
  if (delayed.isEmpty) {
    throw SkipCheck('no delayed long-distance train on the board to probe');
  }
  for (final t in delayed.take(4)) {
    Map<String, String> params(String date, _Ts time) => {
      'administrationId': '80',
      'category': t.cat,
      'date': date,
      'evaNumber': eva,
      'number': '${t.num}',
      'time': time.utcZ,
    };
    final rPlan = await _wagenreihungGet(params(t.dp.date, t.dp));
    if (rPlan.status != 200) continue; // not served here — try the next
    final rLive = await _wagenreihungGet(params(t.dl.date, t.dl));
    final delay = t.delay.toStringAsFixed(0);
    if (t.dl.date == t.dp.date) {
      if (rLive.status != 200) {
        throw CheckError(
          '${t.label} +${delay}min: planned time 200 but live time '
          '${rLive.status} on the SAME service date — `time` '
          "has become a selector; the app's key assumptions (#32) "
          'no longer hold',
        );
      }
      final a = _vehicleIds(rPlan);
      final b = _vehicleIds(rLive);
      var same = a.length == b.length;
      for (var i = 0; same && i < a.length; i++) {
        if (a[i] != b[i]) same = false;
      }
      if (!same) {
        throw CheckError(
          '${t.label} +${delay}min: planned and live time return '
          'DIFFERENT compositions (${a.length} vs ${b.length} cars) — '
          '`time` now selects the run (#32)',
        );
      }
    }
    final rNext = await _wagenreihungGet(params(_addDays(t.dp.date, 1), t.dp));
    final dateMatters = rNext.status != 200;
    return '${t.label} +${delay}min: planned & live time agree '
        '(time ignored); next-day date -> ${rNext.status} '
        '(${dateMatters ? 'date is the selector' : 'date tolerated'})';
  }
  throw SkipCheck('no delayed train that the endpoint actually serves');
}

/// S-Bahnen DO have a Wagenreihung (#33), per network and all-or-nothing.
/// Soft and deliberately weak: asserts that SOME S-Bahn network still serves
/// sequences with metre positions.
Future<String> checkWagenreihungSbahn() async {
  var tried = 0;
  var served = 0;
  final detail = <String>[];
  for (final (name, eva) in [
    ('Rhein-Neckar', '8000156'), // Heidelberg Hbf
    ('Rhein-Ruhr', '8000098'), // Essen Hbf
    ('Nürnberg', '8000284'),
  ]) {
    final rows = maps(await vendoBoard(eva))
        .where(
          (p) =>
              '${p['kurztext'] ?? ''}'.toUpperCase().trim() == 'S' &&
              (p['abgangsDatum'] ?? '') != '',
        )
        .toList();
    for (final p in rows.take(2)) {
      tried++;
      final seq = await _wagenreihung(
        'S',
        p['zugnummer'],
        eva,
        _Ts('${p['abgangsDatum']}'),
      );
      if (seq == null || maps(seq['groups']).isEmpty) continue;
      final cars = _vehicles(seq);
      final positioned = cars.where(_hasMetres).toList();
      if (positioned.isEmpty) continue; // no metres → nothing to draw
      served++;
      detail.add(
        '$name ${p['mitteltext']}: ${cars.length} cars, '
        '${positioned.length} positioned, '
        '${maps(seq['groups']).length} portion(s)',
      );
      break;
    }
    if (served > 0) break;
  }
  if (tried == 0)
    throw SkipCheck('no S-Bahn departures on the boards to probe');
  if (served == 0) {
    throw CheckError(
      'no S-Bahn sequence served across $tried probes in Rhein-Neckar/'
      'Rhein-Ruhr/Nürnberg — the `S` category in '
      'coach_sequence_service.dart now only costs 404s (#33)',
    );
  }
  return detail.join('; ');
}
