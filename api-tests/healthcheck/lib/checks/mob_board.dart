import 'dart:async';
import 'dart:io';

import 'package:xml/xml.dart';

import '../src/core.dart';

/// Checks of group "mob_board": the board, train runs, location search and the
/// /mob surface. Ported from api-tests/healthcheck.py.
final List<Check> mobBoardChecks = [
  Check(
    'bahn.de web API blocked (reiseloesung)',
    checkBahnWebApiBlocked,
    soft: true,
    group: 'mob_board',
  ),
  Check(
    'vendo departures (bahnhofstafel)',
    checkVendoDepartures,
    group: 'mob_board',
  ),
  Check(
    'vendo Ticket hinzufügen (manuellLaden)',
    checkVendoManuellLaden,
    group: 'mob_board',
  ),
  Check(
    'vendo arrivals (bahnhofstafel)',
    checkVendoArrivals,
    group: 'mob_board',
  ),
  Check(
    'vendo board semantics (gattung/cancel)',
    checkVendoBoardSemantics,
    group: 'mob_board',
  ),
  Check(
    'IRIS plan via stops (board "Über")',
    checkIrisBoardVia,
    group: 'mob_board',
  ),
  Check(
    'vendo train run (zuglauf halte)',
    checkVendoZuglaufDetail,
    group: 'mob_board',
  ),
  Check(
    'vendo platform change (gleis vs ezGleis)',
    checkVendoPlatformChange,
    soft: true,
    group: 'mob_board',
  ),
  Check(
    'vendo zuglauf notes (Umleitung/Zusatzhalt)',
    checkVendoZuglaufNotes,
    group: 'mob_board',
  ),
  Check('vendo location search', checkVendoLocation, group: 'mob_board'),
  Check(
    'vendo nearby stations (bytypes)',
    checkVendoNearby,
    group: 'mob_board',
  ),
  Check(
    'mob endpoint surface reachable (67)',
    checkMobSurface,
    soft: true,
    group: 'mob_board',
  ),
];

/// POST /mob/bahnhofstafel/abfahrt — the departure board (replaces the
/// blocked bahn.de abfahrten). Powers the Abfahrtstafel + train-by-number.
Future<String> checkVendoDepartures() async {
  final pos = await vendoBoard(koelnHbf);
  if (pos.isEmpty) throw CheckError('no departure positions');
  final e = pos.first as Map<String, dynamic>;
  for (final key in ['zuglaufId', 'abgangsDatum']) {
    if (!e.containsKey(key)) {
      throw CheckError("departure position missing '$key'");
    }
  }
  if ((e['mitteltext'] ?? '') == '' && (e['kurztext'] ?? '') == '') {
    throw CheckError('departure position has no line text');
  }
  return "${pos.length} departures, first '${e['mitteltext'] ?? '?'}' → "
      "${e['richtung'] ?? '?'}, zuglaufId len=${'${e['zuglaufId']}'.length}";
}

/// POST /mob/auftrag/{nr}/manuellLaden — "Ticket hinzufügen" (order number +
/// surname, no login). An unknown number must come back as a typed 404
/// AUFTRAG_NICHT_GEFUNDEN and a malformed one as 400 VALIDIERUNG — the app maps
/// exactly those to user text. A real order answers 200 with
/// `auftragsbezogeneReisen[]` (same shape as GET …/kundenwunsch) plus
/// `anonymerZugriff.accessToken`; no public test order exists for that path.
Future<String> checkVendoManuellLaden() async {
  final r = await mobPost('auftrag/990000000001/manuellLaden', auftragMedia, {
    'nachname': 'Mustermann',
  });
  if (r.status != 404) {
    throw CheckError(
      'unknown order: expected 404, got ${r.status}: ${clip(r.text)}',
    );
  }
  final typ = mapOf(r.json(), 'details')['typ'];
  if (typ != 'AUFTRAG_NICHT_GEFUNDEN' && typ != 'AUFTRAG_NOT_FOUND') {
    throw CheckError('unknown order: unexpected details.typ $typ');
  }
  final r2 = await mobPost('auftrag/ABC123/manuellLaden', auftragMedia, {
    'nachname': 'Mustermann',
  });
  if (r2.status != 400 || (r2.json() as Map?)?['code'] != 'VALIDIERUNG') {
    throw CheckError(
      'bad order number: expected 400 VALIDIERUNG, got ${r2.status}: '
      '${clip(r2.text)}',
    );
  }
  return 'unknown order → 404 $typ, malformed → 400 VALIDIERUNG';
}

