import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/app_log.dart';
import '../models/station.dart';
import '../models/trip.dart';
import '../models/coach_sequence.dart';
import '../services/hafas_service.dart';
import 'service_providers.dart';

class TrainLookupState {
  final Trip? trip;
  final CoachSequence? coachSequence;
  final bool isLoading;
  final String? error;
  final List<TrainSearchResult> searchResults;

  const TrainLookupState({
    this.trip,
    this.coachSequence,
    this.isLoading = false,
    this.error,
    this.searchResults = const [],
  });

  TrainLookupState copyWith({
    Trip? trip,
    CoachSequence? coachSequence,
    bool? isLoading,
    String? error,
    List<TrainSearchResult>? searchResults,
  }) {
    return TrainLookupState(
      trip: trip ?? this.trip,
      coachSequence: coachSequence ?? this.coachSequence,
      isLoading: isLoading ?? this.isLoading,
      error: error,
      searchResults: searchResults ?? this.searchResults,
    );
  }
}

class TrainLookupNotifier extends Notifier<TrainLookupState> {
  @override
  TrainLookupState build() => const TrainLookupState();

  Future<void> lookupTrain(String trainNumber, {String? fromStationId}) async {
    state = const TrainLookupState(isLoading: true);

    try {
      AppLog.log(
        'lookup "${AppLog.pii(trainNumber, 'Zug')}"'
        '${fromStationId != null ? ' @station ${AppLog.pii(fromStationId, 'ID')}' : ' (network sweep)'}',
        tag: 'train',
      );
      final hafas = ref.read(hafasServiceProvider);
      final results = await hafas.findTrainsByNumber(
        trainNumber,
        fromStationId: fromStationId,
      );
      AppLog.log('${results.length} matches', tag: 'train');

      if (results.isEmpty) {
        state = TrainLookupState(
          error: fromStationId == null
              ? 'Nicht gefunden. Für Busse/Straßenbahnen wähle eine Haltestelle aus.'
              : 'An dieser Haltestelle nicht gefunden. Prüfe die Nummer.',
        );
        return;
      }

      // If searching from a specific station, always show the list
      // so the user can pick which departure they want
      if (results.length == 1 && fromStationId == null) {
        await _loadTrip(results.first.tripId);
        return;
      }

      state = TrainLookupState(searchResults: results);
    } catch (e) {
      state = TrainLookupState(error: 'Fehler: $e');
    }
  }

  Future<void> selectSearchResult(TrainSearchResult result) async {
    state = const TrainLookupState(isLoading: true);
    await _loadTrip(result.tripId, lineLabel: result.lineName);
  }

  /// Open a trip by id. [lineLabel] is the real line ("RE7") known from the
  /// departure/leg that linked here — the `fahrt` API omits it, so we carry it
  /// in to render "RE 7 (11281)" instead of just the running number.
  Future<void> lookupByTripId(String tripId, {String? lineLabel}) async {
    state = const TrainLookupState(isLoading: true);
    await _loadTrip(tripId, lineLabel: lineLabel);
  }

  Future<void> _loadTrip(String tripId, {String? lineLabel}) async {
    try {
      final hafas = ref.read(hafasServiceProvider);
      var trip = await hafas.getTrip(tripId);

      // Carry the real line label in if the trip API didn't supply it.
      final label = lineLabel?.trim() ?? '';
      if (label.isNotEmpty) {
        trip = trip.copyWith(line: trip.line.withName(label));
      }

      // Show trip immediately, then enrich with coordinates
      state = TrainLookupState(trip: trip);

      // Enrich stopovers with coordinates if missing
      _enrichCoordinates(trip);
      _loadCoachSequence(trip);
    } catch (e) {
      state = TrainLookupState(error: 'Fehler beim Laden: $e');
    }
  }

