import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:http/http.dart' as http;
import '../core/app_log.dart';
import '../models/station.dart';
import 'db_api_service.dart' show SegmentPrice;
import '../models/best_price.dart';
import '../models/walking_route.dart';
import '../models/departure.dart';
import '../models/journey.dart';
import '../models/trip.dart';

/// Client for the DB Navigator mobile backend (`app.services-bahn.de/mob`).
///
/// This is the same API the official DB Navigator app uses. Unlike the
/// bahn.de website journey endpoint (`angebote/fahrplan`), it is NOT behind
/// Akamai bot management, so journey search *with prices* works from a plain
/// HTTP client. We use it as the primary journey path.
/// Caps how many requests may be in flight at once, queueing the rest.
///
/// The vendo backend rate-limits per client, so a burst of parallel calls
/// doesn't just queue — it gets everything after the limit rejected with 429.
/// Spending a little latency to stay under the limit beats failing fast (#14).
class _RequestGate {
  _RequestGate(this.maxConcurrent);

  final int maxConcurrent;
  int _active = 0;
  final _queue = <Completer<void>>[];

  Future<T> run<T>(Future<T> Function() task) async {
    if (_active >= maxConcurrent) {
      final waiter = Completer<void>();
      _queue.add(waiter);
      await waiter.future;
    }
    _active++;
    try {
      return await task();
    } finally {
      _active--;
      if (_queue.isNotEmpty) _queue.removeAt(0).complete();
    }
  }
}

