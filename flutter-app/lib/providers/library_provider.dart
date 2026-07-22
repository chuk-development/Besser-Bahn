import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/journey.dart';
import '../models/library_models.dart';
import '../models/station.dart';

/// Searching a station this many times auto-pins it to the favorites list.
const int kAutoStarThreshold = 3;

/// How many non-pinned recent stations to surface as suggestions.
const int kMaxRecents = 6;

/// Past "Reisen" linger this long after arrival, then auto-purge on next load.
const Duration kPastJourneyTtl = Duration(days: 7);

const _kStationsKey = 'lib_stations_v1';
const _kRoutesKey = 'lib_routes_v1';
const _kTrainsKey = 'lib_trains_v1';
const _kJourneysKey = 'lib_journeys_v1';

class LibraryState {
  final List<FavoriteStation> stations;
  final List<SavedRoute> routes;
  final List<SavedTrain> trains;
  final List<SavedJourney> journeys;

  const LibraryState({
    this.stations = const [],
    this.routes = const [],
    this.trains = const [],
    this.journeys = const [],
  });

  LibraryState copyWith({
    List<FavoriteStation>? stations,
    List<SavedRoute>? routes,
    List<SavedTrain>? trains,
    List<SavedJourney>? journeys,
  }) {
    return LibraryState(
      stations: stations ?? this.stations,
      routes: routes ?? this.routes,
      trains: trains ?? this.trains,
      journeys: journeys ?? this.journeys,
    );
  }

  /// Pinned stations, most-used first.
  List<Station> get favorites {
    final pinned = stations.where((s) => s.pinned).toList()
      ..sort((a, b) => b.useCount.compareTo(a.useCount));
    return pinned.map((s) => s.station).toList();
  }

  /// Recently used but not pinned, newest first, capped.
  List<Station> get recents {
    final recent = stations.where((s) => !s.pinned && s.lastUsedMs > 0).toList()
      ..sort((a, b) => b.lastUsedMs.compareTo(a.lastUsedMs));
    return recent.take(kMaxRecents).map((s) => s.station).toList();
  }

  bool isStationFavorite(String id) =>
      stations.any((s) => s.station.id == id && s.pinned);

  bool isRouteSaved(String fromId, String toId) =>
      routes.any((r) => r.from.id == fromId && r.to.id == toId);

  bool hasTrain(String key) => trains.any((t) => t.key == key);

  bool hasJourney(String key) => journeys.any((j) => j.key == key);

  /// Upcoming / in-progress trips, soonest departure first.
  List<SavedJourney> get upcomingJourneys {
    final list = journeys.where((j) => !j.isPast).toList()
      ..sort((a, b) {
        final da = a.journey.plannedDeparture ?? a.journey.departure;
        final db = b.journey.plannedDeparture ?? b.journey.departure;
        if (da == null || db == null) return 0;
        return da.compareTo(db);
      });
    return list;
  }

  /// Completed trips, most recent first.
  List<SavedJourney> get pastJourneys {
    final list = journeys.where((j) => j.isPast).toList()
      ..sort((a, b) {
        final ea = a.endTime, eb = b.endTime;
        if (ea == null || eb == null) return 0;
        return eb.compareTo(ea);
      });
    return list;
  }
}

class LibraryNotifier extends Notifier<LibraryState> {
  @override
  LibraryState build() {
    _load();
    return const LibraryState();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();

    List<T> decode<T>(String key, T Function(Map<String, dynamic>) fromJson) {
      final raw = prefs.getString(key);
      if (raw == null || raw.isEmpty) return [];
      try {
        final list = jsonDecode(raw) as List<dynamic>;
        return list
            .map((e) => fromJson(e as Map<String, dynamic>))
            .toList(growable: false);
      } catch (_) {
        return [];
      }
    }

    // Drop trips whose arrival is older than the grace period.
    final cutoff = DateTime.now().subtract(kPastJourneyTtl);
    final journeys = decode(_kJourneysKey, SavedJourney.fromJson)
        .where((j) {
          final end = j.endTime;
          return end == null || end.isAfter(cutoff);
        })
        .toList(growable: false);

    state = LibraryState(
      stations: decode(_kStationsKey, FavoriteStation.fromJson),
      routes: decode(_kRoutesKey, SavedRoute.fromJson),
      trains: decode(_kTrainsKey, SavedTrain.fromJson),
      journeys: journeys,
    );
    // Persist the purge so dropped entries don't resurrect next launch.
    if (journeys.length != decode(_kJourneysKey, SavedJourney.fromJson).length) {
      _saveJourneys();
    }
  }

