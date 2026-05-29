import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/station.dart';
import '../core/app_log.dart';
import '../models/journey.dart';
import 'service_providers.dart';
import 'settings_provider.dart';

enum JourneySortMode { departure, arrival, duration, transfers }

class JourneySearchState {
  final Station? from;
  final Station? to;
  final DateTime? dateTime;
  final bool isArrival;
  final JourneyResult? result;
  final bool isLoading;
  final String? error;
  final JourneySortMode sortMode;

  const JourneySearchState({
    this.from,
    this.to,
    this.dateTime,
    this.isArrival = false,
    this.result,
    this.isLoading = false,
    this.error,
    this.sortMode = JourneySortMode.departure,
  });

  JourneySearchState copyWith({
    Station? from,
    Station? to,
    DateTime? dateTime,
    bool? isArrival,
    JourneyResult? result,
    bool? isLoading,
    String? error,
    JourneySortMode? sortMode,
  }) {
    return JourneySearchState(
      from: from ?? this.from,
      to: to ?? this.to,
      dateTime: dateTime ?? this.dateTime,
      isArrival: isArrival ?? this.isArrival,
      result: result ?? this.result,
      isLoading: isLoading ?? this.isLoading,
      error: error,
      sortMode: sortMode ?? this.sortMode,
    );
  }

  List<Journey> get sortedJourneys {
    if (result == null) return [];
    final journeys = List<Journey>.from(result!.journeys);
    switch (sortMode) {
      case JourneySortMode.departure:
        journeys.sort((a, b) =>
            (a.departure ?? DateTime(0)).compareTo(b.departure ?? DateTime(0)));
      case JourneySortMode.arrival:
        journeys.sort((a, b) =>
            (a.arrival ?? DateTime(0)).compareTo(b.arrival ?? DateTime(0)));
      case JourneySortMode.duration:
        journeys.sort((a, b) =>
            (a.duration ?? Duration.zero).compareTo(b.duration ?? Duration.zero));
      case JourneySortMode.transfers:
        journeys.sort((a, b) => a.transfers.compareTo(b.transfers));
    }
    return journeys;
  }
}

class JourneySearchNotifier extends Notifier<JourneySearchState> {
  @override
  JourneySearchState build() => const JourneySearchState();

  void setFrom(Station? station) => state = state.copyWith(from: station);
  void setTo(Station? station) => state = state.copyWith(to: station);
  void setDateTime(DateTime? dt) => state = state.copyWith(dateTime: dt);
  void setIsArrival(bool val) => state = state.copyWith(isArrival: val);
  void setSortMode(JourneySortMode mode) =>
      state = state.copyWith(sortMode: mode);

  void swapStations() {
    state = state.copyWith(from: state.to, to: state.from);
  }

