import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/station.dart';
import '../models/departure.dart';
import 'service_providers.dart';

enum BoardMode { departures, arrivals }

/// How the board is presented: a scrolling list or the station map.
enum BoardView { list, map }

class DepartureBoardState {
  final Station? station;
  final List<Departure> departures;
  final bool isLoading;
  final String? error;
  final BoardMode mode;
  final String? filterProduct; // null = all
  final BoardView view;

  const DepartureBoardState({
    this.station,
    this.departures = const [],
    this.isLoading = false,
    this.error,
    this.mode = BoardMode.departures,
    this.filterProduct,
    this.view = BoardView.list,
  });

  DepartureBoardState copyWith({
    Station? station,
    List<Departure>? departures,
    bool? isLoading,
    String? error,
    BoardMode? mode,
    String? filterProduct,
    bool clearFilter = false,
    BoardView? view,
  }) {
    return DepartureBoardState(
      station: station ?? this.station,
      departures: departures ?? this.departures,
      isLoading: isLoading ?? this.isLoading,
      error: error,
      mode: mode ?? this.mode,
      filterProduct: clearFilter ? null : (filterProduct ?? this.filterProduct),
      view: view ?? this.view,
    );
  }

  List<Departure> get filteredDepartures {
    if (filterProduct == null) return departures;
    return departures
        .where((d) => d.line.product == filterProduct)
        .toList();
  }
}

class DepartureBoardNotifier extends Notifier<DepartureBoardState> {
  @override
  DepartureBoardState build() => const DepartureBoardState();

  void setStation(Station station) {
    state = state.copyWith(station: station);
    load();
  }

  void setMode(BoardMode mode) {
    state = state.copyWith(mode: mode);
    load();
  }

  void setFilter(String? product) {
    state = state.copyWith(
      filterProduct: product,
      clearFilter: product == null,
    );
  }

  void setView(BoardView view) => state = state.copyWith(view: view);

  Future<void> load() async {
    final station = state.station;
    if (station == null) return;

    state = state.copyWith(isLoading: true, error: null);

    try {
      final hafas = ref.read(hafasServiceProvider);
      final List<Departure> results;

      if (state.mode == BoardMode.departures) {
        results = await hafas.getDepartures(station.id, duration: 120);
      } else {
        results = await hafas.getArrivals(station.id, duration: 120);
      }

      state = state.copyWith(departures: results, isLoading: false);
    } catch (e) {
      state = state.copyWith(error: 'Fehler: $e', isLoading: false);
    }
  }
}

final departureBoardProvider =
    NotifierProvider<DepartureBoardNotifier, DepartureBoardState>(
        DepartureBoardNotifier.new);
