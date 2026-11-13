import 'dart:convert';

import '../src/core.dart';

/// Checks of group "mob_journey3": sharing, arrival-anchored searches,
/// pagination, "Weitere Abfahrten" and the train polyline. Ported from
/// api-tests/healthcheck.py.
final List<Check> mobJourney3Checks = [
  Check(
    'vendo journey pagination (context)',
    checkVendoJourneyPagination,
    group: 'mob_journey3',
  ),
  Check(
    'vendo arrival deadline + buffer (Termin)',
    checkVendoArrivalDeadline,
    group: 'mob_journey3',
  ),
  Check(
    'vendo stopover split (Aufenthalt)',
    checkVendoStopoverSplit,
    group: 'mob_journey3',
  ),
  Check(
    'vendo weitere abfahrten (segment)',
    checkVendoWeitereAbfahrten,
    group: 'mob_journey3',
  ),
  Check(
    'vendo share journey (teilen vbid)',
    checkVendoShare,
    group: 'mob_journey3',
  ),
  Check(
    'vendo train polyline (zuglauf)',
    checkVendoTrainPolyline,
    group: 'mob_journey3',
  ),
];

const _searchMedia = 'application/x.db.vendo.mob.verbindungssuche.v9+json';
const _fahrplanUrl = 'https://$mobHost/mob/angebote/fahrplan';

/// `datetime.isoformat()` of a local time WITH its UTC offset, the way the
/// Python probe (and DB Navigator) send `reiseDatum`. Microseconds only when
/// non-zero, like Python.
String _isoLocal(DateTime t) {
  final l = t.toLocal();
  final off = l.timeZoneOffset;
  final sign = off.isNegative ? '-' : '+';
  final oh = two(off.inHours.abs());
  final om = two(off.inMinutes.abs() % 60);
  final frac = (l.millisecond == 0 && l.microsecond == 0)
      ? ''
      : '.${(l.millisecond * 1000 + l.microsecond).toString().padLeft(6, '0')}';
  return '${ymd(l)}T${hhmm(l)}:${two(l.second)}$frac$sign$oh:$om';
}

/// `HH:MM` in local time.
String _hm(DateTime t) => hhmm(t.toLocal());

/// Now plus [d], seconds and sub-seconds cut off (Python's
/// `.replace(second=0, microsecond=0)`).
DateTime _wholeMinute(Duration d) {
  final t = DateTime.now().add(d);
  return DateTime(t.year, t.month, t.day, t.hour, t.minute);
}

/// Python's `str(timedelta)` for a non-negative span: `H:MM:SS`.
String _td(Duration d) =>
    '${d.inHours}:${two(d.inMinutes % 60)}:${two(d.inSeconds % 60)}';

Map<String, dynamic> _searchBody(Map<String, dynamic> wunsch) => {
  'autonomeReservierung': false,
  'einstiegsTypList': ['STANDARD'],
  'fahrverguenstigungen': {
    'deutschlandTicketVorhanden': false,
    'nurDeutschlandTicketVerbindungen': false,
  },
  'klasse': 'KLASSE_2',
  'reiseHin': {'wunsch': wunsch},
  'reisendenProfil': {
    'reisende': [
      {
        'ermaessigungen': ['KEINE_ERMAESSIGUNG KLASSENLOS'],
        'reisendenTyp': 'ERWACHSENER',
      },
    ],
  },
  'reservierungsKontingenteVorhanden': false,
};

