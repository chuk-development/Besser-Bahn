import 'dart:convert';
import 'package:http/http.dart' as http;
import '../core/app_log.dart';
import '../core/constants.dart';
import '../core/polyline_cache.dart';
import '../models/station.dart';
import '../models/departure.dart';
import '../models/trip.dart';
import 'vendo_service.dart';

/// Primary service using bahn.de internal APIs (always available)
/// with HAFAS REST as fallback for trip details.
class HafasService {
  final http.Client _client = http.Client();
  final VendoService _vendo = VendoService();
  static const _dbBase = ApiConstants.dbWebApiBaseUrl;
  static const _hafasBase = ApiConstants.hafasBaseUrl;

  Map<String, String> get _headers => {
        'User-Agent': ApiConstants.userAgent,
        'Accept': 'application/json',
        'Accept-Language': 'de-DE,de;q=0.9',
      };

  // ============================================================
  // STATION SEARCH (bahn.de API — always works)
  // ============================================================

  Future<List<Station>> searchStations(String query) async {
    final uri = Uri.parse('$_dbBase/reiseloesung/orte').replace(
      queryParameters: {
        'suchbegriff': query,
        'typ': 'ALL',
        'limit': '10',
      },
    );
    final response = await _client.get(uri, headers: _headers);
    if (response.statusCode != 200) return [];

    final decoded = json.decode(response.body);
    if (decoded is List) {
      return decoded
          .whereType<Map<String, dynamic>>()
          .where((j) => j['type'] == 'ST')
          .map(Station.fromDbWeb)
          .toList();
    }
    return [];
  }

  Future<List<Station>> nearbyStations({
    required double latitude,
    required double longitude,
    int results = 8,
    int? distance,
  }) async {
    final uri = Uri.parse('$_dbBase/reiseloesung/orte/nearby').replace(
      queryParameters: {
        'lat': latitude.toString(),
        'long': longitude.toString(),
        'radius': (distance ?? 2000).toString(),
        'maxNo': results.toString(),
      },
    );
    final response = await _client.get(uri, headers: _headers);
    if (response.statusCode != 200) return [];

    final decoded = json.decode(response.body);
    if (decoded is List) {
      return decoded
          .whereType<Map<String, dynamic>>()
          .map(Station.fromDbWeb)
          .toList();
    }
    return [];
  }

  // ============================================================
  // DEPARTURES / ARRIVALS (bahn.de API)
  // ============================================================

  Future<List<Departure>> getDepartures(
    String stationId, {
    DateTime? when,
    int duration = 60,
    int results = 40,
  }) async {
    final now = when ?? DateTime.now();
    final datum =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final zeit =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:00';

    // bahn.de uses repeated params for verkehrsmittel
    final realUri = Uri.parse('$_dbBase/reiseloesung/abfahrten?'
        'datum=$datum&zeit=$zeit&ortExtId=$stationId&mitVias=false'
        '&verkehrsmittel[]=ICE&verkehrsmittel[]=EC_IC&verkehrsmittel[]=IR'
        '&verkehrsmittel[]=REGIONAL&verkehrsmittel[]=SBAHN'
        '&verkehrsmittel[]=BUS&verkehrsmittel[]=SCHIFF'
        '&verkehrsmittel[]=UBAHN&verkehrsmittel[]=TRAM'
        '&verkehrsmittel[]=ANRUFPFLICHTIG');

    final response = await _client.get(realUri, headers: _headers);
    if (response.statusCode != 200) return [];

    final data = json.decode(response.body) as Map<String, dynamic>;
    final entries = data['entries'] as List<dynamic>? ?? [];

    return entries
        .whereType<Map<String, dynamic>>()
        .take(results)
        .map(_departureFomDbWeb)
        .toList();
  }

  Future<List<Departure>> getArrivals(
    String stationId, {
    DateTime? when,
    int duration = 60,
    int results = 40,
  }) async {
    final now = when ?? DateTime.now();
    final datum =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final zeit =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:00';

    final realUri = Uri.parse('$_dbBase/reiseloesung/ankuenfte?'
        'datum=$datum&zeit=$zeit&ortExtId=$stationId&mitVias=false'
        '&verkehrsmittel[]=ICE&verkehrsmittel[]=EC_IC&verkehrsmittel[]=IR'
        '&verkehrsmittel[]=REGIONAL&verkehrsmittel[]=SBAHN'
        '&verkehrsmittel[]=BUS&verkehrsmittel[]=SCHIFF'
        '&verkehrsmittel[]=UBAHN&verkehrsmittel[]=TRAM'
        '&verkehrsmittel[]=ANRUFPFLICHTIG');

    final response = await _client.get(realUri, headers: _headers);
    if (response.statusCode != 200) return [];

    final data = json.decode(response.body) as Map<String, dynamic>;
    final entries = data['entries'] as List<dynamic>? ?? [];

    return entries
        .whereType<Map<String, dynamic>>()
        .take(results)
        .map(_departureFomDbWeb)
        .toList();
  }

