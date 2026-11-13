import '../src/core.dart';

/// Checks of group "mob_journey": the journey search with prices, address/POI
/// search, door-to-door routing, split scope, earlier alight and the
/// verkehrsmittel filter. Ported from api-tests/healthcheck.py.
final List<Check> mobJourneyChecks = [
  Check('vendo journey + prices (v9)', checkVendoJourney, group: 'mob_journey'),
  Check(
    'vendo address search (ADR)',
    checkVendoAddressSearch,
    group: 'mob_journey',
  ),
  Check('vendo POI search', checkVendoPoiSearch, group: 'mob_journey'),
  Check(
    'vendo door-to-door to an address',
    checkVendoAddressJourney,
    soft: true,
    group: 'mob_journey',
  ),
  Check(
    'vendo split scope: leg vs zuglauf (#22)',
    checkVendoSplitScope,
    group: 'mob_journey',
  ),
  Check(
    'vendo earlier alight (#26)',
    checkVendoEarlierAlight,
    group: 'mob_journey',
  ),
  Check(
    'vendo verkehrsmittel filter (#18)',
    checkVendoVerkehrsmittel,
    group: 'mob_journey',
  ),
];

const _journeyMedia = 'application/x.db.vendo.mob.verbindungssuche.v9+json';
const _locationMedia = 'application/x.db.vendo.mob.location.v3+json';

/// The address the app must be able to route to without Google Maps: the
/// Arbeitsagentur outpost in Preetz. Its nearest stop is the bus stop
/// "Gewerbegebiet, Preetz (Holstein)" ~40 m away — which is exactly the answer
/// a maps app gives, and the answer DB gives too once addresses are searchable.
const preetzAddress = 'Kieler Straße 30, 24211 Preetz';
const preetzNearestStop = 'Gewerbegebiet, Preetz (Holstein)';

/// ISO-8601 with the local UTC offset, like Python's
/// `datetime.now().astimezone().isoformat()` (seconds precision).
String _isoLocal(DateTime d) {
  final l = d.toLocal();
  final off = l.timeZoneOffset;
  final sign = off.isNegative ? '-' : '+';
  final h = two(off.inHours.abs());
  final m = two(off.inMinutes.abs() % 60);
  return '${ymd(l)}T${two(l.hour)}:${two(l.minute)}:${two(l.second)}'
      '$sign$h:$m';
}

/// Tomorrow at [hour]:00 local time.
DateTime _tomorrowAt(int hour) {
  final n = DateTime.now();
  return DateTime(n.year, n.month, n.day + 1, hour);
}

/// Python-style list text: ['a', 'b'].
String _pyList(Iterable<Object?> xs) => '[${xs.map((x) => "'$x'").join(', ')}]';

/// Python-style `repr` of a string.
String _repr(Object? s) => s == null ? 'None' : "'$s'";

/// The standard journey search body every check here sends.
Map<String, dynamic> _searchBody({
  required String from,
  required String to,
  required String when,
  String zeitPunktArt = 'ABFAHRT',
  List<String> verkehrsmittel = const ['ALL'],
}) => {
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
      'verkehrsmittel': verkehrsmittel,
      'zeitWunsch': {'reiseDatum': when, 'zeitPunktArt': zeitPunktArt},
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
};

/// POST /mob/angebote/fahrplan and return `verbindungen`.
Future<List<Map<String, dynamic>>> _fahrplan(Map<String, dynamic> body) async {
  final r = await mobPost('angebote/fahrplan', _journeyMedia, body);
  r.raiseForStatus();
  return maps(r.jsonMap()['verbindungen']);
}

List<Map<String, dynamic>> _legsOf(Map<String, dynamic> c) =>
    maps(mapOf(c, 'verbindung')['verbindungsAbschnitte']);

/// POST /mob/location/search with locationTypes ALL.
Future<List<Map<String, dynamic>>> _locationSearch(String term) async {
  final r = await mobPost('location/search', _locationMedia, {
    'locationTypes': ['ALL'],
    'searchTerm': term,
  });
  r.raiseForStatus();
  final data = r.json();
  if (data is! List) return const [];
  return maps(data);
}