/// The bahn.de website `reiseloesung/*` GET API (orte/abfahrten/ankuenfte/
/// fahrt) is Akamai bot-blocked (OPS_BLOCKED) as of 2026-07-09 — the app moved
/// off it onto the DB Vendo `/mob` backend. Assert it STAYS blocked so we
/// notice (and could simplify) if DB ever reopens it. Soft: a transient 200
/// shouldn't fail CI.
Future<String> checkBahnWebApiBlocked() async {
  final now = DateTime.now();
  final r = await get(
    'https://www.bahn.de/web/api/reiseloesung/abfahrten',
    query: {
      'datum': ymd(now),
      'zeit': '${hhmm(now)}:00',
      'ortExtId': koelnHbf,
      'mitVias': 'false',
    },
    headers: browserHeaders(),
  );
  // Informational. Python saw OPS_BLOCKED here for months; over dart:io (the
  // app's stack) it answers 200 since at least 2026-11-13 — the block was on
  // the Python fingerprint. The app stays on vendo either way.
  if (r.status == 403 || r.text.contains('OPS_BLOCKED')) {
    return 'reiseloesung Akamai-blocked for dart:io — app uses vendo';
  }
  return 'reiseloesung reachable over dart:io (HTTP ${r.status}) — app '
      'still uses vendo';
}

/// The wall-clock of an ISO timestamp as `yyMMddHHmm`, in the timestamp's own
/// offset (no conversion — what Python's `fromisoformat().strftime` gives).
String? _yyMMddHHmm(String iso) {
  final m = RegExp(r'^\d\d(\d\d)-(\d\d)-(\d\d)T(\d\d):(\d\d)').firstMatch(iso);
  if (m == null) return null;
  return '${m[1]}${m[2]}${m[3]}${m[4]}${m[5]}';
}

/// GET iris.noncd.db.de/iris-tts/timetable/plan/{eva}/{yymmdd}/{hh} — the
/// station plan feed. It is the only cheap source of the "Über" stops the app
/// shows under each board row: the Vendo bahnhofstafel carries just `richtung`,
/// and a `zuglauf` per row would be ~37 KB each (and a fast way into a 429).
///
/// Checked here: the XML still has <s><tl n=…> plus a <dp>/<ar> with `pt` and
/// a pipe-separated `ppth`, AND that at least one plan entry still lines up
/// with a Vendo board row on train number + planned minute — that pairing is
/// what puts the stops on the right row.
Future<String> checkIrisBoardVia() async {
  final now = DateTime.now();
  final yymmdd = ymd(now).substring(2).replaceAll('-', '');
  final r = await get(
    'https://iris.noncd.db.de/iris-tts/timetable/plan/$koelnHbf/'
    '$yymmdd/${two(now.hour)}',
    headers: {'Accept': 'application/xml'},
  );
  r.raiseForStatus();
  final root = XmlDocument.parse(r.text).rootElement;
  final runs = <String, List<String>>{};
  for (final s in root.findElements('s')) {
    final tl = s.getElement('tl');
    final nr = (tl?.getAttribute('n') ?? '').trim();
    final dp = s.getElement('dp');
    if (nr.isEmpty || dp == null) continue;
    final pt = dp.getAttribute('pt');
    final ppth = dp.getAttribute('ppth');
    if (pt == null || pt.isEmpty || ppth == null || ppth.isEmpty) continue;
    runs['$nr|$pt'] = ppth.split('|');
  }
  if (runs.isEmpty) {
    throw CheckError('IRIS plan has no <s><dp pt= ppth=> entries');
  }

  // Cross-check against the board the app actually renders.
  var paired = 0;
  for (final p in maps(await vendoBoard(koelnHbf))) {
    final planned = '${p['abgangsDatum'] ?? ''}';
    final z = p['zugnummer'];
    final nr = z == null || z == '' || z == 0 ? '' : '$z';
    if (planned.isEmpty || nr.isEmpty) continue;
    final minute = _yyMMddHHmm(planned);
    if (minute != null && runs.containsKey('$nr|$minute')) paired++;
  }
  if (paired == 0) {
    throw CheckError(
      'no Vendo board row matches an IRIS plan entry on '
      "(zugnummer, planned minute) — the 'Über' column would stay empty",
    );
  }
  return '${runs.length} IRIS runs, $paired matched to board rows';
}

/// Python-style dict rendering: {'ICE': 12, 'RE': 5}.
String _pyDict(Iterable<MapEntry<String, int>> entries) =>
    '{${entries.map((e) => "'${e.key}': ${e.value}").join(', ')}}';