  Departure _departureFomDbWeb(Map<String, dynamic> json) {
    final vm = json['verkehrmittel'] as Map<String, dynamic>? ?? {};
    final zeit = json['zeit'] as String?;
    final ezZeit = json['ezZeit'] as String?;
    final plannedWhen = zeit != null ? DateTime.tryParse(zeit) : null;
    final actualWhen = ezZeit != null ? DateTime.tryParse(ezZeit) : null;

    int? delay;
    if (plannedWhen != null && actualWhen != null) {
      delay = actualWhen.difference(plannedWhen).inSeconds;
    }

    final gleis = json['gleis'] as String?;
    final ezGleis = json['ezGleis'] as String?;

    final meldungen = json['meldungen'] as List<dynamic>? ?? [];

    return Departure(
      tripId: json['journeyId'] as String? ?? '',
      stop: Station(
        id: json['bahnhofsId']?.toString() ?? '',
        name: '',
      ),
      when: actualWhen ?? plannedWhen,
      plannedWhen: plannedWhen,
      delay: delay,
      platform: ezGleis ?? gleis,
      plannedPlatform: gleis,
      direction: json['terminus'] as String? ?? '',
      line: TransitLine(
        name: vm['mittelText'] as String? ?? vm['name'] as String? ?? '',
        fahrtNr: vm['linienNummer'] as String? ?? '',
        productName: vm['kurzText'] as String? ?? '',
        product: _mapProduct(vm['produktGattung'] as String? ?? ''),
        operatorName: null,
      ),
      cancelled: false,
      remarks: meldungen
          .whereType<Map<String, dynamic>>()
          .map((m) => m['text'] as String? ?? '')
          .where((s) => s.isNotEmpty)
          .toList(),
    );
  }

  String _mapProduct(String gattung) {
    switch (gattung) {
      case 'ICE':
        return 'nationalExpress';
      case 'EC_IC':
        return 'national';
      case 'IR':
      case 'REGIONAL':
        return 'regional';
      case 'SBAHN':
        return 'suburban';
      case 'BUS':
        return 'bus';
      case 'UBAHN':
        return 'subway';
      case 'TRAM':
        return 'tram';
      case 'SCHIFF':
        return 'ferry';
      default:
        return gattung.toLowerCase();
    }
  }

  // ============================================================
  // TRIP DETAILS
  // ============================================================

  Future<Trip> getTrip(String tripId) async {
    // bahn.de first — it's fast and reliable. HAFAS is only a last resort
    // (the public mirror is frequently down and would otherwise hang ~10s).
    final sw = Stopwatch()..start();
    AppLog.log('getTrip via bahn.de fahrt…', tag: 'trip');
    try {
      final trip = await _getTripDbWeb(tripId);
      AppLog.log(
          'getTrip ok ${sw.elapsedMilliseconds}ms · ${trip.line.displayName} '
          '(${trip.stopovers.length} stops)',
          tag: 'trip');
      // bahn.de carries no track geometry. Attach the exact route geometry
      // *from the local cache only* here so the trip renders instantly — the
      // (possibly slow) HAFAS network fetch happens lazily from the map widget
      // via [fetchRoutePolyline], snapping the straight line onto the rails.
      final cached = await PolylineCache.instance.get(trip.routeKey);
      return (cached != null && cached.isNotEmpty)
          ? trip.copyWith(polyline: cached)
          : trip;
    } catch (e) {
      AppLog.log(
          'bahn.de fahrt failed ${sw.elapsedMilliseconds}ms ($e) → trying HAFAS',
          tag: 'trip');
      final trip = await _getTripHafas(tripId);
      AppLog.log('getTrip via HAFAS ok ${sw.elapsedMilliseconds}ms', tag: 'trip');
      if (trip.polyline != null && trip.polyline!.isNotEmpty) {
        await PolylineCache.instance.put(trip.routeKey, trip.polyline!);
      }
      return trip;
    }
  }