/// The important one: journeys WITH prices, replaces website fahrplan.
Future<String> checkVendoJourney() async {
  final conns = await _fahrplan(
    _searchBody(from: kielLoc, to: berlinLoc, when: _isoLocal(DateTime.now())),
  );
  if (conns.isEmpty) throw CheckError('no verbindungen returned');
  final c = conns.first;
  final legs = _legsOf(c);
  if (legs.isEmpty) throw CheckError('verbindung has no verbindungsAbschnitte');
  // price is best-effort (some legs are price-less), so only soft-check.
  final price = mapOf(
    mapOf(mapOf(mapOf(c, 'angebote'), 'preise'), 'gesamt'),
    'ab',
  )['betrag'];
  final priceTxt = price != null ? ', ab $price EUR' : ', no price';
  // Disruption-note containers the app reads (himNotizen / echtzeitNotizen,
  // at leg and stop level) must still be lists when present — the leg
  // disruption banner parses {text: ...} out of them.
  // Cancellation: a dropped stop carries `ersatzhaltNotiz` whose `typ` is
  // GECANCELT ("Halt entfällt") — vendo_service reads exactly that path to
  // flag JourneyLeg/LegStopover.cancelled, so guard its shape if present.
  var ersatzSeen = false;
  for (final leg in legs) {
    for (final fld in ['himNotizen', 'echtzeitNotizen']) {
      if (leg.containsKey(fld) && leg[fld] is! List) {
        throw CheckError('leg $fld is not a list');
      }
    }
    for (final h in maps(leg['halte'])) {
      if (h.containsKey('himNotizen') && h['himNotizen'] is! List) {
        throw CheckError('halt himNotizen is not a list');
      }
      final ez = h['ersatzhaltNotiz'];
      if (ez != null) {
        ersatzSeen = true;
        if (ez is! Map || !ez.containsKey('typ')) {
          throw CheckError("ersatzhaltNotiz lacks a 'typ' field");
        }
      }
    }
  }
  final ezTxt = ersatzSeen ? ', ersatzhaltNotiz shape ok' : '';
  return '${conns.length} journeys, first has ${legs.length} legs'
      '$priceTxt$ezTxt';
}

/// Street addresses and POIs come back from /mob/location/search.
///
/// The app searches with locationTypes ALL and shows ADR/POI hits alongside
/// stops, because a rider heading to an office has an address, not a stop
/// name. If DB ever stops answering with ADR entries — or drops the
/// coordinates / locationId the journey search needs — address routing
/// silently dies.
Future<String> checkVendoAddressSearch() async {
  final r = await mobPost('location/search', _locationMedia, {
    'locationTypes': ['ALL'],
    'searchTerm': preetzAddress,
  });
  r.raiseForStatus();
  final raw = r.json();
  if (raw is! List || raw.isEmpty) throw CheckError('expected non-empty list');
  final data = maps(raw);
  final addrs = data.where((o) => o['locationType'] == 'ADR').toList();
  if (addrs.isEmpty) {
    final types = {for (final o in data) '${o['locationType']}'}.toList()
      ..sort();
    throw CheckError(
      'no ADR hit for an address query (types: ${_pyList(types)})',
    );
  }
  final top = addrs.first;
  final name = '${top['name'] ?? ''}';
  if (!name.contains('Kieler Straße 30')) {
    throw CheckError(
      'top ADR is not the searched address: ${_repr(top['name'])}',
    );
  }
  final loc = '${top['locationId'] ?? ''}';
  if (!loc.startsWith('A=2@')) {
    throw CheckError(
      'ADR locationId is not an address handle: ${_repr(clip(loc, 40))}',
    );
  }
  final coords = mapOf(top, 'coordinates');
  if (!coords.containsKey('latitude') || !coords.containsKey('longitude')) {
    throw CheckError('ADR hit carries no coordinates');
  }
  // An ADR *does* carry an evaNr, but it is a pseudo id (98x…/99x… range for
  // addresses/POIs), not a station EVA: no departure board, no station map
  // behind it. That is why the app keys "is this a stop?" off locationType and
  // not off the presence of evaNr — this asserts the trap still looks the way
  // the app expects it to.
  final eva = '${top['evaNr'] ?? ''}';
  if (eva.isNotEmpty && !eva.startsWith('98') && !eva.startsWith('99')) {
    throw CheckError('ADR evaNr $eva looks like a real station EVA');
  }
  final lat = (coords['latitude'] as num).toStringAsFixed(5);
  final lon = (coords['longitude'] as num).toStringAsFixed(5);
  return "${addrs.length}/${data.length} ADR hits, top='$name' @$lat,$lon";
}

