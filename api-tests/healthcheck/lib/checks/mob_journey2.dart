import 'dart:convert';
import 'dart:typed_data';

import '../src/core.dart';

/// Checks of group "mob_journey2": search options, transfer facts, service
/// days, the Bestpreis calendar, master-data drift, walking routes and the
/// party search. Ported from api-tests/healthcheck.py.
final List<Check> mobJourney2Checks = [
  Check(
    'vendo search options (#19)',
    checkVendoSearchOptions,
    group: 'mob_journey2',
  ),
  Check(
    'vendo transfer info (#20.6)',
    checkVendoTransferInfo,
    group: 'mob_journey2',
  ),
  Check(
    'vendo serviceDays (#20.8)',
    checkVendoServiceDays,
    group: 'mob_journey2',
  ),
  Check(
    'vendo tagesbestpreis (#21)',
    checkVendoTagesbestpreis,
    group: 'mob_journey2',
  ),
  Check(
    'stammdaten vs reisende.dart (#21)',
    checkVendoStammdatenDrift,
    group: 'mob_journey2',
  ),
  Check(
    'vendo walking route (#21)',
    checkVendoCalculateroute,
    group: 'mob_journey2',
  ),
  Check(
    'vendo party search (pax/bike/dog/SBA)',
    checkVendoJourneyParty,
    group: 'mob_journey2',
  ),
];

const _searchMedia = 'application/x.db.vendo.mob.verbindungssuche.v9+json';
const _koeln = 'A=1@O=Köln Hbf@X=6958730@Y=50943029@U=80@L=8000207@';

// --- helpers ----------------------------------------------------------------

/// Python's `datetime.isoformat()` of an aware local time: seconds, the
/// microseconds only when non-zero, and the `+HH:MM` offset.
String _iso(DateTime d, Duration offset) {
  final sign = offset.isNegative ? '-' : '+';
  final off =
      '$sign${two(offset.inHours.abs())}:${two(offset.inMinutes.abs() % 60)}';
  final micro = d.millisecond * 1000 + d.microsecond;
  final frac = micro == 0 ? '' : '.${micro.toString().padLeft(6, '0')}';
  return '${ymd(d)}T${two(d.hour)}:${two(d.minute)}:${two(d.second)}$frac$off';
}

/// `(now.astimezone() + timedelta(days)).replace(hour=…, minute=0, …)` — keeps
/// today's UTC offset, like the Python fixed-offset arithmetic did.
String _isoInDays(int days, int hour) {
  final now = DateTime.now();
  final d = now.add(Duration(days: days));
  return _iso(DateTime(d.year, d.month, d.day, hour), now.timeZoneOffset);
}