  /// The exact track geometry (lat/lng points along the rails) for a trip.
  ///
  /// Order: persistent route cache → DB Navigator `zuglauf` endpoint (the
  /// official app's own map source, on the always-up Vendo backend). A
  /// successful fetch is cached for every future view of the same physical
  /// route. Returns null when geometry can't be obtained — the caller then
  /// keeps the straight-line fallback.
  ///
  /// Meant to be called lazily from the map widget so trip loading never blocks
  /// on the network.
  Future<List<Map<String, double>>?> fetchRoutePolyline(Trip trip) async {
    if (trip.polyline != null && trip.polyline!.isNotEmpty) {
      return trip.polyline;
    }
    final key = trip.routeKey;

    final cached = await PolylineCache.instance.get(key);
    if (cached != null && cached.isNotEmpty) {
      AppLog.log('polyline cache hit (${cached.length} pts)', tag: 'trip');
      return cached;
    }

    // DB's own route geometry via the Vendo backend (the official app's map
    // source). The HAFAS mirror is dead, so there's no point chaining it.
    try {
      final poly = await _vendo.fetchTripPolyline(trip.id);
      if (poly != null && poly.isNotEmpty) {
        AppLog.log('polyline via Vendo (${poly.length} pts)', tag: 'trip');
        await PolylineCache.instance.put(key, poly);
        return poly;
      }
    } catch (e) {
      AppLog.log('Vendo polyline failed ($e) → straight-line fallback',
          tag: 'trip');
    }
    return null;
  }

  Future<Trip> _getTripHafas(String tripId) async {
    final encoded = Uri.encodeComponent(tripId);
    final uri = Uri.parse('$_hafasBase/trips/$encoded').replace(
      queryParameters: {
        'stopovers': 'true',
        'remarks': 'true',
        'polyline': 'true',
        'language': 'de',
      },
    );
    final response = await _client
        .get(uri, headers: _headers)
        .timeout(const Duration(seconds: 5));
    if (response.statusCode != 200) {
      throw Exception('HAFAS trip returned ${response.statusCode}');
    }
    final data = json.decode(response.body) as Map<String, dynamic>;
    final tripData = data['trip'] as Map<String, dynamic>? ?? data;
    return Trip.fromHafas(tripData);
  }

  Future<Trip> _getTripDbWeb(String journeyId) async {
    final encoded = Uri.encodeComponent(journeyId);
    final uri = Uri.parse('$_dbBase/reiseloesung/fahrt?journeyId=$encoded');
    // Cap the wait: a hanging/slow bahn.de request must not block the UI
    // forever — time out so getTrip can fall back to HAFAS quickly.
    final response = await _client
        .get(uri, headers: _headers)
        .timeout(const Duration(seconds: 8));
    if (response.statusCode != 200) {
      throw Exception('bahn.de fahrt returned ${response.statusCode}');
    }
    final data = json.decode(response.body) as Map<String, dynamic>;
    return _parseTripFromDbWeb(data, journeyId);
  }

  Trip _parseTripFromDbWeb(Map<String, dynamic> data, String journeyId) {
    final halte = data['halte'] as List<dynamic>? ?? [];

    // Train info comes from first halt or top-level fields
    final zugName = data['zugName'] as String? ?? '';
    String kategorie = '';
    String nummer = '';
    if (halte.isNotEmpty) {
      final firstHalt = halte.first as Map<String, dynamic>;
      kategorie = firstHalt['kategorie'] as String? ?? '';
      nummer = firstHalt['nummer']?.toString() ?? '';
    }

    final stopovers = halte.whereType<Map<String, dynamic>>().map((h) {
      // bahn.de `fahrt` nests times: abfahrt/ankunft = {sollzeit, echtzeit}.
      final ab = h['abfahrt'] as Map<String, dynamic>?;
      final an = h['ankunft'] as Map<String, dynamic>?;
      final plannedDep = _parseTime(ab?['sollzeit'] as String?);
      final actualDep = _parseTime(ab?['echtzeit'] as String?);
      final plannedArr = _parseTime(an?['sollzeit'] as String?);
      final actualArr = _parseTime(an?['echtzeit'] as String?);

      // Coordinates are encoded in the HAFAS location id (@X=lon*1e6@Y=lat*1e6@).
      final locId = h['id'] as String?;
      final coords = _coordsFromLocationId(locId);

      return Stopover(
        stop: Station(
          id: h['extId'] as String? ?? '',
          name: h['name'] as String? ?? '',
          latitude: coords?.$1,
          longitude: coords?.$2,
          locationId: (locId != null && locId.contains('@')) ? locId : null,
        ),
        departure: actualDep ?? plannedDep,
        plannedDeparture: plannedDep,
        departureDelay: (plannedDep != null && actualDep != null)
            ? actualDep.difference(plannedDep).inSeconds
            : null,
        arrival: actualArr ?? plannedArr,
        plannedArrival: plannedArr,
        arrivalDelay: (plannedArr != null && actualArr != null)
            ? actualArr.difference(plannedArr).inSeconds
            : null,
        departurePlatform: h['gleis'] as String?,
        plannedDeparturePlatform: h['gleis'] as String?,
        arrivalPlatform: h['gleis'] as String?,
        plannedArrivalPlatform: h['gleis'] as String?,
        cancelled: h['cancelled'] as bool? ?? false,
      );
    }).toList();

    final origin = stopovers.isNotEmpty
        ? stopovers.first.stop
        : const Station(id: '', name: '');
    final dest = stopovers.length > 1
        ? stopovers.last.stop
        : origin;

    // Build display name: "RE 11972" or "Bus 310" etc.
    final displayName =
        kategorie.isNotEmpty ? '$kategorie $nummer' : zugName;

    return Trip(
      id: journeyId,
      line: TransitLine(
        name: displayName,
        fahrtNr: nummer,
        productName: kategorie,
        product: _mapProduct(kategorie),
      ),
      direction: dest.name,
      origin: origin,
      destination: dest,
      stopovers: stopovers,
    );
  }