/// A named place ("Agentur für Arbeit Kiel") resolves as a POI.
Future<String> checkVendoPoiSearch() async {
  final data = await _locationSearch('Agentur für Arbeit Kiel');
  final pois = data.where((o) => o['locationType'] == 'POI').toList();
  if (pois.isEmpty) throw CheckError('no POI hit for a named place');
  final top = pois.first;
  final loc = '${top['locationId'] ?? ''}';
  if (!loc.startsWith('A=4@')) {
    throw CheckError(
      'POI locationId is not a POI handle: ${_repr(clip(loc, 40))}',
    );
  }
  return "${pois.length} POI hits, top='${top['name']}'";
}

/// Door-to-door: an ADR locationId works as a journey destination.
///
/// DB answers with a normal connection plus a FUSSWEG leg from the last stop
/// to the address itself — that walk is what replaces the maps app: it names
/// the stop to get off at (here "Gewerbegebiet, Preetz (Holstein)") and how
/// far it still is. Soft, because which stop wins depends on the departure the
/// backend happens to pick; the hard part (ADR accepted, journey ends at the
/// address on foot) is still asserted.
Future<String> checkVendoAddressJourney() async {
  final addrs = (await _locationSearch(
    preetzAddress,
  )).where((o) => o['locationType'] == 'ADR').toList();
  if (addrs.isEmpty) throw CheckError('no ADR hit to route to');
  final target = addrs.first;

  // Tomorrow 09:00 as an arrival deadline — an appointment, which is the
  // actual use case (and keeps the query off "right now, last bus already
  // gone").
  final conns = await _fahrplan(
    _searchBody(
      from: kielLoc,
      to: '${target['locationId']}',
      when: _isoLocal(_tomorrowAt(9)),
      zeitPunktArt: 'ANKUNFT',
    ),
  );
  if (conns.isEmpty) {
    throw CheckError('address destination returned no verbindungen');
  }

  final walks = <(String, num?)>[];
  for (final c in conns) {
    final legs = _legsOf(c);
    final last = legs.last;
    if (last['typ'] != 'FUSSWEG') {
      throw CheckError(
        'journey to an address does not end on foot '
        '(last leg typ=${_repr(last['typ'])})',
      );
    }
    final dest = '${mapOf(last, 'ankunftsOrt')['name'] ?? ''}';
    if (!dest.contains('Kieler Straße 30')) {
      throw CheckError('last leg does not end at the address: ${_repr(dest)}');
    }
    walks.add((
      '${mapOf(last, 'abgangsOrt')['name'] ?? ''}',
      last['distanz'] as num?,
    ));
  }

  // The point of the feature: at least one option drops the rider within
  // walking distance, and the app can name that stop.
  final withDist = walks.where((w) => w.$2 != null).toList();
  if (withDist.isEmpty) throw CheckError('no final walk carries a distance');
  final best = withDist.reduce((a, b) => b.$2! < a.$2! ? b : a);
  final near = walks.where((w) => w.$1 == preetzNearestStop).toList();
  final nearTxt = near.isNotEmpty
      ? ', $preetzNearestStop offered (${near.first.$2} m)'
      : ', nearest offered: ${best.$1} (${best.$2} m)';
  return '${conns.length} door-to-door journeys$nearTxt';
}