/// The two board fields the app derives meaning from, rather than shows.
///
/// `produktGattung` decides the IC/EC filter and the drawn train geometry —
/// live it reads `IC_EC` (the app long had only the never-sent `EC_IC`, so
/// every IC was categorised as regional). And a cancelled row is signalled
/// *only* by the realtime note "Halt entfällt"; the board carries no flag, so
/// the app matches on text. Both are DB's to change, hence a check.
///
/// Soft on the cancellation note: a board with nothing cancelled is a good
/// day, not a broken API.
Future<String> checkVendoBoardSemantics() async {
  final gattungen = <String, int>{};
  final notes = <String, int>{};
  for (final eva in [koelnHbf, '8011160']) {
    // Köln, Berlin Hbf
    for (final p in maps(await vendoBoard(eva))) {
      final g = p['produktGattung'];
      if (g is String && g.isNotEmpty) gattungen[g] = (gattungen[g] ?? 0) + 1;
      for (final n in maps(p['echtzeitNotizen'])) {
        final t = n['text'];
        if (t is String && t.isNotEmpty) notes[t] = (notes[t] ?? 0) + 1;
      }
    }
  }

  if (gattungen.isEmpty) throw CheckError('no produktGattung on any board row');
  // The app maps these explicitly; anything else silently becomes 'regional'.
  const known = {
    'ICE', 'IC_EC', 'IR', 'RB', 'RE', 'REGIONAL', 'SBAHN', 'S', //
    'BUS', 'SONSTIGE', 'UBAHN', 'U', 'STR', 'TRAM', 'SCHIFF',
    'IC', 'EC', 'EC_IC',
  };
  final unknown = gattungen.entries.where((e) => !known.contains(e.key));
  if (unknown.isNotEmpty) {
    throw CheckError(
      'unmapped produktGattung ${_pyDict(unknown)} — _mapProduct would call '
      "these 'regional'; add them to the switch",
    );
  }

  var cancels = 0;
  notes.forEach((t, c) {
    final l = t.toLowerCase();
    if (l.contains('entfällt') || l.contains('fällt aus')) cancels += c;
  });
  final top = gattungen.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  final total = gattungen.values.fold<int>(0, (a, b) => a + b);
  return '$total rows, gattungen ${_pyDict(top.take(4))}, '
      '$cancels cancelled notes';
}

/// POST /mob/bahnhofstafel/ankunft — the arrival board. Each position adds
/// `abgangsOrt` (origin) which the board renders as "von …".
Future<String> checkVendoArrivals() async {
  final pos = maps(await vendoBoard(koelnHbf, arrivals: true));
  if (pos.isEmpty) throw CheckError('no arrival positions');
  final e = pos.first;
  if (!e.containsKey('ankunftsDatum') || !e.containsKey('zuglaufId')) {
    throw CheckError('arrival position missing ankunftsDatum/zuglaufId');
  }
  final origin = mapOf(e, 'abgangsOrt')['name'] ?? '?';
  return "${pos.length} arrivals, first from '$origin'";
}

/// A zuglaufId from the Köln board, long-distance preferred.
Future<String> _boardZuglaufId() async {
  final pos = maps(await vendoBoard(koelnHbf));
  if (pos.isEmpty) throw CheckError('no departures to derive a zuglaufId');
  final ld = pos.where(
    (p) => const {'ICE', 'IC', 'EC'}.contains(p['produktGattung']),
  );
  return '${(ld.isNotEmpty ? ld.first : pos.first)['zuglaufId']}';
}

Future<Map<String, dynamic>> _zuglauf(String zid) async {
  final r = await mobGet('zuglauf/${Uri.encodeComponent(zid)}', zuglaufMedia);
  r.raiseForStatus();
  return r.jsonMap('zuglauf');
}