class VendoService {
  /// [client] is injectable so tests can drive the 429/retry path without a
  /// network; production uses a plain client.
  VendoService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  /// Static: one gate for the whole app, since the limit is per client, not
  /// per service instance.
  static final _zuglaufGate = _RequestGate(3);
  static const _maxRetries = 2;

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
    // Vendo `VerkehrsmittelModel` values (see [ProductCategory.vendoCodes]).
    // The filter MUST travel with the request: the backend returns a small
    // window of the *best* connections, so on a route like München–Augsburg
    // every result is an ICE. Filtering those out client-side leaves an empty
    // list while the REs the user asked for were never fetched. Null/empty →
    // ['ALL'].
    List<String>? verkehrsmittel,
    bool nurDeutschlandTicketVerbindungen = false,
    // Minimum transfer time in minutes (`minUmstiegsdauer`). Enforced by the
    // backend — asking for 45 on Kiel–Augsburg turns 5-minute changes into
    // 46+ ones. Without it the transfer profile can only warn about a gap it
    // was handed, instead of asking for connections the rider can make.
    int? minTransferMinutes,
    // Cap on the number of changes (`maxUmstiege`). 0 = direct trains only.
    // Note the backend answers an impossible cap with an empty list rather
    // than an error.
    int? maxTransfers,
    // Stations the route must touch (`viaLocations`), each
    // `{locationId, minUmstiegsdauer?}` — see [SearchOptions.viaLocationsJson].
    // A via is "passed through", not necessarily changed at; its own
    // minUmstiegsdauer applies only where the rider does change there.
    List<Map<String, dynamic>>? viaLocations,
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
        'nurDeutschlandTicketVerbindungen': nurDeutschlandTicketVerbindungen,
      },
      'klasse': firstClass ? 'KLASSE_1' : 'KLASSE_2',
      'reiseHin': {
        'wunsch': {
          'abgangsLocationId': fromLocationId,
          'alternativeHalteBerechnung': true,
          'verkehrsmittel': (verkehrsmittel == null || verkehrsmittel.isEmpty)
              ? const ['ALL']
              : verkehrsmittel,
          'zeitWunsch': {
            'reiseDatum': _isoWithOffset(dateTime ?? DateTime.now()),
            'zeitPunktArt': isArrival ? 'ANKUNFT' : 'ABFAHRT',
          },
          'zielLocationId': toLocationId,
          if (minTransferMinutes != null)
            'minUmstiegsdauer': minTransferMinutes,
          if (maxTransfers != null) 'maxUmstiege': maxTransfers,
          if (viaLocations != null && viaLocations.isNotEmpty)
            'viaLocations': viaLocations,
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
          .map((c) => _parseConnection(c, firstClass: firstClass))
          .toList(),
      earlierRef: data['frueherContext'] as String?,
      laterRef: data['spaeterContext'] as String?,
    );
  }

  /// The real walking route between two points — the way you'd actually walk
  /// it, not the straight line through the buildings
  /// (`POST /mob/location/calculateroute`, #21).
  ///
  /// Deliberately does NOT ask for `desiredCoordinateType: WKB`: without it the
  /// same response carries the polyline as plain `gpsPositions` JSON — verified
  /// identical, 28 points either way — so there is nothing to decode. The
  /// `distance`/`traveltime` come along regardless (Köln Hbf → 200 m south:
  /// 683 m, 492 s — the walk, not the 200 m as the crow flies).
  ///
  /// Returns null when DB can't route between the two points, which is a normal
  /// answer, not an error: the caller falls back to the straight line.
  Future<WalkingRoute?> calculateWalkingRoute({
    required double fromLat,
    required double fromLon,
    required double toLat,
    required double toLon,
  }) async {
    final body = {
      'gpsPositions': [
        {'latitude': fromLat, 'longitude': fromLon},
        {'latitude': toLat, 'longitude': toLon},
      ],
    };
    final url = '$_base/location/calculateroute';
    final res = await _client
        .post(Uri.parse(url),
            headers: _headers(_locationMedia),
            body: utf8.encode(json.encode(body)))
        .timeout(const Duration(seconds: 10));
    AppLog.log('calculateroute HTTP ${res.statusCode} '
        '(${res.bodyBytes.length}B)', tag: 'vendo');
    if (res.statusCode != 200) {
      // A route that can't be computed is not worth an exception — the map is
      // useful without it.
      AppLog.log('calculateroute failed: ${_snippet(res.bodyBytes)}',
          tag: 'vendo');
      return null;
    }
    final data = json.decode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    final points = (data['gpsPositions'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map((p) => (
              lat: (p['latitude'] as num?)?.toDouble(),
              lon: (p['longitude'] as num?)?.toDouble(),
            ))
        .where((p) => p.lat != null && p.lon != null)
        .map((p) => WalkingPoint(p.lat!, p.lon!))
        .toList();
    // Fewer than two points is not a line. A two-point answer is kept: it
    // looks like the straight line, but `distance`/`traveltime` are still DB's
    // real routed numbers, and those are most of the value here.
    if (points.length < 2) return null;
    return WalkingRoute(
      points: points,
      distanceMetres: (data['distance'] as num?)?.toInt(),
      duration: _seconds(data['traveltime']),
    );
  }

  /// The Bestpreis calendar for ONE day: what the trip costs at each time of
  /// day, in a single request (`POST /mob/angebote/tagesbestpreis`, #21).
  ///
  /// Same media type and body as the journey search, minus the pagination
  /// context. Each interval carries its cheapest `angebotsPreis` plus the full
  /// connections behind it — `kontext` included, so what comes back here is a
  /// [Journey] like any other and detail/share/split need no special case.
  ///
  /// The alternative is roughly six paginated searches against a backend that
  /// 429s a client for ~4 minutes after about ten requests in six seconds.
  Future<BestPriceDay> fetchBestPrices({
    required String fromLocationId,
    required String toLocationId,
    required DateTime date,
    bool firstClass = false,
    List<Map<String, dynamic>>? reisende,
    bool deutschlandTicket = false,
    List<String>? verkehrsmittel,
    bool nurDeutschlandTicketVerbindungen = false,
  }) async {
    // Midnight: the endpoint prices the whole DAY, so the time of day in the
    // request is noise — pinning it makes the result cacheable and identical
    // no matter when the user opened the sheet.
    final day = DateTime(date.year, date.month, date.day);
    final body = {
      'autonomeReservierung': false,
      'einstiegsTypList': ['STANDARD'],
      'fahrverguenstigungen': {
        'deutschlandTicketVorhanden': deutschlandTicket,
        'nurDeutschlandTicketVerbindungen': nurDeutschlandTicketVerbindungen,
      },
      'klasse': firstClass ? 'KLASSE_1' : 'KLASSE_2',
      'reiseHin': {
        'wunsch': {
          'abgangsLocationId': fromLocationId,
          'alternativeHalteBerechnung': true,
          'verkehrsmittel': (verkehrsmittel == null || verkehrsmittel.isEmpty)
              ? const ['ALL']
              : verkehrsmittel,
          'zeitWunsch': {
            'reiseDatum': _isoWithOffset(day),
            'zeitPunktArt': 'ABFAHRT',
          },
          'zielLocationId': toLocationId,
        },
      },
      'reisendenProfil': {
        'reisende': (reisende == null || reisende.isEmpty)
            ? [
                {
                  'ermaessigungen': ['KEINE_ERMAESSIGUNG KLASSENLOS'],
                  'reisendenTyp': 'ERWACHSENER',
                }
              ]
            : reisende,
      },
      'reservierungsKontingenteVorhanden': false,
    };

    final url = '$_base/angebote/tagesbestpreis';
    AppLog.log('POST $url day=${_isoWithOffset(day)} '
        'klasse=${firstClass ? 1 : 2}', tag: 'vendo');
    // Bytes, not a String — see searchJourneys: a charset on the vendo media
    // type is rejected with a 405.
    final res = await _client
        .post(Uri.parse(url),
            headers: _headers(_journeyMedia),
            body: utf8.encode(json.encode(body)))
        .timeout(const Duration(seconds: 20));
    AppLog.log('tagesbestpreis HTTP ${res.statusCode} '
        '(${res.bodyBytes.length}B)', tag: 'vendo');
    if (res.statusCode != 200) {
      throw VendoException(_dbAnzeigeText(res.bodyBytes) ??
          'Vendo tagesbestpreis HTTP ${res.statusCode}: '
              '${_snippet(res.bodyBytes)}');
    }
    final data = json.decode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    final intervals = (data['tagesbestPreisIntervalle'] as List<dynamic>? ?? [])
        .whereType<Map<String, dynamic>>()
        .map((iv) => _parseBestPriceInterval(iv, firstClass: firstClass))
        .where((iv) => iv != null)
        .cast<BestPriceInterval>()
        .toList();
    AppLog.log('${intervals.length} price intervals', tag: 'vendo');
    return BestPriceDay(date: day, intervals: intervals);
  }

  /// One `tagesbestPreisIntervalle` entry. Null when it has no bounds — those
  /// are the only field the UI can't do without.
  BestPriceInterval? _parseBestPriceInterval(Map<String, dynamic> iv,
      {bool firstClass = false}) {
    final from = _parse(iv['intervallAb']);
    final to = _parse(iv['intervallBis']);
    if (from == null || to == null) return null;
    final preis = iv['angebotsPreis'] as Map<String, dynamic>?;
    return BestPriceInterval(
      from: from,
      to: to,
      price: (preis?['betrag'] as num?)?.toDouble(),
      currency: preis?['waehrung'] as String? ?? 'EUR',
      isBest: iv['istBestpreis'] as bool? ?? false,
      isPartialPrice: iv['istTeilpreis'] as bool? ?? false,
      journeys: (iv['verbindungen'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map((c) => _parseConnection(c, firstClass: firstClass))
          .toList(),
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
    bool firstClass = false,
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
          .map((c) => _parseConnection(c, firstClass: firstClass))
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
      cancelled: _boardCancelled(notes),
      remarks: notes,
    );
  }

  /// Whether a board row is a cancellation.
  ///
  /// The board carries no flag for this — unlike a Zuglauf halt, which has
  /// `ersatzhaltNotiz.typ == GECANCELT`. The only signal is the realtime note
  /// ("Halt entfällt" on 69 of 1367 rows probed), so this matches on text.
  /// Deliberately loose about the wording, since that is DB's to change.
  static bool _boardCancelled(List<String> notes) {
    for (final n in notes) {
      final t = n.toLowerCase();
      if (t.contains('entfällt') || t.contains('fällt aus')) return true;
    }
    return false;
  }

  // ==========================================================================
  // TRIP DETAIL (Zugverlauf) — GET /mob/zuglauf/{zuglaufId}. Replaces the
  // Akamai-blocked bahn.de `reiseloesung/fahrt`. One call yields the stop list
  // (times/platform/occupancy/coords), train-wide attributes AND the exact
  // track polyline, so the map needs no second request.
  // ==========================================================================

  Future<Trip> getTrip(String zuglaufId) async =>
      parseTrip(await getTripRaw(zuglaufId), zuglaufId);

  /// The raw `/mob/zuglauf/{id}` response, before parsing.
  ///
  /// Exists so the offline package (#29) can persist the backend's own JSON
  /// verbatim and replay it through [parseTrip] later — the same
  /// "store the raw API response, re-parse on read" shape the ticket cache uses.
  /// Storing raw rather than a serialised [Trip] means a parser improvement
  /// benefits already-downloaded packages instead of being locked out by a
  /// stale model snapshot.
  Future<Map<String, dynamic>> getTripRaw(String zuglaufId) async {
    final url = '$_base/zuglauf/${Uri.encodeComponent(zuglaufId)}';
    // Serialised + rate-limit aware: a connection detail screen fires one of
    // these per leg at once, and again on every resume/refresh. Unthrottled,
    // that reliably trips the backend's per-client limit and every leg fails
    // together — which is what made the detail view collapse to the minimal
    // card for *all* connections at once, then recover minutes later (#14).
    final res = await _zuglaufGate.run(
      () => _getWithRetry(url, _zuglaufMedia, tag: 'zuglauf'),
    );
    return json.decode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
  }

  /// Parse a `/mob/zuglauf/{id}` payload — live or replayed from disk.
  Trip parseTrip(Map<String, dynamic> data, String zuglaufId) =>
      _parseTripFromZuglauf(data, zuglaufId);

  /// GET honouring 429 + `Retry-After`. The backend answers a tripped limit
  /// with `{"domain":"MOB","code":"RETRY","status":"ERROR"}` and a
  /// `Retry-After` (~18s observed), i.e. it tells us exactly when to come
  /// back — treating that as a hard failure throws away a request that would
  /// have succeeded. Mirrors DbAccountService's existing 429 backoff.
  Future<http.Response> _getWithRetry(
    String url,
    String media, {
    required String tag,
    int attempt = 0,
  }) async {
    final res = await _client
        .get(Uri.parse(url), headers: _headers(media))
        .timeout(const Duration(seconds: 10));
    if (res.statusCode == 429 && attempt < _maxRetries) {
      final retryAfter = int.tryParse(res.headers['retry-after'] ?? '');
      // No Retry-After → exponential backoff (2s, 4s). Cap the honoured wait:
      // a rider staring at a spinner won't sit through a 60s hint.
      final delay = Duration(
        seconds: (retryAfter ?? (2 << attempt)).clamp(1, 20),
      );
      AppLog.log(
          '429 on $tag → backoff ${delay.inSeconds}s '
          '(attempt ${attempt + 1}/$_maxRetries)',
          tag: 'vendo');
      await Future.delayed(delay);
      return _getWithRetry(url, media, tag: tag, attempt: attempt + 1);
    }
    if (res.statusCode != 200) {
      throw VendoException('Vendo $tag HTTP ${res.statusCode}');
    }
    return res;
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

    // Disruption notes: HIM messages (construction, closed track) and realtime
    // notes ("Umleitung", "Zusatzhalt"), from the run and its stops. Same
    // treatment _parseLeg already gives the journey search — the train run
    // parsed only attributNotizen, so a diversion was invisible while its
    // delay showed up on the unchanged stop list (#17). attributNotizen stay
    // out: they're amenities, and they're already parsed above.
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

    collect(data['himNotizen']);
    collect(data['echtzeitNotizen']);
    for (final h in halte.whereType<Map<String, dynamic>>()) {
      // Per stop it is `echtzeitNotizen` that carries "Halt entfällt" /
      // "Neuer Zielhalt" — `himNotizen` only ever appears at the root. Reading
      // it here matched nothing at all (0 of 450 stops probed).
      collect(h['echtzeitNotizen']);
    }

    return Trip(
      id: zuglaufId,
      disruptions: disruptions,
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
      additional: h['istZusatzhalt'] as bool? ?? false,
      noBoarding: _serviceKey(h) == 'text.realtime.stop.entry.disabled',
      noAlighting: _serviceKey(h) == 'text.realtime.stop.exit.disabled',
      serviceNote:
          (h['serviceNotiz'] as Map<String, dynamic>?)?['text'] as String?,
      occupancy: _occupancyFrom(h['auslastungsInfos'] as List<dynamic>?),
    );
  }

  /// `serviceNotiz.key` — the machine-readable half of "Hält nur zum
  /// Aussteigen". Match on this, never the German text; DB owns the wording.
  static String _serviceKey(Map<String, dynamic> h) =>
      (h['serviceNotiz'] as Map<String, dynamic>?)?['key'] as String? ?? '';

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
  OccupancyLevel _occupancyFrom(List<dynamic>? infos,
      {bool firstClass = false}) {
    return _levelForClass(infos, firstClass: firstClass) ??
        OccupancyLevel.unknown;
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
    // Train numbers the selected connection uses on this segment, in order.
    // When given, an offer for exactly these trains wins over a cheaper one
    // for some other train (#13).
    List<String>? expectedTrains,
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

      // NOTE: no D-Ticket coverage inference here. It used to return 0,00 € if
      // *any* returned journey was purely regional — but the price below comes
      // from a different journey, and the rider travels on a third: their own.
      // A regional alternative existing between two stations says nothing about
      // whether their ICE is covered, which is how ICE segments came out free
      // (#13). The caller decides coverage from the selected connection's own
      // trains (isSegmentDTicketCovered); `deutschlandTicket` now only shapes
      // the request, so DB quotes the right supplementary fare.

      // Prefer the offer for the trains the rider actually selected. The
      // search returns every connection between these two stops, so the
      // cheapest fare can be a Sparpreis bound to a different train — valid
      // on that train, useless on theirs.
      if (expectedTrains != null && expectedTrains.isNotEmpty) {
        for (final j in result.journeys) {
          final trains = <String>[];
          for (final l in j.legs.where((l) => !l.isWalking)) {
            final nr = l.line?.fahrtNr;
            if (nr == null || nr.isEmpty) continue;
            if (trains.isEmpty || trains.last != nr) trains.add(nr);
          }
          final amount = j.price?.amount;
          if (amount != null && _sameTrains(trains, expectedTrains)) {
            return SegmentPrice(price: amount, isDTicketCovered: false);
          }
        }
      }

      final prices = result.journeys
          .map((j) => j.price?.amount)
          .whereType<double>()
          .toList();
      if (prices.isEmpty) {
        return const SegmentPrice(price: double.infinity, isDTicketCovered: false);
      }
      // No offer matched the selected trains — fall back to the cheapest, but
      // say so, so the ticket can carry a "may be train-bound" hint instead of
      // quietly implying the fare is valid on their train.
      return SegmentPrice(
        price: prices.reduce((a, b) => a < b ? a : b),
        isDTicketCovered: false,
        priceMayBeTrainBound: true,
      );
    } catch (e) {
      AppLog.log('segment price failed ($e)', tag: 'vendo');
      return const SegmentPrice(price: double.infinity, isDTicketCovered: false);
    }
  }

  static bool _sameTrains(List<String> a, List<String> b) =>
      a.length == b.length &&
      Iterable<int>.generate(a.length).every((i) => a[i] == b[i]);

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
  Journey parseConnection(Map<String, dynamic> c, {bool firstClass = false}) =>
      _parseConnection(c, firstClass: firstClass);

  Journey _parseConnection(Map<String, dynamic> c,
      {bool firstClass = false}) {
    // /angebote/fahrplan wraps the connection in `verbindung`; the
    // /trip/weitereabfahrten response puts the same fields directly on the
    // connection object — fall back to `c` so both shapes parse.
    final vb = c['verbindung'] as Map<String, dynamic>? ?? c;
    final abschnitte = vb['verbindungsAbschnitte'] as List<dynamic>? ?? [];
    final legs = abschnitte
        .whereType<Map<String, dynamic>>()
        .map((a) => _parseLeg(a, firstClass: firstClass))
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
      disruptions: _connectionNotes(vb),
      serviceDaysNote: _serviceDaysNote(vb),
    );
  }

  /// When this connection doesn't run, in DB's words (#20, point 8).
  ///
  /// Only `serviceDays[].irregular` ("nicht 22. Aug bis 4. Sep 2026"). The
  /// siblings are left alone on purpose:
  ///
  /// - `regular` says "täglich" next to a `wochentage` of [SA, SO] on the same
  ///   object, so at least one of them doesn't mean what it reads like;
  /// - `wochentage` is that list, and rendering "SA, SO" under a connection
  ///   found on a Saturday adds nothing.
  ///
  /// `irregular` is the part that survives checking: across 34 connections the
  /// searched date never fell inside one of its "nicht" ranges.
  static String? _serviceDaysNote(Map<String, dynamic> vb) {
    final days = (vb['serviceDays'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .firstOrNull;
    final text = (days?['irregular'] as String?)?.trim();
    if (text == null || text.isEmpty || text == 'textDefault') return null;
    return text;
  }

  /// Notes about the connection as a whole ("Der Zielhalt Berlin Hbf entfällt.
  /// Ausstieg in Berlin-Spandau möglich.", "Verbindung fällt aus", platform
  /// changes). Occasionally the only place that says what happened — the legs
  /// can carry nothing.
  ///
  /// Reads `echtzeitNotizen`/`himNotizen` rather than `topNotiz`: the latter
  /// holds the same text but is the literal placeholder "textDefault" in 11 of
  /// 15 connections probed, which must never reach the UI.
  static List<String> _connectionNotes(Map<String, dynamic> vb) {
    final out = <String>[];
    for (final key in const ['himNotizen', 'echtzeitNotizen']) {
      for (final n in (vb[key] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()) {
        final t = (n['text'] as String?)?.trim();
        if (t == null || t.isEmpty || t == 'textDefault') continue;
        if (!out.contains(t)) out.add(t);
      }
    }
    return out;
  }

  JourneyLeg _parseLeg(Map<String, dynamic> a, {bool firstClass = false}) {
    final isWalking = a['typ'] == 'FUSSWEG';
    final origin = _stationFromVendo(
        a['abgangsOrt'] as Map<String, dynamic>? ?? const {});
    final dest = _stationFromVendo(
        a['ankunftsOrt'] as Map<String, dynamic>? ?? const {});

    final plannedDep = _parse(a['abgangsDatum']);
    final actualDep = _parse(a['ezAbgangsDatum']) ?? plannedDep;
    final plannedArr = _parse(a['ankunftsDatum']);
    final actualArr = _parse(a['ezAnkunftsDatum']) ?? plannedArr;

    // The train terminates short of `ankunftsOrt` — that field keeps saying
    // "Berlin Hbf 00:17" while the run actually ends at Berlin-Spandau 00:04.
    // Kept alongside the planned values rather than replacing them, so the UI
    // can show that the leg changed, not the rider's search.
    final ersatzZiel = a['ersatzAnkunftsHalt'] as Map<String, dynamic>?;

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
      // See _parseTripFromZuglauf: stop-level notes live in `echtzeitNotizen`.
      collect(h['echtzeitNotizen']);
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

    // What DB itself says about this transfer, instead of us re-deriving it
    // from timestamps (#20, point 6).
    //
    // `verfuegbareZeit` (seconds) is the window from the previous train's
    // arrival to the next one's departure — it matches our computed gap
    // exactly. It only appears where the walk crosses between two distinct
    // stations, and there `abschnittsDauer` is the walk itself (Köln Messe/
    // Deutz: 720s available, 420s walking, 59 m).
    //
    // For a change inside one station DB sends neither and `abschnittsDauer`
    // is the whole window again (Mannheim Hbf: dauer 720 == gap 720). Reading
    // it as a walk estimate there would invent a 12-minute walk across one
    // platform — hence both are only taken together.
    final available = _seconds(a['verfuegbareZeit']);
    final walkDuration =
        isWalking && available != null ? _seconds(a['abschnittsDauer']) : null;

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
      walkingDistance: (a['distanz'] as num?)?.toInt(),
      walkingDuration: walkDuration,
      transferAvailable: available,
      samePlatformTransfer:
          a['weiterfahrtAmGleichenBahnsteig'] as bool? ?? false,
      cancelled: cancelled,
      stopovers: stopovers,
      occupancy: _occupancy(a['auslastungsInfos'] as List<dynamic>?,
          firstClass: firstClass),
      disruptions: disruptions,
      replacementDestination: ersatzZiel == null
          ? null
          : _stationFromVendo(
              ersatzZiel['ort'] as Map<String, dynamic>? ?? const {}),
      replacementArrival: ersatzZiel == null
          ? null
          : _parse(ersatzZiel['ezAnkunftsDatum']) ??
              _parse(ersatzZiel['ankunftsDatum']),
      replacementArrivalPlatform:
          ersatzZiel?['ezGleis'] as String? ?? ersatzZiel?['gleis'] as String?,
    );
  }

  LegStopover _parseStopover(Map<String, dynamic> h) {
    final sn = h['serviceNotiz'] as Map<String, dynamic>?;
    final key = sn?['key'] as String? ?? '';
    return LegStopover(
      stop: _stationFromVendo(h['ort'] as Map<String, dynamic>? ?? const {}),
      arrival: _parse(h['ezAnkunftsDatum']) ?? _parse(h['ankunftsDatum']),
      departure: _parse(h['ezAbgangsDatum']) ?? _parse(h['abgangsDatum']),
      cancelled: _haltCancelled(h),
      // Keyed off `key`, not the German text — DB owns the wording.
      noBoarding: key == 'text.realtime.stop.entry.disabled',
      noAlighting: key == 'text.realtime.stop.exit.disabled',
      serviceNote: sn?['text'] as String?,
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

  /// Occupancy for the class the rider actually searched for.
  ///
  /// Both classes are present in the response (KLASSE_1 on 36 of 36 entries
  /// probed), but this only ever read KLASSE_2 — so a first-class search never
  /// showed any occupancy at all. Falls back to the other class rather than
  /// showing nothing.
  OccupancyInfo? _occupancy(List<dynamic>? infos, {bool firstClass = false}) {
    final level = _levelForClass(infos, firstClass: firstClass);
    return level == null ? null : OccupancyInfo(level: level);
  }

  OccupancyLevel? _levelForClass(List<dynamic>? infos,
      {required bool firstClass}) {
    if (infos == null) return null;
    final want = firstClass ? 'KLASSE_1' : 'KLASSE_2';
    final other = firstClass ? 'KLASSE_2' : 'KLASSE_1';
    OccupancyLevel? fallback;
    for (final i in infos.whereType<Map<String, dynamic>>()) {
      if (i['klasse'] == want) return _stufe(i['stufe'] as int?);
      if (i['klasse'] == other) fallback ??= _stufe(i['stufe'] as int?);
    }
    return fallback;
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
      // Live data says `IC_EC` — the `EC_IC` spelling below never appears and
      // is kept only defensively. Getting this wrong sent every IC into the
      // `default: regional` arm.
      case 'IC_EC':
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

  /// Vendo durations (`verfuegbareZeit`, `abschnittsDauer`) are seconds.
  Duration? _seconds(dynamic v) =>
      v is num ? Duration(seconds: v.toInt()) : null;

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