/// The standard /angebote body: one adult, 2nd class, no reductions.
Map<String, dynamic> _angebotBody(Map<String, dynamic> wunsch) => {
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

Future<Resp> _fahrplan(Map<String, dynamic> body) =>
    mobPost('angebote/fahrplan', _searchMedia, body);

/// Python's `repr()` of a list of strings: `['A', 'B']`.
String _pyList(Iterable<Object?> xs) =>
    '[${xs.map((x) => x is String ? "'$x'" : '$x').join(', ')}]';

/// Python's `repr()` of a str (for `{note!r}`).
String _pyRepr(String s) => s.contains("'") && !s.contains('"')
    ? '"$s"'
    : "'${s.replaceAll("'", r"\'")}'";

List<String> _sorted(Iterable<String> xs) => xs.toList()..sort();

// --- vendo search options (#19) ---------------------------------------------

/// The search options must be honoured server-side (#19).
///
/// `maxUmstiege`, `minUmstiegsdauer` and `viaLocations` are the difference
/// between *searching* for a connection the rider can make and filtering holes
/// into a list we already fetched — the transfer profile can only warn about a
/// 5-minute change it was handed, it can't ask for a better one.
///
/// Each is measured against a baseline on the same route rather than just
/// asserting a 200: the backend answers an unknown wunsch field by ignoring
/// it, so "not rejected" would prove nothing. Note it also answers an
/// impossible constraint with an empty list, not an error — hence the app's
/// relax-and-retry.
Future<String> checkVendoSearchOptions() async {
  // Köln→München: enough one-change options for a cap to bite, and it has
  // both direct ICEs and a natural via (Frankfurt).
  const frankfurt =
      'A=1@O=Frankfurt(Main)Hbf@X=8663785@Y=50107149@U=80@L=8000105@';

  Future<List<({int umst, List<int> gaps, Set<String?> stops})>> search([
    Map<String, dynamic> wunsch = const {},
  ]) async {
    final w = <String, dynamic>{
      'abgangsLocationId': _koeln,
      'alternativeHalteBerechnung': true,
      'verkehrsmittel': ['ALL'],
      'zeitWunsch': {'reiseDatum': _isoInDays(2, 9), 'zeitPunktArt': 'ABFAHRT'},
      'zielLocationId': munichLoc,
      ...wunsch,
    };
    final r = await _fahrplan(_angebotBody(w));
    if (r.status == 400) {
      throw CheckError(
        'wunsch ${_pyList(wunsch.keys)} rejected (400) — field '
        'renamed? re-extract from the Navigator APK',
      );
    }
    r.raiseForStatus();
    final out = <({int umst, List<int> gaps, Set<String?> stops})>[];
    for (final c in maps(listOf(r.json(), 'verbindungen'))) {
      final legs = maps(
        listOf(c['verbindung'], 'verbindungsAbschnitte'),
      ).where((a) => a['typ'] == 'FAHRZEUG').toList();
      final gaps = <int>[];
      for (var i = 0; i + 1 < legs.length; i++) {
        final secs = DateTime.parse(
          '${legs[i + 1]['abgangsDatum']}',
        ).difference(DateTime.parse('${legs[i]['ankunftsDatum']}')).inSeconds;
        gaps.add((secs / 60).floor());
      }
      final stops = <String?>{
        for (final a in legs) mapOf(a, 'abgangsOrt')['name'] as String?,
        for (final a in legs) mapOf(a, 'ankunftsOrt')['name'] as String?,
      };
      out.add((umst: legs.length - 1, gaps: gaps, stops: stops));
    }
    return out;
  }

  final base = await search();
  if (base.isEmpty)
    throw CheckError('baseline search returned no verbindungen');

  final direct = await search({'maxUmstiege': 0});
  if (direct.isEmpty) {
    throw CheckError('maxUmstiege=0 returned nothing (route has ICEs)');
  }
  if (direct.any((c) => c.umst > 0)) {
    throw CheckError(
      'maxUmstiege=0 ignored: ${[for (final c in direct) c.umst]} changes',
    );
  }

  final slack = await search({'minUmstiegsdauer': 40});
  if (slack.isEmpty) throw CheckError('minUmstiegsdauer=40 returned nothing');
  final tight = [
    for (final c in slack)
      for (final g in c.gaps)
        if (g < 40) g,
  ];
  if (tight.isNotEmpty) {
    throw CheckError('minUmstiegsdauer=40 ignored: gaps $tight min');
  }

  // A via is *passed through*, not necessarily changed at — assert the route
  // touches it, which is the promise the option makes.
  final via = await search({
    'viaLocations': [
      {'locationId': frankfurt},
    ],
  });
  if (via.isEmpty) throw CheckError('viaLocations returned nothing');
  final viaStay = await search({
    'viaLocations': [
      {'locationId': frankfurt, 'minUmstiegsdauer': 60},
    ],
  });
  if (viaStay.isEmpty) {
    throw CheckError(
      'viaLocations with own minUmstiegsdauer returned '
      'nothing',
    );
  }
  if (!viaStay.any((c) => c.stops.contains('Frankfurt(Main)Hbf'))) {
    throw CheckError('per-via minUmstiegsdauer dropped the via itself');
  }

  int? minOf(Iterable<int> xs) =>
      xs.isEmpty ? null : xs.reduce((a, b) => a < b ? a : b);
  final baseMin = minOf([for (final c in base) ...c.gaps]);
  final slackMin = minOf([for (final c in slack) ...c.gaps]);
  return 'honoured — baseline ${base.length} conns (min gap '
      '${baseMin ?? 'None'} min), '
      'maxUmstiege=0 → ${direct.length} direct, minUmstiegsdauer=40 → '
      'min gap ${slackMin ?? '—'}'
      ', via → ${via.length} conns / with 60-min stay ${viaStay.length}';
}

// --- vendo transfer info (#20.6) --------------------------------------------

/// DB's own transfer facts, which we used to re-derive or miss (#20.6).
///
/// Two shapes, and the difference matters:
///
/// - a walk BETWEEN stations (Köln Messe/Deutz → …Gl.11-12) carries
///   `verfuegbareZeit` (the window, seconds) next to `abschnittsDauer` (the
///   walk itself) and `distanz`;
/// - a change WITHIN one station carries neither, and `abschnittsDauer` is
///   the whole window again.
///
/// vendo_service therefore only reads `abschnittsDauer` as a walk when
/// `verfuegbareZeit` sits beside it. If DB ever started sending
/// `verfuegbareZeit` on same-station changes too, that rule would start
/// inventing walk times — so assert the pairing, not just the presence.
///
/// `weiterfahrtAmGleichenBahnsteig` rides on the FUSSWEG leg (true also for
/// Gleis 4 → 5 on one island platform) and is what stops the transfer profile
/// warning about the easiest change DB can offer.
Future<String> checkVendoTransferInfo() async {
  const kielStart = 'A=1@O=Kiel Hbf@X=10131976@Y=54314982@U=80@L=8000199@';
  const augsburgEnd =
      'A=1@O=Augsburg Hbf@X=10885802@Y=48365456@U=80@L=8000013@';
  final r = await _fahrplan(
    _angebotBody({
      'abgangsLocationId': kielStart,
      'alternativeHalteBerechnung': true,
      'verkehrsmittel': ['ALL'],
      'zeitWunsch': {'reiseDatum': _isoInDays(2, 8), 'zeitPunktArt': 'ABFAHRT'},
      'zielLocationId': augsburgEnd,
    }),
  );
  r.raiseForStatus();
  final conns = maps(listOf(r.json(), 'verbindungen'));
  if (conns.isEmpty) throw CheckError('no verbindungen returned');

  var walks = 0, samePlatform = 0, paired = 0, adjacentTrains = 0;
  for (final c in conns) {
    final legs = maps(listOf(c['verbindung'], 'verbindungsAbschnitte'));
    for (var i = 0; i + 1 < legs.length; i++) {
      if (legs[i]['typ'] == 'FAHRZEUG' && legs[i + 1]['typ'] == 'FAHRZEUG') {
        // Every transfer is modelled as a FUSSWEG leg; if that ever changes,
        // the flag has to be read off the train instead.
        adjacentTrains++;
      }
    }
    for (final a in legs) {
      if (a['typ'] != 'FUSSWEG') continue;
      walks++;
      final wf = a['weiterfahrtAmGleichenBahnsteig'];
      if (wf != null && wf is! bool) {
        throw CheckError('weiterfahrtAmGleichenBahnsteig is not a bool');
      }
      if (wf == true) samePlatform++;
      final vz = a['verfuegbareZeit'];
      final dauer = a['abschnittsDauer'];
      if (vz == null) continue;
      paired++;
      if (vz is! int || dauer is! int) {
        throw CheckError(
          'verfuegbareZeit/abschnittsDauer not ints '
          '(seconds expected)',
        );
      }
      // The invariant the parser leans on: where DB gives both, the walk fits
      // inside the window. If they were ever equal on a same-station change,
      // "X min Weg" would be a window mislabelled as a walk.
      if (dauer > vz) {
        throw CheckError(
          'walk (${dauer}s) longer than the window (${vz}s) — '
          'verfuegbareZeit is not the transfer window any more',
        );
      }
    }
  }

  if (walks == 0) {
    throw CheckError(
      'no FUSSWEG legs — transfers are modelled elsewhere '
      'now, the same-platform flag moved with them',
    );
  }
  if (adjacentTrains > 0) {
    throw CheckError(
      '$adjacentTrains train→train transfers with no '
      'FUSSWEG leg — read the flag off the train too',
    );
  }
  return '$walks transfers: $samePlatform same-platform, $paired with '
      'verfuegbareZeit+abschnittsDauer paired';
}

// --- vendo serviceDays (#20.8) ----------------------------------------------

const _months = {
  'Jan': 1, 'Feb': 2, 'Mär': 3, 'Mrz': 3, 'Apr': 4, 'Mai': 5, 'Jun': 6, //
  'Jul': 7, 'Aug': 8, 'Sep': 9, 'Okt': 10, 'Nov': 11, 'Dez': 12,
};

/// A real calendar date, or null (Python's `date()` raises ValueError where
/// Dart's DateTime would silently roll over).
DateTime? _date(int y, int m, int d) {
  final dt = DateTime(y, m, d);
  return (dt.year == y && dt.month == m && dt.day == d) ? dt : null;
}

String? _first3(String? s) =>
    s == null ? null : (s.length > 3 ? s.substring(0, 3) : s);

/// (start, end) dates of every 'nicht …' span in a serviceDays text.
List<(DateTime, DateTime)> _nichtRanges(String text, int year) {
  // Python's `\w` is Unicode-aware ("Mär"); Dart's is ASCII-only.
  const w = r'[\wÄÖÜäöüß]';
  final re = RegExp(
    r'(\d{1,2})\.\s*(?:('
    '$w'
    r'{3})\.?\s*)?(?:(\d{4})\s*)?'
    r'(?:bis\s*(\d{1,2})\.\s*(?:('
    '$w'
    r'{3})\.?\s*)?(?:(\d{4}))?)?',
  );
  final out = <(DateTime, DateTime)>[];
  for (final chunk in text.split(';')) {
    final at = chunk.indexOf('nicht');
    if (at < 0) continue;
    final rest = chunk.substring(at + 'nicht'.length);
    for (final m in re.allMatches(rest)) {
      final d1 = m.group(1), m1 = m.group(2), y1 = m.group(3);
      final d2 = m.group(4), m2 = m.group(5), y2 = m.group(6);
      final mm1 = _months[_first3(m1 ?? m2 ?? '')];
      final mm2 = _months[_first3(m2 ?? m1 ?? '')] ?? mm1;
      if (d1 == null || mm1 == null) continue;
      final start = _date(int.parse(y1 ?? y2 ?? '$year'), mm1, int.parse(d1));
      final end = _date(
        int.parse(y2 ?? y1 ?? '$year'),
        mm2!,
        int.parse(d2 ?? d1),
      );
      if (start == null || end == null) continue;
      out.add((start, end));
    }
  }
  return out;
}

/// `serviceDays.irregular` still describes the CONNECTION (#20, point 8).
///
/// The app shows this string as "Verkehrstage dieser Verbindung". That is only
/// honest while the date you're offered is never a date the string excludes —
/// which is exactly what separates it from the zuglauf's `fahrplan.
/// tageOhneFahrt`, where every sampled run was bookable on a day inside its
/// own "tageOhneFahrt" range (RE 10909 on 18 Jul: "16. bis 23. Jul 2026"), and
/// which the app therefore does NOT show.
///
/// Parses the German ranges *here* — never in the app, where the string is
/// passed through untouched — so a change in that promise trips this check
/// instead of a user reading "fährt nicht" about the train they're sitting on.
Future<String> checkVendoServiceDays() async {
  var withNote = 0;
  for (final offset in [2, 30]) {
    final r = await _fahrplan(
      _angebotBody({
        'abgangsLocationId': _koeln,
        'alternativeHalteBerechnung': true,
        'verkehrsmittel': ['ALL'],
        'zeitWunsch': {
          'reiseDatum': _isoInDays(offset, 9),
          'zeitPunktArt': 'ABFAHRT',
        },
        'zielLocationId': munichLoc,
      }),
    );
    r.raiseForStatus();
    for (final c in maps(listOf(r.json(), 'verbindungen'))) {
      final vb = mapOf(c, 'verbindung');
      final days = vb['serviceDays'];
      if (days == null || (days is List && days.isEmpty)) continue;
      if (days is! List || days.first is! Map) {
        throw CheckError('serviceDays is not a list of objects');
      }
      final note = '${(days.first as Map)['irregular'] ?? ''}'.trim();
      if (note.isEmpty) continue;
      withNote++;
      final abschnitte = maps(listOf(vb, 'verbindungsAbschnitte'));
      final dep = abschnitte.isEmpty ? null : abschnitte.first['abgangsDatum'];
      if (dep is! String || dep.isEmpty) continue;
      // The date in the timestamp's own offset (Python's fromisoformat().date()),
      // not converted to UTC.
      final travel = DateTime.parse(dep.substring(0, 10));
      for (final (start, end) in _nichtRanges(note, travel.year)) {
        if (!travel.isBefore(start) && !travel.isAfter(end)) {
          throw CheckError(
            'connection departs ${ymd(travel)} but its own serviceDays '
            'excludes that date (${_pyRepr(note)}) — the string no longer '
            'describes this connection, stop showing it as '
            'Verkehrstage',
          );
        }
      }
    }
  }

  if (withNote == 0) {
    throw CheckError(
      'no connection carried serviceDays.irregular — the '
      'Verkehrstage line can never appear',
    );
  }
  return '$withNote connections with an irregular text, none excluding '
      'its own travel date';
}

// --- vendo tagesbestpreis (#21) ---------------------------------------------

/// The Bestpreis calendar: a whole day of prices in ONE request (#21).
///
/// Same media type and body as /angebote/fahrplan, minus the context. Each
/// interval carries `angebotsPreis` and DB's own `istBestpreis`, plus the full
/// connections — `kontext` included, which is what lets the app hand them
/// straight to the detail/share/split paths instead of re-searching.
///
/// Asserts the parts the app leans on: the interval bounds, that DB flags
/// exactly one best interval, and that a connection still carries a kontext.
Future<String> checkVendoTagesbestpreis() async {
  final r = await mobPost(
    'angebote/tagesbestpreis',
    _searchMedia,
    _angebotBody({
      'abgangsLocationId': _koeln,
      'alternativeHalteBerechnung': true,
      'verkehrsmittel': ['ALL'],
      'zeitWunsch': {'reiseDatum': _isoInDays(6, 0), 'zeitPunktArt': 'ABFAHRT'},
      'zielLocationId': berlinLoc,
    }),
  );
  r.raiseForStatus();
  final intervals = maps(listOf(r.json(), 'tagesbestPreisIntervalle'));
  if (intervals.isEmpty)
    throw CheckError('no tagesbestPreisIntervalle returned');

  var best = 0, priced = 0;
  var kontextSeen = false;
  for (final iv in intervals) {
    if ((iv['intervallAb'] ?? '') == '' || (iv['intervallBis'] ?? '') == '') {
      throw CheckError(
        'interval without intervallAb/intervallBis — the '
        'app drops those, the calendar would lose a slot',
      );
    }
    if (iv['istBestpreis'] == true) best++;
    final preis = iv['angebotsPreis'];
    if (preis != null) {
      priced++;
      if (preis is! Map || preis['betrag'] is! num) {
        throw CheckError('angebotsPreis.betrag is not a number');
      }
    }
    for (final c in maps(listOf(iv, 'verbindungen'))) {
      final k = mapOf(c, 'verbindung')['kontext'];
      if (k != null && k != '') {
        kontextSeen = true;
      } else {
        throw CheckError(
          'a Bestpreis connection has no kontext — '
          'detail/share/split would break on it',
        );
      }
    }
  }

  if (best != 1) {
    throw CheckError(
      '$best intervals flagged istBestpreis (expected '
      'exactly 1) — the app marks what DB marks',
    );
  }
  if (priced == 0) throw CheckError('no interval carried angebotsPreis');
  if (!kontextSeen) throw CheckError('no connections in any interval');

  final prices = [
    for (final iv in intervals)
      if (iv['angebotsPreis'] != null && iv['istTeilpreis'] != true)
        (iv['angebotsPreis'] as Map)['betrag'] as num,
  ];
  if (prices.isEmpty) {
    // Python's min() of an empty sequence raised ValueError here.
    throw StateError('min() arg is an empty sequence');
  }
  final cheapest = prices.reduce((a, b) => a < b ? a : b);
  return '${intervals.length} intervals, $priced priced, best flagged once, '
      'cheapest $cheapest EUR';
}

// --- stammdaten vs reisende.dart (#21) --------------------------------------

/// The app's compiled-in `reisende.dart` enums vs. the live master data.
///
/// `GET /mob/stammdaten` is the source these enums were copied from, by hand,
/// out of an APK asset. That's the same failure mode as the hardcoded
/// `verkehrsmittel: ['ALL']` of #18: a value that can't move when DB moves it.
/// This diffs the Dart source itself — not a snapshot of it — so drift shows up
/// the day it happens.
///
/// Why the two directions are not treated alike:
///
/// - `reisendenTyp` is a hard fail. We send exactly one per traveller, and a
///   renamed one is an immediate break.
/// - A BahnCard we ship that vanishes from the master data is a hard fail:
///   BahnCards demonstrably move the price (BC50 takes Köln→München from
///   153,69 € to 97,35 €), so if one stopped working, riders would silently be
///   quoted full fare.
/// - Anything else is REPORTED, not failed. The endpoint answers an invented
///   `ermaessigungen` key with a 200 and an unchanged price — it ignores what
///   it doesn't know. So a de-listed foreign/SBA key is indistinguishable from
///   a working one, and failing CI over it would only invite someone to delete
///   a working option (see SbaOption.beeintrOhneRolli).
/// - Live keys we don't offer are reported too: NL-100 was found exactly that
///   way, and it is real money (Köln→Amsterdam 73,99 € → 51,60 €).
Future<String> checkVendoStammdatenDrift() async {
  const media = 'application/x.db.vendo.mob.stammdaten.v6+json';
  final r = await get(
    'https://$mobHost/mob/stammdaten?operatingSystem=ANDROID&sdtyp=RESOURCE',
    headers: vendoHeaders(media),
    timeout: const Duration(seconds: 40),
  );
  r.raiseForStatus();
  final data = r.json();

  // `key` already carries the class suffix ("BAHNCARD50 KLASSE_2"), which is
  // exactly the token the app puts in `ermaessigungen`.
  Set<String> keysOfList(String name) => {
    for (final e in maps(listOf(data, name)))
      if (e['key'] is String && (e['key'] as String).isNotEmpty)
        e['key'] as String,
  };
  final liveErm = keysOfList('ermaessigungen');
  final liveTypen = keysOfList('reisendenTypen');
  if (liveErm.isEmpty || liveTypen.isEmpty) {
    throw CheckError(
      'stammdaten has no ermaessigungen/reisendenTypen — '
      'shape changed',
    );
  }

  final src = appFile('lib/models/reisende.dart').readAsStringSync();

  /// The `enum X { ... }` block, so one enum's keys can't leak into another.
  String enumBody(String name) {
    final m = RegExp(
      'enum ${RegExp.escape(name)} \\{(.*?)^\\}',
      multiLine: true,
      dotAll: true,
    ).firstMatch(src);
    if (m == null) throw CheckError('enum $name not found in reisende.dart');
    return m.group(1)!;
  }

  // First string literal of each enum entry is its vendoKey.
  Set<String> keysOf(String name) => {
    for (final m in RegExp(
      r"'([A-Z0-9][A-Z0-9_\- ]*)'",
    ).allMatches(enumBody(name)))
      m.group(1)!,
  };

  final oursErm = keysOf('Reduction')..addAll(keysOf('SbaOption'));
  final oursTypen = keysOf('TravelerType');

  final typenOursNotLive = oursTypen.difference(liveTypen);
  final typenLiveNotOurs = liveTypen.difference(oursTypen);
  if (typenOursNotLive.isNotEmpty || typenLiveNotOurs.isNotEmpty) {
    throw CheckError(
      'reisendenTyp drift — ours-not-live: ${_pyList(_sorted(typenOursNotLive))}, '
      'live-not-ours: ${_pyList(_sorted(typenLiveNotOurs))}',
    );
  }

  final oursMissing = oursErm.difference(liveErm);
  final goneBahncards = oursMissing.where((k) => k.startsWith('BAHNCARD'));
  if (goneBahncards.isNotEmpty) {
    throw CheckError(
      'BahnCard keys no longer in the master data: '
      '${_pyList(_sorted(goneBahncards))} '
      '— riders holding them would be quoted full fare',
    );
  }

  final liveMissing = liveErm.difference(oursErm);
  final notes = <String>[];
  if (oursMissing.isNotEmpty) {
    notes.add(
      'we still offer ${_pyList(_sorted(oursMissing))} (de-listed; the '
      'endpoint ignores unknown keys, so this is not provably '
      'broken)',
    );
  }
  if (liveMissing.isNotEmpty) {
    notes.add('not offered by us: ${_pyList(_sorted(liveMissing))}');
  }
  final detail = notes.isNotEmpty ? notes.join('; ') : 'no drift';
  return '${liveErm.length} ermaessigungen / ${liveTypen.length} '
      'reisendenTypen live — $detail';
}

// --- vendo walking route (#21) ----------------------------------------------

/// Real walking routing, used for "Fußweg zum Gleis" (#21).
///
/// The app deliberately does NOT send `desiredCoordinateType: WKB`: without it
/// the same response carries the polyline as plain `gpsPositions`, so there is
/// no WKB decoder in the app at all. This asserts that plain form still comes
/// back with a real polyline — and, by decoding the WKB variant here only,
/// that the two still agree. If DB ever made the polyline WKB-only, the app
/// would silently fall back to straight lines forever; this check is what
/// would say so.
Future<String> checkVendoCalculateroute() async {
  const media = 'application/x.db.vendo.mob.location.v3+json';
  // Köln Hbf → ~200 m south. Straight-line ~200 m, real walk ~680 m — the gap
  // that makes the endpoint worth calling.
  const points = [
    {'latitude': 50.943029, 'longitude': 6.958730},
    {'latitude': 50.941200, 'longitude': 6.958730},
  ];

  final r = await mobPost('location/calculateroute', media, {
    'gpsPositions': points,
  });
  if (r.status == 400) {
    throw CheckError(
      'calculateroute rejected {gpsPositions:[{latitude,'
      'longitude}]} (400) — request shape changed',
    );
  }
  r.raiseForStatus();
  final d = r.jsonMap();
  final plain = (d['gpsPositions'] as List?) ?? const [];
  if (plain.length < 2) {
    throw CheckError(
      'no polyline in the plain response — the app has no '
      'WKB decoder and would draw straight lines forever',
    );
  }
  for (final p in plain) {
    if (p is! Map || p['latitude'] is! num || p['longitude'] is! num) {
      throw CheckError('gpsPositions entries are not lat/lon numbers');
    }
  }
  final distance = d['distance'];
  final traveltime = d['traveltime'];
  if (distance is! int || traveltime is! int) {
    throw CheckError(
      'distance/traveltime missing or not ints (seconds '
      'and metres expected)',
    );
  }

  // The whole point: routed distance must exceed the crow-flight one.
  const straight = 203; // metres between the two points above
  if (distance < straight) {
    throw CheckError(
      'routed distance $distance m is under the straight '
      'line ($straight m) — not a walking route',
    );
  }

  final r2 = await mobPost('location/calculateroute', media, {
    'gpsPositions': points,
    'desiredCoordinateType': 'WKB',
  });
  r2.raiseForStatus();
  final raw = base64.decode('${r2.jsonMap()['wkb']}');
  final bd = ByteData.sublistView(Uint8List.fromList(raw));
  final endian = raw[0] == 1 ? Endian.little : Endian.big;
  final gtype = bd.getUint32(1, endian);
  if (gtype != 2) {
    throw CheckError('WKB geometry type $gtype, expected 2 (LineString)');
  }
  final n = bd.getUint32(5, endian);
  if (n != plain.length) {
    throw CheckError(
      'WKB has $n points but the plain response has '
      '${plain.length} — they no longer agree, and the app '
      'only reads the plain one',
    );
  }

  return '${plain.length} points, $distance m / ${traveltime}s walking vs '
      '~$straight m straight; WKB agrees';
}

// --- vendo party search (pax/bike/dog/SBA) ----------------------------------

/// Advanced "Reisende & Klasse" search: the app lets you build a party of
/// multiple passengers (with explicit ages), a bike and a dog, pick 1st class,
/// and attach BahnCards / a Schwerbehindertenausweis. Every key here comes from
/// the DB Navigator master data (api-tests/db_stammdaten_enums.json). Exercise
/// a representative payload — if DB renames a reisendenTyp/ermaessigung enum
/// this 400s before users hit it.
///
/// Notes proven against the live endpoint: FAHRRAD/HUND are reisendenTyp
/// entries with empty ermaessigungen; `alter` is a scalar int per traveller (an
/// array → HTTP 400); BahnCard + SBA may be combined in one traveller's list.
Future<String> checkVendoJourneyParty() async {
  final now = DateTime.now();
  final body = {
    'autonomeReservierung': false,
    'einstiegsTypList': ['STANDARD'],
    'fahrverguenstigungen': {
      'deutschlandTicketVorhanden': false,
      'nurDeutschlandTicketVerbindungen': false,
    },
    // 2nd class: a wheelchair-place SBA (…_MIT_ROLLSTUHL) is not bookable in
    // 1st class — DB rejects that combo with MDA-ERSTE-KLASSE-ROLLSTUHL.
    'klasse': 'KLASSE_2',
    'reiseHin': {
      'wunsch': {
        'abgangsLocationId': kielLoc,
        'alternativeHalteBerechnung': true,
        'verkehrsmittel': ['ALL'],
        'zeitWunsch': {
          'reiseDatum': _iso(now, now.timeZoneOffset),
          'zeitPunktArt': 'ABFAHRT',
        },
        'zielLocationId': berlinLoc,
      },
    },
    'reisendenProfil': {
      'reisende': [
        {
          // adult with BahnCard 25 + Schwerbehindertenausweis (combined)
          'reisendenTyp': 'ERWACHSENER',
          'ermaessigungen': [
            'BAHNCARD25 KLASSE_2',
            'SBA_BEEINTRAECHTIGUNGEN_MIT_ROLLSTUHL KLASSENLOS',
          ],
          'alter': 40,
        },
        {
          // child with an explicit age
          'reisendenTyp': 'FAMILIENKIND',
          'ermaessigungen': ['KEINE_ERMAESSIGUNG KLASSENLOS'],
          'alter': 10,
        },
        {'reisendenTyp': 'FAHRRAD', 'ermaessigungen': <String>[]},
        {'reisendenTyp': 'HUND', 'ermaessigungen': <String>[]},
      ],
    },
    'reservierungsKontingenteVorhanden': false,
  };
  final r = await _fahrplan(body);
  r.raiseForStatus();
  final conns = maps(listOf(r.json(), 'verbindungen'));
  if (conns.isEmpty) throw CheckError('party search returned no verbindungen');

  // Bike rules per leg (#68): the app reads `attributNotizen[].key` and maps
  // FB/FR/FS to "begrenzt möglich / reservierungspflichtig / Sperrzeiten".
  // The container has to stay a list of {key, text}; WHICH codes come back
  // depends on the trains of the day, so the codes themselves stay soft.
  final bikeKeys = <String>{};
  for (final c in conns) {
    for (final leg in maps(listOf(c['verbindung'], 'verbindungsAbschnitte'))) {
      final notes = leg['attributNotizen'];
      if (notes == null) continue;
      if (notes is! List) throw CheckError('leg attributNotizen is not a list');
      for (final n in notes) {
        if (n is! Map || !n.containsKey('key')) {
          throw CheckError("attributNotiz lacks a 'key'");
        }
        final k = '${n['key']}'.toUpperCase();
        if (const {'FB', 'FR', 'FS'}.contains(k)) bikeKeys.add(k);
      }
    }
  }
  final bikeTxt = bikeKeys.isNotEmpty
      ? ', bike codes ${_pyList(_sorted(bikeKeys))}'
      : ", no bike codes on today's trains";
  return 'party (2 pers, bike, dog, BC25+SBA) ok — '
      '${conns.length} journeys$bikeTxt';
}
