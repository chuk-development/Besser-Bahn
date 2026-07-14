import 'dart:convert';
import 'dart:math';
import 'package:http/http.dart' as http;
import '../core/app_log.dart';
import '../models/station.dart';
import 'db_api_service.dart' show SegmentPrice;
import '../models/departure.dart';
import '../models/journey.dart';
import '../models/trip.dart';

/// Client for the DB Navigator mobile backend (`app.services-bahn.de/mob`).
///
/// This is the same API the official DB Navigator app uses. Unlike the
/// bahn.de website journey endpoint (`angebote/fahrplan`), it is NOT behind
/// Akamai bot management, so journey search *with prices* works from a plain
/// HTTP client. We use it as the primary journey path.
class VendoService {
  final http.Client _client = http.Client();

  static const _base = 'https://app.services-bahn.de/mob';
  static const _journeyMedia =
      'application/x.db.vendo.mob.verbindungssuche.v9+json';
  static const _locationMedia = 'application/x.db.vendo.mob.location.v3+json';
  static const _zuglaufMedia = 'application/x.db.vendo.mob.zuglauf.v2+json';
  static const _shareMedia =
      'application/x.db.vendo.mob.verbindungteilen.v1+json';
  static const _bahnhofstafelMedia =
      'application/x.db.vendo.mob.bahnhofstafeln.v2+json';

  final _rng = Random();

  Map<String, String> _headers(String media) => {
        'Accept': media,
        'Content-Type': media,
        'Accept-Language': 'de',
        'User-Agent': 'DBNavigator/Android/26.9.0',
        'X-App-Version': '26.9.0',
        'X-Correlation-ID': '${_uuid()}_${_uuid()}',
      };

  /// Search journeys with offers/prices. [fromLocationId]/[toLocationId] are the
  /// full HAFAS location strings ([Station.vendoLocationId]).
  Future<JourneyResult> searchJourneys({
    required String fromLocationId,
    required String toLocationId,
    DateTime? dateTime,
    bool isArrival = false,
    bool firstClass = false,
    String? context,
    // The travellers in DB's `reisendenProfil.reisende` shape — each
    // `{reisendenTyp, ermaessigungen:[...], alter?}`. Built from the
    // SearchParty (passengers, ages, bike/dog, BahnCards, SBA) so prices match
    // exactly what the user pays. Defaults to a single adult, no discount.
    List<Map<String, dynamic>>? reisende,
    bool deutschlandTicket = false,
  }) async {
    final reisendeJson = (reisende == null || reisende.isEmpty)
        ? [
            {
              'ermaessigungen': ['KEINE_ERMAESSIGUNG KLASSENLOS'],
              'reisendenTyp': 'ERWACHSENER',
            }
          ]
        : reisende;
    final body = {
      'autonomeReservierung': false,
      'einstiegsTypList': ['STANDARD'],
      'fahrverguenstigungen': {
        'deutschlandTicketVorhanden': deutschlandTicket,
        'nurDeutschlandTicketVerbindungen': false,
      },
      'klasse': firstClass ? 'KLASSE_1' : 'KLASSE_2',
      'reiseHin': {
        'wunsch': {
          'abgangsLocationId': fromLocationId,
          'alternativeHalteBerechnung': true,
          'verkehrsmittel': ['ALL'],
          'zeitWunsch': {
            'reiseDatum': _isoWithOffset(dateTime ?? DateTime.now()),
            'zeitPunktArt': isArrival ? 'ANKUNFT' : 'ABFAHRT',
          },
          'zielLocationId': toLocationId,
          // Earlier/later pagination: the DB Navigator backend returns
          // frueherContext/spaeterContext tokens; replaying one here scrolls
          // the result window. Field is `context` (English), not `kontext`.
          if (context != null) 'context': context,
        },
      },
      'reisendenProfil': {
        'reisende': reisendeJson,
      },
      'reservierungsKontingenteVorhanden': false,
    };

    final url = '$_base/angebote/fahrplan';
    AppLog.log('journey ${fromLocationId.split('@O=').last.split('@').first}'
        ' → ${toLocationId.split('@O=').last.split('@').first}', tag: 'vendo');
    AppLog.log('POST $url klasse=${firstClass ? 1 : 2} '
        'isArrival=$isArrival dt=${_isoWithOffset(dateTime ?? DateTime.now())}',
        tag: 'vendo');
    // NB: pass the body as BYTES, not a String. package:http appends
    // `; charset=utf-8` to the Content-Type of a String body, and the DB edge
    // exact-matches the vendo media type — the charset variant is rejected with
    // HTTP 405 (0B). Bytes leave the Content-Type header untouched.
    final res = await _client
        .post(Uri.parse(url),
            headers: _headers(_journeyMedia),
            body: utf8.encode(json.encode(body)))
        .timeout(const Duration(seconds: 12));
    AppLog.log('fahrplan HTTP ${res.statusCode} (${res.bodyBytes.length}B)',
        tag: 'vendo');
    if (res.statusCode != 200) {
      // Surface the upstream body — DB encodes the real reason (bot block,
      // bad location id, rate limit) in the JSON, not just the status code.
      final snippet = _snippet(res.bodyBytes);
      AppLog.log('fahrplan non-200 body: $snippet', tag: 'vendo');
      AppLog.log('fahrplan resp headers: ${res.headers}', tag: 'vendo');
      // Business-rule rejections (e.g. a wheelchair-place SBA in 1st class,
      // MDA-ERSTE-KLASSE-ROLLSTUHL) carry a ready-to-show German `anzeigeText`
      // — prefer that over the raw JSON so the party sheet gets actionable
      // feedback ("Bitte wählen Sie die 2. Klasse.").
      final friendly = _dbAnzeigeText(res.bodyBytes);
      throw VendoException(friendly ??
          'Vendo fahrplan HTTP ${res.statusCode}: $snippet');
    }
    final data = json.decode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    final conns = data['verbindungen'] as List<dynamic>? ?? [];
    AppLog.log('${conns.length} journeys parsed', tag: 'vendo');
    return JourneyResult(
      journeys: conns
          .whereType<Map<String, dynamic>>()
          .map(_parseConnection)
          .toList(),
      earlierRef: data['frueherContext'] as String?,
      laterRef: data['spaeterContext'] as String?,
    );
  }