/// "Reise teilen": POST a connection's full HAFAS recon ctx (verbindung.kontext,
/// field GH) to /angebote/verbindung/teilen → backend mints a `vbid` that
/// resolves to the EXACT connection. Powers VendoService.shareJourney, which
/// builds https://www.bahn.de/buchung/start?vbid=<vbid>. We first search to get
/// a fresh kontext (recon strings are time-bound), then share it.
Future<String> checkVendoShare() async {
  final sr = await post(
    _fahrplanUrl,
    headers: vendoHeaders(_searchMedia),
    body: jsonEncode(
      _searchBody({
        'abgangsLocationId': kielLoc,
        'alternativeHalteBerechnung': true,
        'verkehrsmittel': ['ALL'],
        'zeitWunsch': {
          'reiseDatum': _isoLocal(DateTime.now()),
          'zeitPunktArt': 'ABFAHRT',
        },
        'zielLocationId': berlinLoc,
      }),
    ),
  );
  sr.raiseForStatus();
  final conns = listOf(sr.json(), 'verbindungen');
  if (conns.isEmpty) throw CheckError('no verbindungen to share');
  final vb = mapOf(conns.first, 'verbindung');
  final recon = vb['kontext'] as String?;
  if (recon == null || recon.isEmpty || !recon.contains('¶')) {
    throw CheckError('first verbindung carries no recon kontext');
  }

  const shareMedia = 'application/x.db.vendo.mob.verbindungteilen.v1+json';
  final abschnitte = maps(vb['verbindungsAbschnitte']);
  final hd = abschnitte.isNotEmpty ? abschnitte.first['abgangsDatum'] : null;
  final r = await post(
    'https://$mobHost/mob/angebote/verbindung/teilen',
    headers: vendoHeaders(shareMedia),
    body: jsonEncode({
      'GH': recon,
      'HD': hd,
      'SO': 'Kiel Hbf',
      'ZO': 'Berlin Hbf',
    }),
  );
  if (r.status != 200 && r.status != 201) {
    throw CheckError('teilen HTTP ${r.status}');
  }
  final vbid = (r.json() as Map?)?['vbid'] as String?;
  if (vbid == null || vbid.isEmpty) {
    throw CheckError('teilen response has no vbid');
  }

  // …and back again: a pasted share link has to resolve to the very same
  // connection, which is what the manual split-ticket entry runs (#44).
  // GET the share record for its recon ctx, then replay that ctx through
  // /angebote/recon. (The old path went via www.bahn.de/web/api, which
  // Akamai blocks — every pasted link failed.)
  final lookup = await get(
    'https://$mobHost/mob/angebote/verbindung/$vbid',
    headers: vendoHeaders(shareMedia),
  );
  if (lookup.status != 200) {
    throw CheckError('share lookup HTTP ${lookup.status}');
  }
  final back = (lookup.json() as Map?)?['GH'] as String?;
  if (back == null || back.isEmpty || !back.contains('¶')) {
    throw CheckError('share lookup carries no recon ctx (GH)');
  }
  final rr = await post(
    'https://$mobHost/mob/angebote/recon',
    headers: vendoHeaders(_searchMedia),
    body: jsonEncode({
      'autonomeReservierung': false,
      'einstiegsTypList': ['STANDARD'],
      'fahrverguenstigungen': {
        'deutschlandTicketVorhanden': false,
        'nurDeutschlandTicketVerbindungen': false,
      },
      'klasse': 'KLASSE_2',
      // NB `verbindungHin.kontext` — `ctxRecon`/`hinfahrtRecon` (the
      // website's spelling) are answered 400 VALIDIERUNG.
      'verbindungHin': {'kontext': back},
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
  if (rr.status != 200) throw CheckError('recon HTTP ${rr.status}');
  final reconData = rr.jsonMap('recon response');
  final legs = listOf(mapOf(reconData, 'verbindung'), 'verbindungsAbschnitte');
  if (legs.isEmpty) {
    throw CheckError(
      'recon response has no verbindungsAbschnitte (shape changed)',
    );
  }
  if (!reconData.containsKey('angebote')) {
    throw CheckError('recon response carries no angebote (no price)');
  }
  final short = vbid.length > 8 ? vbid.substring(0, 8) : vbid;
  return 'vbid minted ($short…) → bahn.de/buchung/start?vbid=…; '
      'resolves back to ${legs.length} leg(s) with prices';
}

/// One `zeitPunktArt: ANKUNFT` journey search — the request both the
/// Termin-Modus and the Aufenthalt plan are built on.
Future<Map<String, dynamic>> _arrivalSearch(
  String abgang,
  String ziel,
  DateTime arriveBy, {
  String? context,
}) async {
  final wunsch = <String, dynamic>{
    'abgangsLocationId': abgang,
    'alternativeHalteBerechnung': true,
    'verkehrsmittel': ['ALL'],
    'zeitWunsch': {
      'reiseDatum': _isoLocal(arriveBy),
      'zeitPunktArt': 'ANKUNFT',
    },
    'zielLocationId': ziel,
  };
  if (context != null && context.isNotEmpty) wunsch['context'] = context;
  final res = await post(
    _fahrplanUrl,
    headers: vendoHeaders(_searchMedia),
    body: jsonEncode(_searchBody(wunsch)),
  );
  res.raiseForStatus();
  return res.jsonMap('arrival search');
}

/// (departure, arrival) of a whole connection, as the app reads them.
(DateTime?, DateTime?) _connTimes(dynamic conn) {
  final abschnitte = maps(mapOf(conn, 'verbindung')['verbindungsAbschnitte']);
  DateTime? dep;
  DateTime? arr;
  for (final a in abschnitte) {
    final s = a['abgangsDatum'];
    if (s is String && s.isNotEmpty && dep == null) dep = DateTime.parse(s);
  }
  for (final a in abschnitte.reversed) {
    final s = a['ankunftsDatum'];
    if (s is String && s.isNotEmpty) {
      arr = DateTime.parse(s);
      break;
    }
  }
  return (dep, arr);
}

DateTime _minOf(Iterable<DateTime> xs) =>
    xs.reduce((a, b) => a.isBefore(b) ? a : b);
DateTime _maxOf(Iterable<DateTime> xs) =>
    xs.reduce((a, b) => a.isAfter(b) ? a : b);

/// "Ich muss um 09:48 da sein" (Termin-Modus): an ANKUNFT search must return
/// connections that get in BY the requested time, and `frueherContext` must
/// page to ones that get in EARLIER — that is the whole mechanism behind the
/// buffer filter (`utils/arrival_buffer.dart`, `setMinBufferMinutes`). If the
/// backend ever answered an arrival wish with a departure window, every buffer
/// shown in the app would be wrong, and the "mind. X min Puffer" filter would
/// page backwards forever.
Future<String> checkVendoArrivalDeadline() async {
  final deadline = _wholeMinute(const Duration(hours: 8));
  final data = await _arrivalSearch(kielLoc, berlinLoc, deadline);
  final conns = listOf(data, 'verbindungen');
  if (conns.isEmpty) {
    throw CheckError('arrival search returned no connections');
  }

  final arrivals = [
    for (final c in conns)
      if (_connTimes(c).$2 case final a?) a,
  ];
  if (arrivals.isEmpty) {
    throw CheckError('no connection carries a final ankunftsDatum');
  }
  final inTime = arrivals.where((a) => !a.isAfter(deadline)).toList();
  if (inTime.isEmpty) {
    throw CheckError(
      'every connection arrives AFTER the requested ${_hm(deadline)} '
      '(earliest ${_hm(_minOf(arrivals))}) — arrival wish ignored?',
    );
  }
  // The tight-answer premise the feature exists for: DB's own best answer sits
  // just before the deadline, so the app has to offer the earlier ones itself.
  final latest = _maxOf(inTime);
  final bufferMin = deadline.difference(latest).inSeconds ~/ 60;

  final tok = data['frueherContext'] as String?;
  if (tok == null || tok.isEmpty) {
    throw CheckError(
      'no frueherContext on an arrival search — the buffer '
      'filter could not widen its window',
    );
  }
  final earlier = await _arrivalSearch(
    kielLoc,
    berlinLoc,
    deadline,
    context: tok,
  );
  final eArrivals = [
    for (final c in listOf(earlier, 'verbindungen'))
      if (_connTimes(c).$2 case final a?) a,
  ];
  if (eArrivals.isEmpty) {
    throw CheckError('frueherContext page carries no arrivals');
  }
  final baseMin = _minOf(arrivals);
  final pageMin = _minOf(eArrivals);
  if (!pageMin.isBefore(baseMin)) {
    throw CheckError(
      'earlier page is not earlier (base ${_hm(baseMin)}, '
      'page ${_hm(pageMin)}) — more buffer unreachable',
    );
  }
  final gained = baseMin.difference(pageMin).inSeconds ~/ 60;
  return 'ANKUNFT honoured: ${inTime.length}/${arrivals.length} arrive by '
      '${_hm(deadline)} (tightest leaves $bufferMin min); '
      'frueher adds $gained min more buffer';
}

/// "Aufenthalt einplanen" end to end (`utils/stopover_plan.dart`): two
/// INDEPENDENT arrival searches joined at a hub — hub→goal by the appointment,
/// then home→hub by "that train leaves minus the stay". The point is a gap DB's
/// own chained search would never offer, so this asserts the gap really comes
/// out the far end.
Future<String> checkVendoStopoverSplit() async {
  const stay = Duration(minutes: 60);
  final deadline = _wholeMinute(const Duration(hours: 10));

  // Leg 2: Hamburg → Berlin, nailed to the appointment.
  final second = await _arrivalSearch(hamburgLoc, berlinLoc, deadline);
  final candidates = <(DateTime, DateTime)>[
    for (final c in listOf(second, 'verbindungen'))
      if (_connTimes(c) case (final d?, final a?) when !a.isAfter(deadline))
        (d, a),
  ];
  if (candidates.isEmpty) {
    throw CheckError(
      'no Hamburg→Berlin connection arrives by ${_hm(deadline)}',
    );
  }
  final pick = candidates.reduce((x, y) => y.$1.isAfter(x.$1) ? y : x);
  final hubDep = pick.$1;
  final hubArr = pick.$2;

  // Leg 1: Kiel → Hamburg, has to be in an hour before that train goes.
  final target = hubDep.subtract(stay);
  final first = await _arrivalSearch(kielLoc, hamburgLoc, target);
  final stays = <Duration>[
    for (final c in listOf(first, 'verbindungen'))
      if (_connTimes(c).$2 case final a? when !a.isAfter(hubDep))
        hubDep.difference(a),
  ];
  if (stays.isEmpty) {
    throw CheckError('no Kiel→Hamburg connection lands before ${_hm(hubDep)}');
  }
  final qualifying = stays.where((s) => s >= stay).toList();
  if (qualifying.isEmpty) {
    final best = stays.reduce((a, b) => a > b ? a : b);
    throw CheckError(
      'no Kiel→Hamburg arrival leaves the wanted 60 min at the hub '
      '(best ${_td(best)}) — an ANKUNFT search for ${_hm(target)} '
      'returned only later trains',
    );
  }
  final best = qualifying.reduce((a, b) => a > b ? a : b);
  return 'split ok: Berlin by ${_hm(deadline)} → Hamburg dep '
      '${_hm(hubDep)} (in ${_hm(hubArr)}); '
      '${qualifying.length} Kiel→Hamburg option(s) with ≥60 min stay '
      '(up to ${best.inSeconds ~/ 60} min)';
}

/// Earlier/later buttons: the journey response carries frueherContext/
/// spaeterContext tokens; replaying one in reiseHin.wunsch.context scrolls the
/// window. Verify the token comes back and earlier actually returns earlier
/// departures (powers loadEarlier/loadLater in journey_search_provider).
Future<String> checkVendoJourneyPagination() async {
  Map<String, dynamic> body([String? context]) {
    final wunsch = <String, dynamic>{
      'abgangsLocationId': kielLoc,
      'alternativeHalteBerechnung': true,
      'verkehrsmittel': ['ALL'],
      'zeitWunsch': {
        'reiseDatum': _isoLocal(DateTime.now()),
        'zeitPunktArt': 'ABFAHRT',
      },
      'zielLocationId': berlinLoc,
    };
    if (context != null && context.isNotEmpty) wunsch['context'] = context;
    return _searchBody(wunsch);
  }

  String? firstDep(Map<String, dynamic> d) {
    final c = listOf(d, 'verbindungen');
    if (c.isEmpty) return null;
    final abschnitte = maps(
      mapOf(c.first, 'verbindung')['verbindungsAbschnitte'],
    );
    if (abschnitte.isEmpty) return null;
    return abschnitte.first['abgangsDatum'] as String?;
  }

  final base = await post(
    _fahrplanUrl,
    headers: vendoHeaders(_searchMedia),
    body: jsonEncode(body()),
  );
  base.raiseForStatus();
  final bd = base.jsonMap('journey response');
  final tok = bd['frueherContext'] as String?;
  if (tok == null || tok.isEmpty) {
    throw CheckError('no frueherContext token in journey response');
  }
  final earlier = await post(
    _fahrplanUrl,
    headers: vendoHeaders(_searchMedia),
    body: jsonEncode(body(tok)),
  );
  earlier.raiseForStatus();
  final ed = earlier.jsonMap('earlier response');
  final b0 = firstDep(bd);
  final e0 = firstDep(ed);
  if (e0 == null ||
      e0.isEmpty ||
      b0 == null ||
      b0.isEmpty ||
      e0.compareTo(b0) >= 0) {
    throw CheckError(
      'earlier ctx did not return earlier trains (base=$b0, earlier=$e0)',
    );
  }
  return 'pagination ok (base ${b0.substring(11, 16)} -> earlier '
      '${e0.substring(11, 16)})';
}

/// Every produktGattungen code `VendoService.produktGattungenFor` can send.
/// The endpoint validates the string against its own enum and answers 400
/// VALIDIERUNG for anything outside it — it does NOT ignore unknown values — so
/// a wrong code means "Weitere Abfahrten" is dead for that product, silently.
/// The app long sent `EC_IC` (live spelling: `IC_EC`), `U` (wants `UBAHN`) and
/// an invented `ALL` catch-all, which 400'd every IC/EC and U-Bahn leg.
const weitereAbfahrtenGattungen = [
  'ICE',
  'IC_EC',
  'RB',
  'SBAHN',
  'BUS',
  'UBAHN',
  'STR',
  'SCHIFF',
];

Future<Resp> _weitereAbfahrten(
  String abgang,
  String ziel,
  String gattung, {
  int hours = 4,
}) {
  final ankunft = _isoLocal(DateTime.now().add(Duration(hours: hours)));
  return post(
    'https://$mobHost/mob/trip/weitereabfahrten',
    headers: vendoHeaders(_searchMedia),
    body: jsonEncode({
      'wunsch': {
        'abgangsLocationId': abgang,
        'alternativeHalteBerechnung': true,
        'fahrradmitnahme': false,
        'produktGattungen': gattung,
        'zeitWunsch': {'reiseDatum': ankunft, 'zeitPunktArt': 'ANKUNFT'},
        'zielLocationId': ziel,
      },
    }),
  );
}

/// "Weitere Abfahrten": alternative trains of one product group on a direct
/// segment, anchored on arrival. POST /mob/trip/weitereabfahrten. NB the
/// response puts verbindungsAbschnitte DIRECTLY on each connection (no
/// `verbindung` wrapper, unlike /angebote/fahrplan) — the app relies on that.
///
/// Also asserts every product code the app maps to is still inside the
/// endpoint's enum: a rejected code takes the whole switcher down for that
/// product, and an empty result set looks exactly the same from the UI.
Future<String> checkVendoWeitereAbfahrten() async {
  final rejected = <String>[];
  for (final gattung in weitereAbfahrtenGattungen) {
    final r = await _weitereAbfahrten(berlinHbf, hamburgLoc, gattung);
    if (r.status != 200) rejected.add('$gattung→${r.status}');
  }
  if (rejected.isNotEmpty) {
    throw CheckError('produktGattungen rejected: ${rejected.join(', ')}');
  }

  // Berlin→Hamburg by ICE: the one pair/product that always has alternatives
  // to page through. (Kiel→Hamburg "RB" used to be the probe and now returns
  // an empty list — the direct trains there are REs, which live in `RB` only
  // nominally.)
  final r = await _weitereAbfahrten(berlinHbf, hamburgLoc, 'ICE');
  r.raiseForStatus();
  final conns = listOf(r.json(), 'verbindungen');
  if (conns.isEmpty) throw CheckError('no verbindungen returned');
  final c = conns.first;
  // the un-wrapped shape the app's _parseConnection now falls back to
  final legs = maps(c is Map ? c['verbindungsAbschnitte'] : null);
  if (legs.isEmpty) {
    throw CheckError(
      'connection has no verbindungsAbschnitte (response shape changed)',
    );
  }
  final halte = maps(legs.first['halte']);
  if (halte.length < 2) throw CheckError('first leg has no halte');
  final dep = '${halte.first['abgangsDatum'] ?? ''}';
  final hm = dep.length >= 16 ? dep.substring(11, 16) : '';
  return '${conns.length} alt departures, first $hm '
      '(${halte.length} halte); '
      '${weitereAbfahrtenGattungen.length} produktGattungen accepted';
}

/// GET /mob/zuglauf/{id} — the exact track geometry DB Navigator draws on its
/// map (polylineGroup.polylineDesc[].coordinates). Powers the app's route map
/// (services/vendo_service.fetchTripPolyline). Id is a vendo `zuglaufId` —
/// here taken from the departure board (a vendo leg carries the same string).
Future<String> checkVendoTrainPolyline() async {
  final pos = await vendoBoard(berlinHbf);
  if (pos.isEmpty) throw CheckError('no departures to derive a zuglaufId');
  final jid = '${(pos.first as Map)['zuglaufId']}';

  final r = await get(
    'https://$mobHost/mob/zuglauf/${Uri.encodeComponent(jid)}',
    headers: vendoHeaders(zuglaufMedia),
  );
  r.raiseForStatus();
  final data = r.json();
  final descs = maps(mapOf(data, 'polylineGroup')['polylineDesc']);
  final pts = [for (final d in descs) ...maps(d['coordinates'])];
  if (pts.isEmpty)
    throw CheckError('no polylineGroup.polylineDesc coordinates');
  final first = pts.first;
  if (!first.containsKey('latitude') || !first.containsKey('longitude')) {
    throw CheckError('coordinate missing latitude/longitude');
  }
  return '${pts.length} track points (first ${first['latitude']},'
      '${first['longitude']})';
}