/// Split-ticket scope (#22): a leg's `halte` must be exactly the stretch the
/// rider travels, while /mob/zuglauf answers with the WHOLE train run.
///
/// The split candidates are built from the leg (utils/split_stops.dart), and
/// the connection-detail screen may hand over its cached run — which is then
/// cut down to the leg via the boarding/alighting `evaNr`. Two things have to
/// hold for that, and both are asserted here on Berlin Hbf → Braunschweig Hbf,
/// where the ICE carries on to München long after the rider gets off:
///
///   * the leg's halte stop AT the destination (they did not, in #22's
///     screenshot: it offered Berlin → Hildesheim on a Braunschweig trip),
///   * the leg's halte are a contiguous slice of the run's halte, keyed on
///     evaNr — otherwise the trim can't find the leg in the run and the app
///     silently falls back to the leg's own stops.
Future<String> checkVendoSplitScope() async {
  final conns = await _fahrplan(
    _searchBody(
      from: berlinLoc,
      to: braunschweigLoc,
      when: _isoLocal(_tomorrowAt(9)),
      verkehrsmittel: const ['HOCHGESCHWINDIGKEITSZUEGE'],
    ),
  );
  if (conns.isEmpty) throw CheckError('no Berlin → Braunschweig connections');

  // First direct ICE leg that carries a run id — that's the #22 case.
  Map<String, dynamic>? leg;
  String? zid;
  for (final c in conns) {
    final legs = _legsOf(c);
    if (legs.length != 1) continue;
    final l = legs.first;
    final id = (l['zuglaufId'] ?? l['risZuglaufId']) as String?;
    if (id != null && id.isNotEmpty) {
      leg = l;
      zid = id;
      break;
    }
  }
  if (leg == null || zid == null) {
    throw CheckError('no direct ICE leg with a zuglaufId');
  }

  final halte = maps(leg['halte']);
  final legIds = [for (final h in halte) '${mapOf(h, 'ort')['evaNr']}'];
  if (legIds.last != '8000049') {
    throw CheckError(
      'leg halte end at ${mapOf(halte.last, 'ort')['name']}, not the '
      'searched destination Braunschweig Hbf — the leg is NOT leg-scoped',
    );
  }

  final r = await mobGet('zuglauf/${Uri.encodeComponent(zid)}', zuglaufMedia);
  r.raiseForStatus();
  final runIds = [
    for (final h in maps(r.jsonMap()['halte'])) '${mapOf(h, 'ort')['evaNr']}',
  ];
  if (runIds.isEmpty) throw CheckError('zuglauf has no halte');
  if (!runIds.contains(legIds.first) || !runIds.contains(legIds.last)) {
    throw CheckError(
      'leg boarding/alighting evaNr absent from its own '
      "zuglauf — the trim to the ridden section can't key "
      'on evaNr any more',
    );
  }
  final board = runIds.indexOf(legIds.first);
  final alight = runIds.indexOf(legIds.last, board);
  if (alight < 0) {
    throw CheckError(
      'leg boarding/alighting evaNr absent from its own '
      "zuglauf — the trim to the ridden section can't key "
      'on evaNr any more',
    );
  }
  final slice = runIds.sublist(board, alight + 1);
  if (slice.join('|') != legIds.join('|')) {
    throw CheckError(
      'leg halte are not a contiguous slice of the run: '
      'leg=${_pyList(legIds)} vs run[$board:${alight + 1}]=${_pyList(slice)}',
    );
  }
  final past = runIds.length - 1 - alight;
  return '${leg['mitteltext']}: leg ${legIds.length} halte == run'
      "[$board:${alight + 1}], run has ${runIds.length} ($past past the "
      "rider's destination)";
}

/// Rescue option B (#26): get off earlier and go another way.
///
/// The feature rests on two properties of the journey search, and both fail
/// silently rather than loudly if DB changes them — the app would just stop
/// offering rescues, or worse, offer ones timed off the timetable while the
/// train is an hour down.
///
///   * a leg's intermediate `halte` carry their own arrival, with the realtime
///     one in `ezAnkunftsZeitpunkt`/`ezAnkunftsDatum` where it exists. The app
///     picks candidate exits by LIVE arrival (utils/earlier_alight.dart —
///     `AlightStop.arrival`); a plan-only halt list makes that impossible.
///   * an intermediate halt's `ort` is usable as a search origin: the whole
///     fan-out is one search per earlier stop, keyed on the halt's own
///     locationId/evaNr. If those stop round-tripping, every candidate search
///     returns nothing and option B quietly disappears.
///
/// Kiel → Berlin, whose ICE/IC legs have plenty of intermediate stops.
Future<String> checkVendoEarlierAlight() async {
  Future<List<Map<String, dynamic>>> search(
    String from,
    String to,
    DateTime at,
  ) => _fahrplan(_searchBody(from: from, to: to, when: _isoLocal(at)));

  final conns = await search(kielLoc, berlinLoc, _tomorrowAt(9));
  if (conns.isEmpty) throw CheckError('no Kiel → Berlin connections');

  // A train leg with intermediate stops = one you could get off early from.
  Map<String, dynamic>? leg;
  outer:
  for (final c in conns) {
    for (final l in _legsOf(c)) {
      if (l['typ'] == 'FUSSWEG') continue;
      if (maps(l['halte']).length >= 3) {
        leg = l;
        break outer;
      }
    }
  }
  if (leg == null) {
    throw CheckError(
      'no train leg with intermediate halte — the app has '
      'no earlier stop to offer as an exit',
    );
  }

  final halte = maps(leg['halte']);
  // Intermediate stops only: the first has no arrival (you board there) and
  // the last is the planned change, which is never an "earlier" exit.
  final inner = halte.sublist(1, halte.length - 1);
  bool has(Map<String, dynamic> h, String k) =>
      h[k] != null && h[k] != '' && h[k] != false;
  final timed = inner
      .where((h) => has(h, 'ankunftsZeitpunkt') || has(h, 'ankunftsDatum'))
      .toList();
  if (timed.isEmpty) {
    throw CheckError(
      'no intermediate halt carries an arrival time — picking an exit by '
      'live arrival is impossible',
    );
  }
  final ez = inner
      .where((h) => has(h, 'ezAnkunftsZeitpunkt') || has(h, 'ezAnkunftsDatum'))
      .length;

  // The exit must be usable as the origin of the next search.
  final exitHalt = timed.last;
  final ort = mapOf(exitHalt, 'ort');
  final locId = ort['locationId'];
  if (locId == null || locId == '') {
    throw CheckError(
      "halt ${ort['name']} has no locationId — it can't be searched from",
    );
  }
  final onward = await search(
    '$locId',
    berlinLoc,
    DateTime.now().add(const Duration(days: 1, hours: 11)),
  );
  if (onward.isEmpty) {
    throw CheckError(
      'no onward connections from the intermediate halt '
      '${ort['name']} — option B would find nothing',
    );
  }

  return '${leg['mitteltext']}: ${inner.length} intermediate halte '
      '(${timed.length} with arrival, $ez with realtime); '
      '${ort['name']} → Berlin re-searchable (${onward.length} conns)';
}

