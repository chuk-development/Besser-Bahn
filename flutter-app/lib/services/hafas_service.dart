import 'dart:convert';
import 'package:http/http.dart' as http;
import '../core/app_log.dart';
import '../core/constants.dart';
import '../core/polyline_cache.dart';
import '../models/station.dart';
import '../models/departure.dart';
import '../models/trip.dart';
import 'offline_store.dart';
import 'vendo_service.dart';

/// Station search, departure boards and trip detail. Backed by the DB Vendo
/// `/mob` backend (the bahn.de web API is Akamai-blocked); HAFAS REST remains a
/// last-resort fallback for trip detail only.
class HafasService {
  final http.Client _client = http.Client();
  final VendoService _vendo = VendoService();
  static const _hafasBase = ApiConstants.hafasBaseUrl;

  Map<String, String> get _headers => {
        'User-Agent': ApiConstants.userAgent,
        'Accept': 'application/json',
        'Accept-Language': 'de-DE,de;q=0.9',
      };

  // ============================================================
  // STATION SEARCH (DB Vendo /mob backend — bahn.de web API is Akamai-blocked)
  // ============================================================

  Future<List<Station>> searchStations(String query) =>
      _vendo.searchLocations(query);

  /// Stations near a coordinate — via the DB Vendo `location/nearby/bytypes`
  /// endpoint (request shape reverse-engineered from the DB Navigator APK).
  Future<List<Station>> nearbyStations({
    required double latitude,
    required double longitude,
    int results = 8,
    int? distance,
  }) =>
      _vendo.nearbyStations(
        latitude: latitude,
        longitude: longitude,
        radius: distance ?? 2000,
        maxResults: results,
      );

  // ============================================================
  // DEPARTURES / ARRIVALS (DB Vendo Bahnhofstafel)
  // ============================================================

  Future<List<Departure>> getDepartures(
    String stationId, {
    DateTime? when,
    int duration = 60,
    int results = 40,
  }) =>
      _vendo.getDepartures(stationId, when: when, results: results);

  Future<List<Departure>> getArrivals(
    String stationId, {
    DateTime? when,
    int duration = 60,
    int results = 40,
  }) =>
      _vendo.getArrivals(stationId, when: when, results: results);

  // ============================================================
  // TRIP DETAILS
  // ============================================================

  Future<Trip> getTrip(String tripId) async {
    // DB Vendo `zuglauf` first — it returns the stop list, train attributes AND
    // the exact track polyline in one call, and isn't Akamai-gated. HAFAS is a
    // last resort (the public mirror is frequently down and would hang ~10s).
    final sw = Stopwatch()..start();
    AppLog.log('getTrip via Vendo zuglauf…', tag: 'trip');
    try {
      final trip = await _vendo.getTrip(tripId);
      AppLog.log(
          'getTrip ok ${sw.elapsedMilliseconds}ms · ${trip.line.displayName} '
          '(${trip.stopovers.length} stops, '
          '${trip.polyline?.length ?? 0} geo pts)',
          tag: 'trip');
      // zuglauf already carries the geometry; cache it for reuse across days
      // (keyed by the physical route, not the date-bearing trip id).
      if (trip.polyline != null && trip.polyline!.isNotEmpty) {
        await PolylineCache.instance.put(trip.routeKey, trip.polyline!);
        return trip;
      }
      // No geometry in this response → attach a cached track if we have one.
      final cached = await PolylineCache.instance.get(trip.routeKey);
      return (cached != null && cached.isNotEmpty)
          ? trip.copyWith(polyline: cached)
          : trip;
    } catch (e) {
      AppLog.log(
          'Vendo zuglauf failed ${sw.elapsedMilliseconds}ms ($e) → trying HAFAS',
          tag: 'trip');
      try {
        final trip = await _getTripHafas(tripId);
        AppLog.log('getTrip via HAFAS ok ${sw.elapsedMilliseconds}ms',
            tag: 'trip');
        if (trip.polyline != null && trip.polyline!.isNotEmpty) {
          await PolylineCache.instance.put(trip.routeKey, trip.polyline!);
        }
        return trip;
      } catch (e2) {
        // Both live sources are gone. If the rider packed this journey for
        // offline use, replay the run we stored instead of failing — the screen
        // says how old it is (#29). Last resort by design: a stored run has no
        // realtime in it, so it must never pre-empt a reachable backend.
        final offline = await _offlineTrip(tripId);
        if (offline != null) {
          AppLog.log('getTrip served from offline package', tag: 'offline');
          return offline;
        }
        rethrow;
      }
    }
  }

  /// The stored `/mob/zuglauf` payload for [tripId], re-parsed. Null when no
  /// package carries this leg.
  Future<Trip?> _offlineTrip(String tripId) async {
    try {
      final raw = await OfflineStore.instance.readPlan(tripId);
      if (raw == null) return null;
      final trip = _vendo.parseTrip(raw, tripId);
      if (trip.polyline != null && trip.polyline!.isNotEmpty) return trip;
      final cached = await PolylineCache.instance.get(trip.routeKey);
      return (cached != null && cached.isNotEmpty)
          ? trip.copyWith(polyline: cached)
          : trip;
    } catch (_) {
      return null;
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