  /// "Weitere Abfahrten" for ONE direct segment — the alternative trains of the
  /// same product group running [abgangs]→[ziel] around [ankunft]. Mirrors the
  /// DB Navigator `POST /mob/trip/weitereabfahrten` (each result is a one-leg
  /// trip). [context] paginates ("Mehr anzeigen") via the prior result's
  /// `spaeterContext`/`frueherContext`.
  Future<JourneyResult> fetchWeitereAbfahrten({
    required String abgangsLocationId,
    required String zielLocationId,
    required DateTime ankunft,
    required String produktGattungen,
    String? context,
    bool fahrradmitnahme = false,
  }) async {
    final body = {
      'wunsch': {
        'abgangsLocationId': abgangsLocationId,
        'alternativeHalteBerechnung': true,
        'fahrradmitnahme': fahrradmitnahme,
        'produktGattungen': produktGattungen,
        'zeitWunsch': {
          'reiseDatum': _isoWithOffset(ankunft),
          'zeitPunktArt': 'ANKUNFT',
        },
        'zielLocationId': zielLocationId,
        if (context != null) 'context': context,
      },
    };
    final url = '$_base/trip/weitereabfahrten';
    AppLog.log('weitereabfahrten gattung=$produktGattungen '
        'an=${_isoWithOffset(ankunft)}${context != null ? ' (mehr)' : ''}',
        tag: 'vendo');
    final res = await _client
        .post(Uri.parse(url),
            headers: _headers(_journeyMedia),
            body: utf8.encode(json.encode(body)))
        .timeout(const Duration(seconds: 12));
    AppLog.log('weitereabfahrten HTTP ${res.statusCode} '
        '(${res.bodyBytes.length}B)', tag: 'vendo');
    if (res.statusCode != 200) {
      throw VendoException('Vendo weitereabfahrten HTTP ${res.statusCode}: '
          '${_snippet(res.bodyBytes)}');
    }
    final data = json.decode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    final conns = data['verbindungen'] as List<dynamic>? ?? [];
    return JourneyResult(
      journeys: conns
          .whereType<Map<String, dynamic>>()
          .map(_parseConnection)
          .toList(),
      earlierRef: data['frueherContext'] as String?,
      laterRef: data['spaeterContext'] as String?,
    );
  }

  /// Map our internal HAFAS-style [product] back to the vendo product-group
  /// code `weitereabfahrten` expects (e.g. "regional" → "RB", an RE/RB train).
  static String produktGattungenFor(String? product) {
    switch (product) {
      case 'nationalExpress':
        return 'ICE';
      case 'national':
        return 'EC_IC';
      case 'regional':
      case 'regionalExp':
        return 'RB';
      case 'suburban':
        return 'SBAHN';
      case 'bus':
        return 'BUS';
      case 'subway':
        return 'U';
      case 'tram':
        return 'STR';
      case 'ferry':
        return 'SCHIFF';
      default:
        return 'ALL';
    }
  }

  /// Official bahn.de "Reise teilen" deep link for [journey] — the exact same
  /// `vbid` link the DB Navigator app produces. It opens the EXACT connection
  /// (all legs, this departure) on bahn.de, NOT a pre-filled search.
  ///
  /// Flow (mirrors the app): POST the connection's full HAFAS recon context
  /// (`GH`, == the search response's `verbindung.kontext`) to `/teilen`; the
  /// backend mints a short `vbid` that resolves to the journey. Returns null if
  /// the journey carries no recon context (then the caller should fall back to
  /// a pre-filled search link).
  // vbid links are stable per recon ctx — cache so "öffnen" and "teilen" of the
  // same connection mint the link once, not twice.
  final _shareCache = <String, String>{};