  Future<void> _enrichCoordinates(Trip trip) async {
    final hafas = ref.read(hafasServiceProvider);
    final needsCoords = trip.stopovers
        .where((s) => !s.stop.hasLocation && s.stop.name.isNotEmpty)
        .toList();

    if (needsCoords.isEmpty) return;

    // Look up coordinates for every missing stop in PARALLEL. Sequentially this
    // was N × ~300ms of network — on a 15-stop ICE that's ~5s before the map
    // could even draw stations, which is the "Zug lädt zu langsam" the rider
    // sees. Future.wait fires them all at once so total = slowest single hit.
    final enriched = <String, Station>{};
    final results = await Future.wait(
      needsCoords.map((stop) async {
        try {
          final hits = await hafas.searchStations(stop.stop.name);
          if (hits.isEmpty) return null;
          final match = hits.firstWhere(
            (s) => s.id == stop.stop.id || s.name == stop.stop.name,
            orElse: () => hits.first,
          );
          return match.hasLocation ? MapEntry(stop.stop.id, match) : null;
        } catch (_) {
          return null;
        }
      }),
      eagerError: false,
    );
    for (final entry in results) {
      if (entry != null) enriched[entry.key] = entry.value;
    }

    if (enriched.isEmpty || state.trip?.id != trip.id) return;

    // Rebuild trip with enriched coordinates
    final newStopovers = trip.stopovers.map((s) {
      final enrichedStation = enriched[s.stop.id];
      if (enrichedStation != null) {
        return Stopover(
          stop: Station(
            id: s.stop.id,
            name: s.stop.name,
            latitude: enrichedStation.latitude,
            longitude: enrichedStation.longitude,
          ),
          arrival: s.arrival,
          plannedArrival: s.plannedArrival,
          arrivalDelay: s.arrivalDelay,
          departure: s.departure,
          plannedDeparture: s.plannedDeparture,
          departureDelay: s.departureDelay,
          arrivalPlatform: s.arrivalPlatform,
          plannedArrivalPlatform: s.plannedArrivalPlatform,
          departurePlatform: s.departurePlatform,
          plannedDeparturePlatform: s.plannedDeparturePlatform,
          cancelled: s.cancelled,
        );
      }
      return s;
    }).toList();

    final enrichedTrip = Trip(
      id: trip.id,
      line: trip.line,
      direction: trip.direction,
      origin: newStopovers.first.stop,
      destination: newStopovers.last.stop,
      stopovers: newStopovers,
      polyline: trip.polyline,
    );

    state = state.copyWith(trip: enrichedTrip);
  }

  Future<void> _loadCoachSequence(Trip trip) async {
    try {
      final coachService = ref.read(coachSequenceServiceProvider);
      final currentStop = trip.currentStop ?? trip.stopovers.firstOrNull;
      if (currentStop == null) return;

      final cs = await coachService.getCoachSequenceForDeparture(
        category: trip.line.productName,
        trainNumber: trip.line.fahrtNr,
        stationEva: currentStop.stop.id,
        departureTime: currentStop.sequenceTime,
      );

      if (cs != null) {
        state = state.copyWith(coachSequence: cs);
      }
    } catch (_) {
      // Coach sequence is optional
    }
  }

  Future<void> refresh() async {
    final trip = state.trip;
    if (trip == null) return;
    state = state.copyWith(isLoading: true);
    await _loadTrip(trip.id, lineLabel: trip.line.name);
  }

  /// Background refresh for an open train run: re-fetch the trip WITHOUT a
  /// spinner and keep the current trip on failure (offline etc.), so live
  /// delays/platforms quietly update while you're riding.
  Future<void> refreshSilent() async {
    final trip = state.trip;
    if (trip == null) return;
    try {
      final hafas = ref.read(hafasServiceProvider);
      var fresh = await hafas.getTrip(trip.id);
      // Preserve the line label carried in originally (fahrt API omits it).
      final label = trip.line.name.trim();
      if (label.isNotEmpty) {
        fresh = fresh.copyWith(line: fresh.line.withName(label));
      }
      state = state.copyWith(trip: fresh);
      _enrichCoordinates(fresh);
      _loadCoachSequence(fresh);
    } catch (_) {
      // Keep the currently shown trip.
    }
  }

  void clear() {
    state = const TrainLookupState();
  }
}

final trainLookupProvider =
    NotifierProvider<TrainLookupNotifier, TrainLookupState>(
      TrainLookupNotifier.new,
    );