  Future<void> _saveStations() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kStationsKey,
        jsonEncode(state.stations.map((s) => s.toJson()).toList()));
  }

  Future<void> _saveRoutes() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _kRoutesKey, jsonEncode(state.routes.map((r) => r.toJson()).toList()));
  }

  Future<void> _saveTrains() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _kTrainsKey, jsonEncode(state.trains.map((t) => t.toJson()).toList()));
  }

  Future<void> _saveJourneys() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kJourneysKey,
        jsonEncode(state.journeys.map((j) => j.toJson()).toList()));
  }

  int _nowMs() => DateTime.now().millisecondsSinceEpoch;

  /// Record that the user selected/searched [station]. Increments its use
  /// count, refreshes recency and auto-pins it once it crosses the threshold.
  void recordStationUse(Station station) {
    if (station.id.isEmpty) return;
    final list = List<FavoriteStation>.from(state.stations);
    final idx = list.indexWhere((s) => s.station.id == station.id);
    if (idx >= 0) {
      final existing = list[idx];
      final newCount = existing.useCount + 1;
      list[idx] = existing.copyWith(
        useCount: newCount,
        lastUsedMs: _nowMs(),
        pinned: existing.pinned || newCount >= kAutoStarThreshold,
      );
    } else {
      list.add(FavoriteStation(
        station: station,
        useCount: 1,
        lastUsedMs: _nowMs(),
        pinned: kAutoStarThreshold <= 1,
      ));
    }
    state = state.copyWith(stations: list);
    _saveStations();
  }

  /// Merge a server-side list of stations into the local favorites — used to
  /// pull the DB account's Bahnhof-Favoriten on login. Each [serverStations]
  /// entry is added as a pinned favorite if not already present; existing
  /// entries are upgraded to pinned (useCount/lastUsedMs are preserved). No
  /// network write-back here — the user's local pins remain authoritative.
  void mergeServerFavorites(List<Station> serverStations) {
    if (serverStations.isEmpty) return;
    final list = List<FavoriteStation>.from(state.stations);
    var changed = false;
    for (final s in serverStations) {
      if (s.id.isEmpty && s.locationId == null) continue;
      final idx = list.indexWhere((e) =>
          (e.station.id.isNotEmpty && e.station.id == s.id) ||
          (e.station.locationId != null &&
              e.station.locationId == s.locationId));
      if (idx >= 0) {
        // The user already knows this station — pin it but don't claim it
        // back as server-only; their useCount/manual pin make it theirs.
        if (!list[idx].pinned) {
          list[idx] = list[idx].copyWith(pinned: true);
          changed = true;
        }
      } else {
        // Brand-new entry from the server — flag it so we can drop it on
        // logout without touching anything the user typed themselves.
        list.add(FavoriteStation(
          station: s,
          useCount: 0,
          lastUsedMs: _nowMs(),
          pinned: true,
          fromServer: true,
        ));
        changed = true;
      }
    }
    if (changed) {
      state = state.copyWith(stations: list);
      _saveStations();
    }
  }

  /// Privacy: remove every entry that was pulled in via [mergeServerFavorites]
  /// and never used locally. Called from the auth notifier on logout so the
  /// search suggestions no longer leak a signed-out account's favorites.
  void dropServerFavorites() {
    final kept = state.stations
        .where((s) => !(s.fromServer && s.useCount == 0))
        .map((s) => s.fromServer && s.useCount > 0
            ? s.copyWith(fromServer: false)
            : s)
        .toList();
    if (kept.length == state.stations.length) {
      // Still strip the fromServer flag on entries the user has since used.
      final cleaned = state.stations
          .map((s) => s.fromServer ? s.copyWith(fromServer: false) : s)
          .toList();
      final anyFromServer = state.stations.any((s) => s.fromServer);
      if (!anyFromServer) return;
      state = state.copyWith(stations: cleaned);
    } else {
      state = state.copyWith(stations: kept);
    }
    _saveStations();
  }

  /// Manually star/unstar a station. Unstarring keeps the entry (so it can
  /// still appear in recents) but clears the pin.
  void toggleStationPin(Station station) {
    if (station.id.isEmpty) return;
    final list = List<FavoriteStation>.from(state.stations);
    final idx = list.indexWhere((s) => s.station.id == station.id);
    if (idx >= 0) {
      list[idx] = list[idx].copyWith(pinned: !list[idx].pinned);
    } else {
      list.add(FavoriteStation(
        station: station,
        useCount: 0,
        lastUsedMs: _nowMs(),
        pinned: true,
      ));
    }
    state = state.copyWith(stations: list);
    _saveStations();
  }

  // ---- Routes ----

  void toggleRoute(Station from, Station to) {
    if (from.id.isEmpty || to.id.isEmpty) return;
    final list = List<SavedRoute>.from(state.routes);
    final idx =
        list.indexWhere((r) => r.from.id == from.id && r.to.id == to.id);
    if (idx >= 0) {
      list.removeAt(idx);
    } else {
      list.insert(0, SavedRoute(from: from, to: to));
    }
    state = state.copyWith(routes: list);
    _saveRoutes();
  }

  void removeRoute(String key) {
    state = state.copyWith(
        routes: state.routes.where((r) => r.key != key).toList());
    _saveRoutes();
  }

  // ---- Trains ----

  void toggleTrain(SavedTrain train) {
    final list = List<SavedTrain>.from(state.trains);
    final idx = list.indexWhere((t) => t.key == train.key);
    if (idx >= 0) {
      list.removeAt(idx);
    } else {
      list.insert(0, train);
    }
    state = state.copyWith(trains: list);
    _saveTrains();
  }

  void removeTrain(String key) {
    state = state.copyWith(
        trains: state.trains.where((t) => t.key != key).toList());
    _saveTrains();
  }

  // ---- Journeys (Reisen) ----

  /// Save [journey] as a trip, or remove it if already saved (toggle).
  void toggleJourney(Journey journey) {
    final entry = SavedJourney(journey: journey, savedAtMs: _nowMs());
    final list = List<SavedJourney>.from(state.journeys);
    final idx = list.indexWhere((j) => j.key == entry.key);
    if (idx >= 0) {
      list.removeAt(idx);
    } else {
      list.insert(0, entry);
    }
    state = state.copyWith(journeys: list);
    _saveJourneys();
  }

  void removeJourney(String key) {
    state = state.copyWith(
        journeys: state.journeys.where((j) => j.key != key).toList());
    _saveJourneys();
  }

  /// Put a removed trip back exactly as it was — same save time, same bell.
  /// Backs "Rückgängig" after a swipe delete (#51), which is what makes the
  /// accidental swipe harmless. A trip that's somehow saved again already wins,
  /// so undoing twice can't duplicate it.
  void restoreJourney(SavedJourney entry) {
    if (state.journeys.any((j) => j.key == entry.key)) return;
    state = state.copyWith(journeys: [entry, ...state.journeys]);
    _saveJourneys();
  }

  /// Swap the saved trip [oldKey] for [journey] — the same trip after a leg was
  /// exchanged ("Weitere Abfahrten", "früher aussteigen"). Without this the
  /// library would keep the abandoned itinerary and every notification channel
  /// hanging off it (reminders, live companion, background tracking) would keep
  /// alerting for trains the rider no longer takes (#58).
  ///
  /// No-op when [oldKey] isn't saved: an unsaved trip has nothing to migrate.
  /// Keeps the entry's position, save time and watched flag, and collapses a
  /// collision if the new itinerary happens to carry an already-saved key.
  void replaceJourney(String oldKey, Journey journey) {
    final list = List<SavedJourney>.from(state.journeys);
    final idx = list.indexWhere((j) => j.key == oldKey);
    if (idx < 0) return;
    final previous = list[idx];
    final next = SavedJourney(
      journey: journey,
      savedAtMs: previous.savedAtMs,
      watched: previous.watched,
    );
    if (next.key == oldKey && identical(previous.journey, journey)) return;
    list[idx] = next;
    if (next.key != oldKey) {
      for (var i = list.length - 1; i >= 0; i--) {
        if (i != idx && list[i].key == next.key) list.removeAt(i);
      }
    }
    state = state.copyWith(journeys: list);
    _saveJourneys();
  }

  /// Turn the live companion on/off for one saved trip (#11, point 2).
  void setJourneyWatched(String key, bool watched) {
    state = state.copyWith(
      journeys: [
        for (final j in state.journeys)
          j.key == key ? j.copyWith(watched: watched) : j,
      ],
    );
    _saveJourneys();
  }

  /// Whether the live companion tracks this trip. Unknown trip → false: it
  /// isn't saved, so there's nothing to track.
  bool isJourneyWatched(String key) =>
      state.journeys.where((j) => j.key == key).firstOrNull?.watched ?? false;
}

final libraryProvider =
    NotifierProvider<LibraryNotifier, LibraryState>(LibraryNotifier.new);