  Future<String?> shareJourney(Journey journey) async {
    final recon = journey.refreshToken;
    // `/teilen` needs the full HAFAS recon string. The `checksum` fallback we
    // also store in refreshToken (e.g. "43bc223b_3") is NOT a recon ctx — the
    // `¶` marker distinguishes them. Bail so the caller can use a search link.
    if (recon == null || !recon.contains('¶')) return null;
    final cached = _shareCache[recon];
    if (cached != null) return cached;

    final dep = journey.plannedDeparture ?? journey.departure;
    final body = <String, dynamic>{
      'GH': recon,
      if (dep != null) 'HD': _isoWithOffset(dep),
      'SO': journey.origin?.name ?? '',
      'ZO': journey.destination?.name ?? '',
    };
    final url = '$_base/angebote/verbindung/teilen';
    final res = await _client
        .post(Uri.parse(url),
            headers: _headers(_shareMedia),
            body: utf8.encode(json.encode(body)))
        .timeout(const Duration(seconds: 10));
    AppLog.log('teilen HTTP ${res.statusCode} (${res.bodyBytes.length}B)',
        tag: 'vendo');
    if (res.statusCode != 201 && res.statusCode != 200) {
      AppLog.log('teilen non-2xx body: ${_snippet(res.bodyBytes)}', tag: 'vendo');
      return null;
    }
    final data = json.decode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    final vbid = data['vbid'] as String?;
    if (vbid == null || vbid.isEmpty) return null;
    final link = 'https://www.bahn.de/buchung/start?vbid=$vbid';
    _shareCache[recon] = link;
    return link;
  }