  // ============================================================
  // TRAIN SEARCH BY NUMBER
  // ============================================================

  Future<List<TrainSearchResult>> findTrainsByNumber(
    String input, {
    String? fromStationId,
  }) async {
    final cleaned = input.trim().toUpperCase();
    final parts = cleaned.split(RegExp(r'\s+'));

    String? productFilter;
    String number;

    if (parts.length >= 2) {
      productFilter = parts[0];
      number = parts.sublist(1).join(' ').replaceAll(RegExp(r'[^0-9]'), '');
    } else {
      number = cleaned.replaceAll(RegExp(r'[^0-9]'), '');
    }

    if (number.isEmpty) return [];

    final results = <TrainSearchResult>[];
    final seenTripIds = <String>{};

    List<List<Departure>> allDeps;

    if (fromStationId != null) {
      try {
        final deps = await getDepartures(fromStationId, results: 100);
        allDeps = [deps];
      } catch (_) {
        allDeps = [];
      }
    } else {
      final stationEntries =
          AppConstants.majorStations.entries.take(5).toList();
      final futures = stationEntries.map((entry) async {
        try {
          return await getDepartures(entry.value, results: 80);
        } catch (_) {
          return <Departure>[];
        }
      });
      allDeps = await Future.wait(futures);
    }

    for (final deps in allDeps) {
      for (final dep in deps) {
        final lineNumber = dep.line.fahrtNr;
        final lineName = dep.line.name.toUpperCase();

        bool matches = lineNumber == number;
        if (!matches && lineName.contains(number)) matches = true;

        if (matches && productFilter != null) {
          final prodName = dep.line.productName.toUpperCase();
          if (!prodName.startsWith(productFilter) &&
              !productFilter.startsWith(prodName)) {
            matches = false;
          }
        }

        if (matches && !seenTripIds.contains(dep.tripId)) {
          seenTripIds.add(dep.tripId);
          results.add(TrainSearchResult(
            tripId: dep.tripId,
            lineName: dep.line.displayName,
            direction: dep.direction,
            plannedWhen: dep.plannedWhen,
            product: dep.line.productName,
          ));
        }
      }
    }

    results.sort((a, b) {
      if (productFilter != null) {
        final aMatch =
            a.product.toUpperCase().startsWith(productFilter) ? 0 : 1;
        final bMatch =
            b.product.toUpperCase().startsWith(productFilter) ? 0 : 1;
        if (aMatch != bMatch) return aMatch.compareTo(bMatch);
      }
      return (a.plannedWhen ?? DateTime(0))
          .compareTo(b.plannedWhen ?? DateTime(0));
    });

    return results;
  }

  DateTime? _parseTime(dynamic value) {
    if (value is String) return DateTime.tryParse(value);
    return null;
  }

  /// Extract (latitude, longitude) from a HAFAS location id
  /// (`...@X=<lon*1e6>@Y=<lat*1e6>@...`).
  (double, double)? _coordsFromLocationId(String? id) {
    if (id == null) return null;
    final x = RegExp(r'@X=(-?\d+)@').firstMatch(id);
    final y = RegExp(r'@Y=(-?\d+)@').firstMatch(id);
    if (x == null || y == null) return null;
    return (int.parse(y.group(1)!) / 1e6, int.parse(x.group(1)!) / 1e6);
  }
}

class TrainSearchResult {
  final String tripId;
  final String lineName;
  final String direction;
  final DateTime? plannedWhen;
  final String product;

  const TrainSearchResult({
    required this.tripId,
    required this.lineName,
    required this.direction,
    this.plannedWhen,
    required this.product,
  });
}