/// GET /mob/zuglauf/{zuglaufId} — the train run that powers the Zugverlauf.
/// Replaces the blocked bahn.de `fahrt`. One response carries the stop list
/// (halte: ort+coords, ankunft/abgang times, gleis), per-stop
/// `auslastungsInfos` (2nd-class load), train-wide `attributNotizen`
/// (bike/accessibility/amenities) AND `polylineGroup` (map geometry). Asserts
/// the halte shape; occupancy and attributes are best-effort (a stray tram
/// carries neither).
Future<String> checkVendoZuglaufDetail() async {
  final data = await _zuglauf(await _boardZuglaufId());
  final halte = maps(data['halte']);
  if (halte.isEmpty) throw CheckError('zuglauf has no halte');
  final h0 = halte.first;
  if (!h0.containsKey('ort') || !mapOf(h0, 'ort').containsKey('evaNr')) {
    throw CheckError('zuglauf halt missing ort/evaNr');
  }
  bool truthy(dynamic v) => v != null && v != '' && v != false;
  if (!halte.any(
    (h) => truthy(h['abgangsDatum']) || truthy(h['ankunftsDatum']),
  )) {
    throw CheckError('zuglauf halte carry no times');
  }
  // Best-effort shape guards (the app reads these but tolerates absence).
  final occ = halte.any(
    (h) =>
        h['auslastungsInfos'] is List &&
        (h['auslastungsInfos'] as List).isNotEmpty,
  );
  final attrsRaw = data['attributNotizen'];
  if (attrsRaw != null &&
      attrsRaw != '' &&
      attrsRaw is! List &&
      !(attrsRaw is Map && attrsRaw.isEmpty)) {
    throw CheckError('attributNotizen is not a list');
  }
  final attrs = attrsRaw is List ? attrsRaw : const [];
  final poly = listOf(mapOf(data, 'polylineGroup'), 'polylineDesc');
  final extras = [
    if (occ) 'auslastung✓',
    if (attrs.isNotEmpty) '${attrs.length} attrs',
    if (poly.isNotEmpty) 'polyline✓',
  ];
  return '${halte.length} stops, ${data['mitteltext'] ?? '?'}'
      '${extras.isNotEmpty ? ' (${extras.join(', ')})' : ''}';
}

/// Diversion signals on the train run (#17). The app reads three things the
/// zuglauf parser used to ignore: root `himNotizen` (Bauarbeiten/
/// Streckensperrung), root+halt `echtzeitNotizen` ("Umleitung", "Zusatzhalt"
/// — text only, NO `typ` key, so matching is on text), and `istZusatzhalt`
/// per halt.
///
/// Asserts the fields still exist and keep their types. Whether any train is
/// actually diverted right now is up to the day, so presence of a real
/// Umleitung is reported, not required.
Future<String> checkVendoZuglaufNotes() async {
  final data = await _zuglauf(await _boardZuglaufId());
  final halte = maps(data['halte']);
  if (halte.isEmpty) throw CheckError('zuglauf has no halte');

  for (final key in ['himNotizen', 'echtzeitNotizen']) {
    if (data.containsKey(key) && data[key] is! List) {
      throw CheckError("root '$key' is not a list");
    }
  }
  // istZusatzhalt is sent on every halt; the app defaults it to false, but if
  // it vanished entirely we'd silently stop detecting added stops.
  if (!halte.any((h) => h.containsKey('istZusatzhalt'))) {
    throw CheckError(
      "no halt carries 'istZusatzhalt' — added stops can no longer be detected",
    );
  }
  for (final h in halte) {
    if ((h['istZusatzhalt'] ?? false) is! bool) {
      throw CheckError('istZusatzhalt is not a bool');
    }
  }

  final notes = <String>[
    for (final n in [
      ...maps(data['himNotizen']),
      ...maps(data['echtzeitNotizen']),
    ])
      '${n['text'] ?? ''}',
    for (final h in halte)
      for (final n in maps(h['echtzeitNotizen'])) '${n['text'] ?? ''}',
  ];
  final zusatz = halte.where((h) => h['istZusatzhalt'] == true).length;
  var detail =
      '${halte.length} stops, ${notes.length} notes, $zusatz Zusatzhalt';
  if (notes.any((n) {
    final l = n.toLowerCase();
    return l.contains('umleitung') || l.contains('umgeleitet');
  })) {
    detail += ' (live Umleitung!)';
  }
  return detail;
}

/// Gleiswechsel: vendo sends the timetabled platform as `gleis` and the
/// realtime one as `ezGleis` — the latter ONLY when it differs. The app parses
/// both apart (planned vs actual) so a platform change is detectable; parsing
/// both from `gleis` silently swallowed every Gleiswechsel (#16).
///
/// Soft: whether any train is rerouted to another platform right now is up to
/// the day. Absence of `ezGleis` across a whole board is normal-ish; the point
/// is to notice if the FIELD NAME disappears while changes still happen.
Future<String> checkVendoPlatformChange() async {
  final pos = maps(await vendoBoard(koelnHbf));
  if (pos.isEmpty) {
    throw CheckError('no departures to inspect for platform changes');
  }
  if (!pos.any((p) => p.containsKey('gleis'))) {
    throw CheckError("no departure carries 'gleis' — planned platform gone");
  }
  final changed = pos.where((p) {
    final ez = p['ezGleis'];
    return ez != null && ez != '' && ez != p['gleis'];
  }).toList();
  if (changed.isEmpty) {
    return '${pos.length} departures, no live Gleiswechsel right now '
        '(field intact, nothing to compare)';
  }
  final e = changed.first;
  return '${changed.length}/${pos.length} with Gleiswechsel, e.g. '
      "'${e['mitteltext'] ?? '?'}' ${e['gleis']} → ${e['ezGleis']}";
}