/// The `verkehrsmittel` filter must be honoured server-side.
///
/// Vendo returns a small window of the *best* connections, so on an ICE trunk
/// route like München–Augsburg an ["ALL"] search is 100% ICE even though REs
/// run every few minutes. Filtering client-side therefore yields an empty
/// list (issue #18) — the modes have to travel with the request.
///
/// Asserts the enum values (from the DB Navigator's `VerkehrsmittelModel`)
/// are still accepted and actually change the result set.
Future<String> checkVendoVerkehrsmittel() async {
  const nah = [
    'NAHVERKEHRSONSTIGEZUEGE',
    'SBAHNEN',
    'BUSSE',
    'UBAHN',
    'STRASSENBAHN',
    'SCHIFFE',
    'ANRUFPFLICHTIGEVERKEHRE',
  ];
  const fern = [
    'HOCHGESCHWINDIGKEITSZUEGE',
    'INTERCITYUNDEUROCITYZUEGE',
    'INTERREGIOUNDSCHNELLZUEGE',
  ];

  Future<List<String>> gattungen(List<String> vm) async {
    // Tomorrow, 09:MM:SS — Python only replaced hour/minute.
    final n = DateTime.now().add(const Duration(days: 1));
    final at = DateTime(n.year, n.month, n.day, 9, 0, n.second);
    final r = await mobPost(
      'angebote/fahrplan',
      _journeyMedia,
      _searchBody(
        from: munichLoc,
        to: augsburgLoc,
        when: _isoLocal(at),
        verkehrsmittel: vm,
      ),
    );
    if (r.status == 400) {
      throw CheckError(
        'verkehrsmittel ${_pyList(vm)} rejected (400) — enum changed, '
        're-extract VerkehrsmittelModel from the Navigator APK',
      );
    }
    r.raiseForStatus();
    final out = <String>[];
    for (final c in maps(r.jsonMap()['verbindungen'])) {
      for (final ab in _legsOf(c)) {
        if (ab['typ'] == 'FAHRZEUG') {
          final k = ab['kurztext'];
          out.add(k == null || k == '' ? '?' : '$k');
        }
      }
    }
    return out;
  }

  final nahG = await gattungen(nah);
  if (nahG.isEmpty) throw CheckError('Nahverkehr-only search returned no legs');
  if (nahG.any((g) => g.startsWith('ICE'))) {
    throw CheckError(
      'Nahverkehr-only search leaked Fernverkehr: ${_pyList(nahG)}',
    );
  }

  final fernG = await gattungen(fern);
  if (fernG.isEmpty) {
    throw CheckError('Fernverkehr-only search returned no legs');
  }
  if (!fernG.any((g) => g.startsWith('IC'))) {
    throw CheckError(
      'Fernverkehr-only search has no IC*/ICE: ${_pyList(fernG)}',
    );
  }

  List<String> sortedSet(List<String> xs) => xs.toSet().toList()..sort();
  return 'filter honoured — Nah=${_pyList(sortedSet(nahG))} '
      'Fern=${_pyList(sortedSet(fernG))}';
}