  /// Search with optional text fallback for unresolved station names
  Future<void> search({String? fromText, String? toText}) async {
    state = state.copyWith(isLoading: true, error: null);

    try {
      final hafas = ref.read(hafasServiceProvider);

      // Auto-resolve stations from text if not selected from dropdown
      var from = state.from;
      var to = state.to;

      if (from == null && fromText != null && fromText.trim().length >= 2) {
        final results = await hafas.searchStations(fromText.trim());
        if (results.isNotEmpty) {
          from = results.first;
          state = state.copyWith(from: from);
        }
      }

      if (to == null && toText != null && toText.trim().length >= 2) {
        final results = await hafas.searchStations(toText.trim());
        if (results.isNotEmpty) {
          to = results.first;
          state = state.copyWith(to: to);
        }
      }

      if (from == null || to == null) {
        state = state.copyWith(
          isLoading: false,
          error: from == null && to == null
              ? 'Start und Ziel eingeben.'
              : from == null
                  ? 'Startstation nicht gefunden.'
                  : 'Zielstation nicht gefunden.',
        );
        return;
      }

      AppLog.log('search ${from.name} (${from.id}) → ${to.name} (${to.id}) '
          'at ${state.dateTime ?? "now"} '
          '${state.isArrival ? "[arrival]" : "[departure]"}', tag: 'journey');

      // DB Vendo (DB Navigator backend) is the only working journey source:
      // it returns journeys WITH prices and is not Akamai-gated. The old
      // bahn.de-website journey POST (OPS_BLOCKED) and the public HAFAS mirror
      // (chronically down) were removed — they never succeeded and only added a
      // multi-second hang before the real error surfaced.
      final vendo = ref.read(vendoServiceProvider);
      final settings = ref.read(settingsProvider);
      final result = await vendo.searchJourneys(
        fromLocationId: from.vendoLocationId,
        toLocationId: to.vendoLocationId,
        dateTime: state.dateTime ?? DateTime.now(),
        isArrival: state.isArrival,
        firstClass: settings.bahnCard.isFirstClass,
        ermaessigung: settings.bahnCard.vendoErmaessigung,
        deutschlandTicket: settings.hasDeutschlandTicket,
      );
      AppLog.log('vendo result: ${result.journeys.length} journeys',
          tag: 'journey');
      state = state.copyWith(result: result, isLoading: false);
    } catch (e) {
      AppLog.log('search FAILED: $e', tag: 'journey');
      state = state.copyWith(error: 'Fehler: $e', isLoading: false);
    }
  }

  /// Load earlier connections by replaying the Vendo `frueherContext` token,
  /// prepending the (deduped) results and advancing the earlier token.
  Future<void> loadEarlier() => _loadMore(earlier: true);

  /// Load later connections via the `spaeterContext` token.
  Future<void> loadLater() => _loadMore(earlier: false);

  Future<void> _loadMore({required bool earlier}) async {
    final current = state.result;
    final token = earlier ? current?.earlierRef : current?.laterRef;
    if (token == null || state.from == null || state.to == null) return;

    state = state.copyWith(isLoading: true, error: null);
    try {
      final vendo = ref.read(vendoServiceProvider);
      final settings = ref.read(settingsProvider);
      final more = await vendo.searchJourneys(
        fromLocationId: state.from!.vendoLocationId,
        toLocationId: state.to!.vendoLocationId,
        dateTime: state.dateTime ?? DateTime.now(),
        isArrival: state.isArrival,
        context: token,
        firstClass: settings.bahnCard.isFirstClass,
        ermaessigung: settings.bahnCard.vendoErmaessigung,
        deutschlandTicket: settings.hasDeutschlandTicket,
      );

      // Dedupe against what we already show (paged windows can overlap).
      final existing = current?.journeys ?? const [];
      final seen = existing.map(_journeyKey).toSet();
      final fresh =
          more.journeys.where((j) => seen.add(_journeyKey(j))).toList();

      final combined = JourneyResult(
        journeys: earlier
            ? [...fresh, ...existing]
            : [...existing, ...fresh],
        // Advance only the token we scrolled; keep the other end intact.
        earlierRef: earlier ? more.earlierRef : current?.earlierRef,
        laterRef: earlier ? current?.laterRef : more.laterRef,
      );
      state = state.copyWith(result: combined, isLoading: false);
    } catch (e) {
      AppLog.log('loadMore(${earlier ? "earlier" : "later"}) failed: $e',
          tag: 'journey');
      state = state.copyWith(isLoading: false);
    }
  }

  /// Stable identity for a journey, to dedupe overlapping paged windows.
  String _journeyKey(Journey j) =>
      j.refreshToken ??
      '${j.departure?.toIso8601String()}|${j.arrival?.toIso8601String()}'
          '|${j.legs.firstOrNull?.line?.name ?? ''}';

  void clear() {
    state = const JourneySearchState();
  }
}

final journeySearchProvider =
    NotifierProvider<JourneySearchNotifier, JourneySearchState>(
        JourneySearchNotifier.new);