const _locationMedia = 'application/x.db.vendo.mob.location.v3+json';

Future<String> checkVendoLocation() async {
  final r = await mobPost('location/search', _locationMedia, {
    'locationTypes': ['ALL'],
    'searchTerm': 'Köln Hbf',
  });
  r.raiseForStatus();
  final data = r.json();
  if (data is! List || data.isEmpty) {
    throw CheckError('expected non-empty list');
  }
  final first = data.first as Map<String, dynamic>;
  for (final key in ['locationId', 'evaNr', 'coordinates']) {
    if (!first.containsKey(key)) throw CheckError("missing field '$key'");
  }
  return "${data.length} hits, top='${first['name']}' eva=${first['evaNr']}";
}

/// Every concrete (non-templated) DB Navigator `/mob` endpoint, extracted from
/// the app APK with `apkurl` (see the apk-url-extractor tool). This is the
/// full backend surface the official app talks to — most we don't use yet, but
/// probing them catches the moment DB removes/renames one (which is how the
/// whole reiseloesung API vanished). Regenerate on a DB Navigator update:
///   apkurl <dbnav.xapk> ; jq -r '.apiPaths[]|select(startswith("mob/") and (contains("{")|not))' snapshots/de.hafas.android.db-*.json
const mobSurface = [
  'mob/aboVertragsstatusAnonym', 'mob/aboverkauf/bestellanfrage', //
  'mob/adressvalidierung', 'mob/amp/discovery/v1/nearby',
  'mob/amp/discovery/v1/stations', 'mob/amp/discovery/v1/stations/location',
  'mob/amp/discovery/v1/vehicles', 'mob/amp/discovery/v1/vehicles/location',
  'mob/amp/discovery/v1/vehicles/lookup', 'mob/amp/login/v1/auth',
  'mob/amp/login/v1/token', 'mob/amp/navigation/v1/estimations/multimodal',
  'mob/amp/pay-discounts/v1/vouchers', 'mob/amp/sharing-booking/v1/bookings',
  'mob/amp/sharing-booking/v1/bookings/latest', 'mob/angebote/fahrplan',
  'mob/angebote/recon', 'mob/angebote/recon/autonomereservierung',
  'mob/angebote/tagesbestpreis', 'mob/angebote/umtausch',
  'mob/angebote/upgrade', 'mob/angebote/verbindung/teilen',
  'mob/appversion/check', 'mob/auftrag/materialisieren/erstmaterialisierung',
  'mob/auftrag/materialisieren/folgematerialisierung', 'mob/auftrag/token',
  'mob/auftrag/upgradeAngebot', 'mob/bahnhofstafel/abfahrt',
  'mob/bahnhofstafel/ankunft', 'mob/buchungen', 'mob/buchungen/abbrechen',
  'mob/buchungen/abschliessen', 'mob/buchungen/abschliessen/anonym',
  'mob/buchungen/anonym', 'mob/buchungen/storno', 'mob/buchungen/umtausch',
  'mob/datalake', 'mob/devicetoken', 'mob/devicetoken/delete',
  'mob/emobilebahncards', 'mob/errorreport', 'mob/gsd/gsd_v3',
  'mob/katalog/angebot', 'mob/katalog/verbundshop/angebot',
  'mob/kci/reservierungen', 'mob/kcidurchfuehren', 'mob/konfiguration',
  'mob/kundenkonten/nutzungsbedingungen/akzeptieren',
  'mob/kundenkonten/nutzungsbedingungen/status', 'mob/kundenkontingente',
  'mob/location/calculateroute', 'mob/location/nearby/bytypes',
  'mob/location/search', 'mob/mehrfahrtenkarten', 'mob/reisen',
  'mob/reisenuebersicht', 'mob/stammdaten', 'mob/streckenfavoriten',
  'mob/trip/recon', 'mob/trip/weitereabfahrten', 'mob/warenkorb',
  'mob/warenkorb/stornooption', 'mob/zahlungsart/lastschrift/mandatstext',
  'mob/zahlungsmittel', 'mob/zahlungsmittel/bankdetails',
  'mob/zahlungsmittel/legacy', 'mob/zuglaeufe/halte/by-abfahrt/wagenreihung',
];