  /// The exact track geometry (the rails the train actually runs on) for a
  /// train run, from the DB Navigator backend's `zuglauf` endpoint — the same
  /// source the official app uses to draw the route on its map.
  ///
  /// [zuglaufId] is the HAFAS-style run id (`2|#VN#1#ST#…`), i.e. a journey
  /// leg's `tripId` / the bahn.de departure `journeyId`. Returns the route as
  /// `{lat, lng}` points, or null if the backend carries no geometry.
  Future<List<Map<String, double>>?> fetchTripPolyline(String zuglaufId) async {
    final url = '$_base/zuglauf/${Uri.encodeComponent(zuglaufId)}';
    final res = await _client
        .get(Uri.parse(url), headers: _headers(_zuglaufMedia))
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) {
      throw VendoException('Vendo zuglauf HTTP ${res.statusCode}');
    }
    final data = json.decode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    final points = _parsePolyline(data);
    AppLog.log('zuglauf polyline ${points?.length ?? 0} pts', tag: 'vendo');
    return points;
  }

  /// Extract the flattened lat/lng track from a `zuglauf` response's
  /// `polylineGroup.polylineDesc[].coordinates`. Null when absent.
  List<Map<String, double>>? _parsePolyline(Map<String, dynamic> data) {
    final group = data['polylineGroup'] as Map<String, dynamic>?;
    final descs = group?['polylineDesc'] as List<dynamic>? ?? const [];
    final points = <Map<String, double>>[];
    for (final desc in descs.whereType<Map<String, dynamic>>()) {
      final coords = desc['coordinates'] as List<dynamic>? ?? const [];
      for (final c in coords.whereType<Map<String, dynamic>>()) {
        final lat = (c['latitude'] as num?)?.toDouble();
        final lng = (c['longitude'] as num?)?.toDouble();
        if (lat != null && lng != null) {
          points.add({'lat': lat, 'lng': lng});
        }
      }
    }
    return points.isEmpty ? null : points;
  }

  // ==========================================================================
  // DEPARTURE / ARRIVAL BOARD (Bahnhofstafel) — replaces the Akamai-blocked
  // bahn.de `reiseloesung/abfahrten|ankuenfte` GET endpoints.
  // POST /mob/bahnhofstafel/{abfahrt|ankunft}
  //   body {anfrageZeit "HH:MM", datum "YYYY-MM-DD", ursprungsBahnhofId <eva>,
  //         verkehrsmittel ["ALL"]}
  //   → {bahnhofstafel{Abfahrt|Ankunft}Positionen: [...]}
  // Each position carries a `zuglaufId` — the same id GET /mob/zuglauf/{id}
  // (and [getTrip]) consumes, so a board row taps straight through to detail.
  // ==========================================================================

  Future<List<Departure>> getDepartures(String evaId,
          {DateTime? when, int results = 40}) =>
      _fetchBoard(evaId, when: when, results: results, arrivals: false);

  Future<List<Departure>> getArrivals(String evaId,
          {DateTime? when, int results = 40}) =>
      _fetchBoard(evaId, when: when, results: results, arrivals: true);

  Future<List<Departure>> _fetchBoard(String evaId,
      {DateTime? when, int results = 40, required bool arrivals}) async {
    final now = when ?? DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final body = {
      'anfrageZeit': '${two(now.hour)}:${two(now.minute)}',
      'datum': '${now.year}-${two(now.month)}-${two(now.day)}',
      'ursprungsBahnhofId': evaId,
      'verkehrsmittel': ['ALL'],
    };
    final path = arrivals ? 'ankunft' : 'abfahrt';
    final res = await _client
        .post(Uri.parse('$_base/bahnhofstafel/$path'),
            headers: _headers(_bahnhofstafelMedia),
            // Bytes, not String — a charset param on Content-Type is rejected.
            body: utf8.encode(json.encode(body)))
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) {
      throw VendoException('Vendo bahnhofstafel/$path HTTP ${res.statusCode}');
    }
    final data = json.decode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    final key = arrivals
        ? 'bahnhofstafelAnkunftPositionen'
        : 'bahnhofstafelAbfahrtPositionen';
    final list = data[key] as List<dynamic>? ?? const [];
    return list
        .whereType<Map<String, dynamic>>()
        .take(results)
        .map((p) => _departureFromBoard(p, arrivals: arrivals))
        .toList();
  }

  Departure _departureFromBoard(Map<String, dynamic> p,
      {required bool arrivals}) {
    final planned =
        _parse(arrivals ? p['ankunftsDatum'] : p['abgangsDatum']);
    final actual =
        _parse(arrivals ? p['ezAnkunftsDatum'] : p['ezAbgangsDatum']) ??
            planned;
    final delay = (planned != null && actual != null)
        ? actual.difference(planned).inSeconds
        : null;
    final gattung = p['produktGattung'] as String? ?? '';
    // `gleis` is the timetabled platform, `ezGleis` the realtime one — only
    // sent when they differ. Keeping both apart is what makes a Gleiswechsel
    // detectable; collapsing them onto one field hides it (#16).
    final gleis = p['gleis'] as String?;
    final ezGleis = p['ezGleis'] as String?;
    // Departures label the destination (`richtung`); arrivals label the origin
    // (`abgangsOrt`) — the board shows "from …" for an incoming train.
    final direction = arrivals
        ? ((p['abgangsOrt'] as Map<String, dynamic>?)?['name'] as String? ?? '')
        : (p['richtung'] as String? ?? '');
    final notes = (p['echtzeitNotizen'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map((m) => m['text'] as String? ?? '')
        .where((s) => s.isNotEmpty)
        .toList();
    return Departure(
      tripId: p['zuglaufId'] as String? ?? '',
      stop: _stationFromVendo(p['abfrageOrt'] as Map<String, dynamic>? ?? const {}),
      when: actual ?? planned,
      plannedWhen: planned,
      delay: delay,
      platform: ezGleis ?? gleis,
      plannedPlatform: gleis,
      direction: direction,
      line: TransitLine(
        name: p['mitteltext'] as String? ??
            p['kurztext'] as String? ??
            gattung,
        fahrtNr: p['zugnummer']?.toString() ??
            p['verkehrsmittelNummer'] as String? ??
            '',
        productName: p['kurztext'] as String? ?? gattung,
        product: _mapProduct(gattung),
      ),
      cancelled: false,
      remarks: notes,
    );
  }

  // ==========================================================================
  // TRIP DETAIL (Zugverlauf) — GET /mob/zuglauf/{zuglaufId}. Replaces the
  // Akamai-blocked bahn.de `reiseloesung/fahrt`. One call yields the stop list
  // (times/platform/occupancy/coords), train-wide attributes AND the exact
  // track polyline, so the map needs no second request.
  // ==========================================================================

  Future<Trip> getTrip(String zuglaufId) async {
    final url = '$_base/zuglauf/${Uri.encodeComponent(zuglaufId)}';
    final res = await _client
        .get(Uri.parse(url), headers: _headers(_zuglaufMedia))
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) {
      throw VendoException('Vendo zuglauf HTTP ${res.statusCode}');
    }
    final data = json.decode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    return _parseTripFromZuglauf(data, zuglaufId);
  }

  Trip _parseTripFromZuglauf(Map<String, dynamic> data, String zuglaufId) {
    final halte = data['halte'] as List<dynamic>? ?? const [];
    final stopovers = halte
        .whereType<Map<String, dynamic>>()
        .map(_stopoverFromZuglauf)
        .toList();

    final gattung = data['produktGattung'] as String? ?? '';
    final zugnummer = data['zugnummer']?.toString() ?? '';
    final displayName = (data['mitteltext'] as String?)?.trim().isNotEmpty == true
        ? data['mitteltext'] as String
        : '$gattung $zugnummer'.trim();

    final origin = stopovers.isNotEmpty
        ? stopovers.first.stop
        : const Station(id: '', name: '');
    final dest = stopovers.length > 1 ? stopovers.last.stop : origin;

    final attributes = (data['attributNotizen'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(_tripAttrFromNotiz)
        .toList();

    return Trip(
      id: zuglaufId,
      line: TransitLine(
        name: displayName,
        fahrtNr: zugnummer,
        productName: data['kurztext'] as String? ?? gattung,
        product: _mapProduct(gattung),
      ),
      direction: dest.name,
      origin: origin,
      destination: dest,
      stopovers: stopovers,
      attributes: attributes,
      polyline: _parsePolyline(data),
    );
  }

  Stopover _stopoverFromZuglauf(Map<String, dynamic> h) {
    final plannedDep = _parse(h['abgangsDatum']);
    final actualDep = _parse(h['ezAbgangsDatum']) ?? plannedDep;
    final plannedArr = _parse(h['ankunftsDatum']);
    final actualArr = _parse(h['ezAnkunftsDatum']) ?? plannedArr;
    final gleis = h['gleis'] as String?;
    final ezGleis = h['ezGleis'] as String?;
    return Stopover(
      stop: _stationFromVendo(h['ort'] as Map<String, dynamic>? ?? const {}),
      departure: actualDep,
      plannedDeparture: plannedDep,
      departureDelay: (plannedDep != null && actualDep != null)
          ? actualDep.difference(plannedDep).inSeconds
          : null,
      arrival: actualArr,
      plannedArrival: plannedArr,
      arrivalDelay: (plannedArr != null && actualArr != null)
          ? actualArr.difference(plannedArr).inSeconds
          : null,
      departurePlatform: ezGleis ?? gleis,
      plannedDeparturePlatform: gleis,
      arrivalPlatform: ezGleis ?? gleis,
      plannedArrivalPlatform: gleis,
      cancelled: _haltCancelled(h),
      occupancy: _occupancyFrom(h['auslastungsInfos'] as List<dynamic>?),
    );
  }

  /// Map a vendo `attributNotiz` ({key, text, priority}) to a [TripAttribute].
  /// The train-detail UI keys its bike/wheelchair icons off `kategorie`, which
  /// vendo doesn't send — so derive it from the well-known short codes (FB/…
  /// bike, RO/RG/OC/RS wheelchair). Amenity codes (EH/KL/WLAN/BR) are matched
  /// by `key` downstream, so those pass through with an empty kategorie.
  TripAttribute _tripAttrFromNotiz(Map<String, dynamic> n) {
    final key = (n['key'] as String? ?? '').toUpperCase();
    String kategorie = '';
    if (const {'FB', 'FK', 'FR', 'FH'}.contains(key)) {
      kategorie = 'FAHRRADMITNAHME';
    } else if (const {'RO', 'RG', 'OC', 'RS'}.contains(key)) {
      kategorie = 'BARRIEREFREI';
    }
    return TripAttribute(
      kategorie: kategorie,
      key: key,
      value: n['text'] as String? ?? '',
    );
  }

  /// DB `auslastungsInfos` (per stop) → 2nd-class [OccupancyLevel], reusing the
  /// shared `stufe` mapping. Shape: `[{klasse: KLASSE_2, stufe: 1}]`.
  OccupancyLevel _occupancyFrom(List<dynamic>? infos) {
    if (infos == null) return OccupancyLevel.unknown;
    for (final i in infos.whereType<Map<String, dynamic>>()) {
      if (i['klasse'] == 'KLASSE_2') return _stufe(i['stufe'] as int?);
    }
    return OccupancyLevel.unknown;
  }

  /// Cheapest price for one split-ticket segment, via the vendo journey API
  /// (the website price endpoint is Akamai-blocked). [from]/[to] may be full
  /// HAFAS location strings or bare EVA numbers.
  Future<SegmentPrice> getSegmentPrice({
    required String from,
    required String to,
    DateTime? dateTime,
    bool deutschlandTicket = false,
    bool firstClass = false,
    String ermaessigung = 'KEINE_ERMAESSIGUNG KLASSENLOS',
    // The actual passenger profile (age + type + BahnCard) from the search
    // party. When given it drives the price so youth/child fares match what the
    // user sees in the DB app — instead of always pricing an adult. Falls back
    // to a single adult with [ermaessigung] when omitted.
    List<Map<String, dynamic>>? reisende,
  }) async {
    try {
      final result = await searchJourneys(
        fromLocationId: _loc(from),
        toLocationId: _loc(to),
        dateTime: dateTime,
        firstClass: firstClass,
        reisende: reisende ??
            [
              {
                'reisendenTyp': 'ERWACHSENER',
                'ermaessigungen': [ermaessigung],
              }
            ],
        deutschlandTicket: deutschlandTicket,
      );
      if (result.journeys.isEmpty) {
        return const SegmentPrice(price: double.infinity, isDTicketCovered: false);
      }

      // D-Ticket covers a segment if some connection is purely local/regional.
      if (deutschlandTicket) {
        final covered = result.journeys.any((j) => j.legs
            .where((l) => !l.isWalking)
            .every((l) => _isLocal(l.line?.product)));
        if (covered) {
          return const SegmentPrice(price: 0.0, isDTicketCovered: true);
        }
      }

      final prices = result.journeys
          .map((j) => j.price?.amount)
          .whereType<double>()
          .toList();
      if (prices.isEmpty) {
        return const SegmentPrice(price: double.infinity, isDTicketCovered: false);
      }
      return SegmentPrice(
        price: prices.reduce((a, b) => a < b ? a : b),
        isDTicketCovered: false,
      );
    } catch (e) {
      AppLog.log('segment price failed ($e)', tag: 'vendo');
      return const SegmentPrice(price: double.infinity, isDTicketCovered: false);
    }
  }

  bool _isLocal(String? product) =>
      product == null ||
      const {'regional', 'suburban', 'subway', 'tram', 'bus', 'ferry'}
          .contains(product);

  String _loc(String id) => id.contains('@') ? id : 'A=1@L=$id@';

  /// First ~300 chars of a response body, for error logging.
  /// DB error bodies look like
  /// `{"code":"FACHLICH","details":{"anzeigeText":"…"},"status":"ERROR"}`.
  /// Pull out the user-facing `anzeigeText` if present.
  String? _dbAnzeigeText(List<int> bytes) {
    try {
      final j = json.decode(utf8.decode(bytes));
      if (j is Map<String, dynamic>) {
        final details = j['details'];
        if (details is Map<String, dynamic>) {
          final text = details['anzeigeText'];
          if (text is String && text.trim().isNotEmpty) return text.trim();
        }
      }
    } catch (_) {}
    return null;
  }

  String _snippet(List<int> bytes) {
    try {
      final s = utf8.decode(bytes).replaceAll(RegExp(r'\s+'), ' ').trim();
      return s.length > 300 ? '${s.substring(0, 300)}…' : s;
    } catch (_) {
      return '<${bytes.length}B non-utf8>';
    }
  }

  /// Vendo location search — returns stations carrying their full locationId.
  Future<List<Station>> searchLocations(String query) async {
    final res = await _client.post(
      Uri.parse('$_base/location/search'),
      headers: _headers(_locationMedia),
      // Bytes, not String — see the note in searchJourneys (charset → 405).
      body: utf8.encode(
          json.encode({'locationTypes': ['ALL'], 'searchTerm': query})),
    );
    if (res.statusCode != 200) return [];
    final data = json.decode(utf8.decode(res.bodyBytes));
    if (data is! List) return [];
    return data
        .whereType<Map<String, dynamic>>()
        // Stations only (locationType 'ST') — the app searches for stops, not
        // addresses/POIs, and downstream boards need a station EVA.
        .where((o) => o['locationType'] == 'ST')
        .map(_stationFromVendo)
        .toList();
  }

  /// Stations near a coordinate — `POST /mob/location/nearby/bytypes`. The
  /// coordinates go inside an `area`, and `types`/`operatingSystem` are
  /// required (that request shape, reverse-engineered from the DB Navigator
  /// APK, is why the older `/mob/location/nearby` guesses all 400'd). Response
  /// is `{fahrplanAuskunftLocations: [...]}` in the same item shape as search.
  Future<List<Station>> nearbyStations({
    required double latitude,
    required double longitude,
    int radius = 2000,
    int maxResults = 8,
  }) async {
    final res = await _client.post(
      Uri.parse('$_base/location/nearby/bytypes'),
      headers: _headers(_locationMedia),
      body: utf8.encode(json.encode({
        'area': {
          'coordinates': {'latitude': latitude, 'longitude': longitude},
          'radius': radius,
        },
        'maxResults': maxResults,
        'operatingSystem': 'ANDROID',
        'products': ['ALL'],
        'types': ['ST'],
      })),
    );
    if (res.statusCode != 200) return [];
    final data = json.decode(utf8.decode(res.bodyBytes));
    final locs = (data is Map<String, dynamic>
        ? data['fahrplanAuskunftLocations']
        : null) as List<dynamic>? ?? const [];
    return locs.whereType<Map<String, dynamic>>().map(_stationFromVendo).toList();
  }

  // -- parsing ---------------------------------------------------------------

  /// Public entry to the connection parser — accepts a raw vendo `verbindung`
  /// wrapper (e.g. `reise.reiseInfos.verbindung` from a booked ticket) and
  /// returns a parsed [Journey] usable by the same UI as a search result.
  Journey parseConnection(Map<String, dynamic> c) => _parseConnection(c);

  Journey _parseConnection(Map<String, dynamic> c) {
    // /angebote/fahrplan wraps the connection in `verbindung`; the
    // /trip/weitereabfahrten response puts the same fields directly on the
    // connection object — fall back to `c` so both shapes parse.
    final vb = c['verbindung'] as Map<String, dynamic>? ?? c;
    final abschnitte = vb['verbindungsAbschnitte'] as List<dynamic>? ?? [];
    final legs = abschnitte
        .whereType<Map<String, dynamic>>()
        .map(_parseLeg)
        .toList();

    JourneyPrice? price;
    final preise = (c['angebote'] as Map<String, dynamic>?)?['preise']
        as Map<String, dynamic>?;
    final ab = ((preise?['gesamt'] as Map<String, dynamic>?)?['ab'])
        as Map<String, dynamic>?;
    final betrag = (ab?['betrag'] as num?)?.toDouble();
    if (betrag != null) {
      price = JourneyPrice(
          amount: betrag, currency: ab?['waehrung'] as String? ?? 'EUR');
    }

    return Journey(
      legs: legs,
      refreshToken: vb['kontext'] as String? ?? vb['checksum'] as String?,
      price: price,
    );
  }

  JourneyLeg _parseLeg(Map<String, dynamic> a) {
    final isWalking = a['typ'] == 'FUSSWEG';
    final origin = _stationFromVendo(
        a['abgangsOrt'] as Map<String, dynamic>? ?? const {});
    final dest = _stationFromVendo(
        a['ankunftsOrt'] as Map<String, dynamic>? ?? const {});

    final plannedDep = _parse(a['abgangsDatum']);
    final actualDep = _parse(a['ezAbgangsDatum']) ?? plannedDep;
    final plannedArr = _parse(a['ankunftsDatum']);
    final actualArr = _parse(a['ezAnkunftsDatum']) ?? plannedArr;

    final halte = a['halte'] as List<dynamic>? ?? [];
    final stopovers = halte
        .whereType<Map<String, dynamic>>()
        .map(_parseStopover)
        .toList();

    // The leg is unusable when the boarding (first) or alighting (last) stop of
    // this segment is dropped — you can't get on, or can't get off here. A
    // dropped intermediate stop alone is a Teilausfall, surfaced per-stopover.
    // DB also signals a fully-cancelled run with a high-priority realtime note
    // whose text says the train "fällt aus" — catch that too (verified: a fully
    // cancelled run comes back with every halt GECANCELT, the note is the
    // belt-and-braces case). himNotizen are NOT used here: their construction
    // texts mention generic "Zugausfälle" without this leg being cancelled.
    final ezAusfall = (a['echtzeitNotizen'] as List<dynamic>? ?? [])
        .whereType<Map<String, dynamic>>()
        .any((n) =>
            (n['text'] as String?)?.toLowerCase().contains('fällt aus') ??
            false);
    final cancelled = (stopovers.isNotEmpty &&
            (stopovers.first.cancelled || stopovers.last.cancelled)) ||
        ezAusfall;

    // Disruption notes: HIM messages (construction, broken lifts, …) and
    // realtime notes ("Reparatur an der Strecke"), from the leg and its stops.
    // attributNotizen (amenities/reservation hints) are intentionally excluded.
    final disruptions = <String>[];
    void collect(dynamic list) {
      if (list is! List) return;
      for (final n in list.whereType<Map<String, dynamic>>()) {
        final t = (n['text'] as String?)?.trim();
        if (t != null && t.isNotEmpty && !disruptions.contains(t)) {
          disruptions.add(t);
        }
      }
    }

    collect(a['himNotizen']);
    collect(a['echtzeitNotizen']);
    for (final h in halte.whereType<Map<String, dynamic>>()) {
      collect(h['himNotizen']);
    }

    String? depPlatform;
    String? plannedDepPlatform;
    String? arrPlatform;
    String? plannedArrPlatform;
    if (stopovers.isNotEmpty) {
      final first = halte.first as Map;
      final last = halte.last as Map;
      plannedDepPlatform = first['gleis'] as String?;
      depPlatform = first['ezGleis'] as String? ?? plannedDepPlatform;
      plannedArrPlatform = last['gleis'] as String?;
      arrPlatform = last['ezGleis'] as String? ?? plannedArrPlatform;
    }

    TransitLine? line;
    if (!isWalking) {
      line = TransitLine(
        name: a['mitteltext'] as String? ?? a['kurztext'] as String? ?? '',
        fahrtNr: (a['zugNummer'] ?? a['verkehrsmittelNummer'] ?? '').toString(),
        productName: a['kurztext'] as String? ?? '',
        product: _mapProduct(a['produktGattung'] as String?),
      );
    }

    return JourneyLeg(
      tripId: a['zuglaufId'] as String? ?? a['risZuglaufId'] as String?,
      origin: origin,
      destination: dest,
      departure: actualDep,
      plannedDeparture: plannedDep,
      departureDelay: _delay(plannedDep, actualDep),
      departurePlatform: depPlatform,
      plannedDeparturePlatform: plannedDepPlatform,
      arrival: actualArr,
      plannedArrival: plannedArr,
      arrivalDelay: _delay(plannedArr, actualArr),
      arrivalPlatform: arrPlatform,
      plannedArrivalPlatform: plannedArrPlatform,
      line: line,
      direction: a['richtung'] as String?,
      isWalking: isWalking,
      cancelled: cancelled,
      stopovers: stopovers,
      occupancy: _occupancy(a['auslastungsInfos'] as List<dynamic>?),
      disruptions: disruptions,
    );
  }

  LegStopover _parseStopover(Map<String, dynamic> h) {
    return LegStopover(
      stop: _stationFromVendo(h['ort'] as Map<String, dynamic>? ?? const {}),
      arrival: _parse(h['ezAnkunftsDatum']) ?? _parse(h['ankunftsDatum']),
      departure: _parse(h['ezAbgangsDatum']) ?? _parse(h['abgangsDatum']),
      cancelled: _haltCancelled(h),
    );
  }

  /// A stop is dropped when DB attaches an `ersatzhaltNotiz` of type
  /// `GECANCELT` ("Halt entfällt"). Other types (e.g. an additional/replacement
  /// stop) are not cancellations.
  static bool _haltCancelled(Map<String, dynamic> h) =>
      (h['ersatzhaltNotiz'] as Map<String, dynamic>?)?['typ'] == 'GECANCELT';

  Station _stationFromVendo(Map<String, dynamic> ort) {
    // Journey halte/legs nest coords under `position`; the location-search
    // endpoint uses `coordinates` — accept either.
    final pos = (ort['position'] ?? ort['coordinates']) as Map<String, dynamic>?;
    final loc = ort['locationId'] as String?;
    return Station(
      id: (ort['evaNr'] ?? '').toString(),
      name: ort['name'] as String? ?? '',
      latitude: (pos?['latitude'] as num?)?.toDouble(),
      longitude: (pos?['longitude'] as num?)?.toDouble(),
      locationId: (loc != null && loc.contains('@')) ? loc : null,
    );
  }

  OccupancyInfo? _occupancy(List<dynamic>? infos) {
    if (infos == null) return null;
    for (final i in infos.whereType<Map<String, dynamic>>()) {
      if (i['klasse'] == 'KLASSE_2') {
        return OccupancyInfo(level: _stufe(i['stufe'] as int?));
      }
    }
    return null;
  }

  OccupancyLevel _stufe(int? stufe) {
    switch (stufe) {
      case 1:
        return OccupancyLevel.low;
      case 2:
        return OccupancyLevel.medium;
      case 3:
        return OccupancyLevel.high;
      case 4:
        return OccupancyLevel.veryHigh;
      default:
        return OccupancyLevel.unknown;
    }
  }

  String _mapProduct(String? gattung) {
    switch (gattung) {
      case 'ICE':
        return 'nationalExpress';
      case 'IC':
      case 'EC':
      case 'EC_IC':
        return 'national';
      case 'IR':
        return 'regional';
      case 'RB':
      case 'RE':
      case 'REGIONAL':
        return 'regional';
      case 'S':
      case 'SBAHN':
        return 'suburban';
      case 'BUS':
      case 'SONSTIGE': // long-distance Fernbus (Flixbus) — no rail category
        return 'bus';
      case 'U':
      case 'UBAHN':
        return 'subway';
      case 'STR':
      case 'TRAM':
        return 'tram';
      case 'SCHIFF':
        return 'ferry';
      default:
        return 'regional';
    }
  }

  int? _delay(DateTime? planned, DateTime? actual) {
    if (planned == null || actual == null) return null;
    return actual.difference(planned).inSeconds;
  }

  DateTime? _parse(dynamic v) =>
      v is String ? DateTime.tryParse(v)?.toLocal() : null;

  /// ISO-8601 with the local UTC offset, as the DB Navigator app sends.
  String _isoWithOffset(DateTime dt) {
    final l = dt.toLocal();
    final off = l.timeZoneOffset;
    final sign = off.isNegative ? '-' : '+';
    final h = off.inHours.abs().toString().padLeft(2, '0');
    final m = (off.inMinutes.abs() % 60).toString().padLeft(2, '0');
    final base = l.toIso8601String().split('.').first;
    return '$base$sign$h:$m';
  }

  String _uuid() {
    final b = List<int>.generate(16, (_) => _rng.nextInt(256));
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    String hex(int x) => x.toRadixString(16).padLeft(2, '0');
    final s = b.map(hex).join();
    return '${s.substring(0, 8)}-${s.substring(8, 12)}-${s.substring(12, 16)}'
        '-${s.substring(16, 20)}-${s.substring(20)}';
  }

  void dispose() => _client.close();
}

class VendoException implements Exception {
  final String message;
  const VendoException(this.message);
  @override
  String toString() => message;
}