/// The sweep's own client: unpaced and parallel, like the Python sweep (which
/// used the raw transport with 8 workers). Pacing 130+ requests 2 s apart
/// would make this one check take minutes.
final HttpClient _sweepClient = HttpClient()
  ..connectionTimeout = const Duration(seconds: 15);

Future<(int, String)> _sweepRequest(String method, String url) async {
  final req = await _sweepClient.openUrl(method, Uri.parse(url));
  vendoHeaders(
    _locationMedia,
  ).forEach((k, v) => req.headers.set(k, v, preserveHeaderCase: true));
  if (method == 'POST') {
    req.contentLength = 2;
    req.write('{}');
  }
  final res = await req.close();
  final body = await res
      .fold<List<int>>(<int>[], (a, b) => a..addAll(b))
      .then((b) => String.fromCharCodes(b.take(400)));
  return (res.statusCode, body);
}

Future<String> _probeSurface(String path) async {
  final url = 'https://$mobHost/$path';
  // POST first; if the path 404s (some are GET-only → the router 404s an
  // unmatched method+path), re-probe with GET before calling it gone.
  try {
    for (final method in ['POST', 'GET']) {
      final (status, text) = await _sweepRequest(
        method,
        url,
      ).timeout(const Duration(seconds: 15));
      if (status == 403 || text.contains('OPS_BLOCKED')) return 'BLOCKED';
      if (status != 404) return 'ok'; // reachable (401/400/405/415/200/500…)
    }
    return '404'; // both methods 404 → really gone
  } on TimeoutException {
    return 'ERR:Timeout';
  } catch (e) {
    return 'ERR:${e.runtimeType}';
  }
}

/// Reachability sweep over the ENTIRE DB Navigator /mob surface (see
/// [mobSurface]). POST an empty body to each and flag only the ones that are
/// *gone* — 404 (removed/renamed) or OPS_BLOCKED (Akamai). Auth-gated (401),
/// wrong-media (415), bad-body (400), wrong-method (405) all count as
/// reachable: the endpoint still exists. Soft — a transient blip shouldn't
/// fail CI, but a real removal shows up here first. This is the early-warning
/// net that would have flagged the reiseloesung shutdown.
Future<String> checkMobSurface() async {
  final results = List<String>.filled(mobSurface.length, '');
  var next = 0;
  Future<void> worker() async {
    while (next < mobSurface.length) {
      final i = next++;
      results[i] = await _probeSurface(mobSurface[i]);
    }
  }

  await Future.wait(List.generate(8, (_) => worker()));
  final gone = [
    for (var i = 0; i < mobSurface.length; i++)
      if (results[i] != 'ok') '${mobSurface[i]}→${results[i]}',
  ];
  if (gone.isNotEmpty) {
    throw CheckError(
      '${gone.length}/${mobSurface.length} mob endpoints NOT reachable: '
      '[${gone.map((g) => "'$g'").join(', ')}]',
    );
  }
  return 'all ${mobSurface.length} mob endpoints reachable';
}

/// POST /mob/location/nearby/bytypes — stations near a coordinate. The coords
/// go inside `area`, and `types`/`operatingSystem` are required (that shape is
/// why the older /mob/location/nearby guesses all 400'd). Response:
/// {fahrplanAuskunftLocations: [...]}.
Future<String> checkVendoNearby() async {
  final r = await mobPost('location/nearby/bytypes', _locationMedia, {
    'area': {
      'coordinates': {'latitude': 50.9427, 'longitude': 6.9586},
      'radius': 2000,
    },
    'maxResults': 5,
    'operatingSystem': 'ANDROID',
    'products': ['ALL'],
    'types': ['ST'],
  });
  r.raiseForStatus();
  final locs = maps(r.jsonMap()['fahrplanAuskunftLocations']);
  if (locs.isEmpty) throw CheckError('no nearby locations');
  final first = locs.first;
  for (final key in ['evaNr', 'name', 'coordinates']) {
    if (!first.containsKey(key)) {
      throw CheckError("nearby location missing '$key'");
    }
  }
  return "${locs.length} nearby, closest '${first['name']}' "
      '(${first['distance']}m)';
}
