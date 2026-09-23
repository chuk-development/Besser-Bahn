import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/app_log.dart';
import '../core/trip_metrics.dart';
import '../models/journey.dart';
import '../models/library_models.dart';
import '../models/travel_stats.dart';
import 'account_provider.dart';
import 'library_provider.dart';
import 'service_providers.dart';

const _kStatsKey = 'travel_stats_v1';
const _kCountedKey = 'travel_stats_counted_v2';
const _kLegacyCountedKey = 'travel_stats_counted_v1';

/// Lifetime on-device travel statistics. Folds every completed saved trip into
/// a persisted [TravelStats] accumulator exactly once — keyed by the trip's
/// stable [SavedJourney.key] so the same trip never double-counts, and so the
/// totals survive the 7-day auto-purge of the saved-trips list.
///
/// It watches the library and reconciles on every change: any past trip whose
/// key isn't in the counted set gets measured ([TripMetrics]) and added. Pure
/// local — no network, no server.
class TravelStatsNotifier extends Notifier<TravelStats> {
  /// Keys of trips already folded into the totals. Persisted alongside the
  /// stats so a purged trip isn't recounted if it somehow reappears.
  final Set<String> _counted = {};
  bool _loaded = false;

  @override
  TravelStats build() {
    _load();
    // Reconcile whenever saved trips change (a trip just completed, a new one
    // got bookmarked and is already in the past, …).
    ref.listen(libraryProvider, (_, next) => _reconcile(next.pastJourneys));
    // Also reconcile when the DB account's Meine-Reisen list changes — every
    // real bought ticket that's already in the past gets folded in too, so
    // the punctuality / distance numbers come from actual journeys, not just
    // the few the user happened to bookmark locally.
    ref.listen(reisenuebersichtProvider, (_, next) {
      final ticketKeys =
          next.asData?.value.orders
              .map((o) {
                if (o.kundenwunschIds.isEmpty) return null;
                return '${o.auftragsnummer}/${o.kundenwunschIds.first}';
              })
              .whereType<String>()
              .toList() ??
          const <String>[];
      _reconcileTickets(ticketKeys);
    });
    return TravelStats.empty;
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    try {
      final rawStats = prefs.getString(_kStatsKey);
      if (rawStats != null && rawStats.isNotEmpty) {
        state = TravelStats.fromJson(
          jsonDecode(rawStats) as Map<String, dynamic>,
        );
      }
      final rawCounted = prefs.getString(_kCountedKey);
      if (rawCounted != null && rawCounted.isNotEmpty) {
        _counted
          ..clear()
          ..addAll((jsonDecode(rawCounted) as List).cast<String>());
      } else {
        // Migrate v1: prior keys were the raw library journey key; we now
        // namespace them as "lib:<key>" so DB tickets and local saves don't
        // collide. Convert in-place once.
        final legacy = prefs.getString(_kLegacyCountedKey);
        if (legacy != null && legacy.isNotEmpty) {
          _counted
            ..clear()
            ..addAll(
              (jsonDecode(legacy) as List).cast<String>().map((k) => 'lib:$k'),
            );
          await prefs.remove(_kLegacyCountedKey);
        }
      }
    } catch (e) {
      AppLog.log('travel stats load failed ($e)', tag: 'stats');
    }
    _loaded = true;
    // Catch up on any trips that completed while we were away — both local
    // bookmarks and the DB-account tickets currently in cache.
    _reconcile(ref.read(libraryProvider).pastJourneys);
    final uebersicht = ref.read(reisenuebersichtProvider).asData?.value;
    if (uebersicht != null) {
      final keys = uebersicht.orders
          .where((o) => o.kundenwunschIds.isNotEmpty)
          .map((o) => '${o.auftragsnummer}/${o.kundenwunschIds.first}')
          .toList();
      _reconcileTickets(keys);
    }
  }

  /// Fold every not-yet-counted completed trip into the running totals.
  void _reconcile(List<SavedJourney> past) {
    if (!_loaded || past.isEmpty) return;
    var next = state;
    var changed = false;
    for (final saved in past) {
      final key = 'lib:${saved.key}';
      if (_counted.contains(key)) continue;
      _counted.add(key);
      changed = true;
      next = _foldJourney(
        next,
        saved.journey,
        endMs: saved.endTime?.millisecondsSinceEpoch ?? saved.savedAtMs,
      );
    }
    if (changed) {
      state = next;
      _save();
    }
  }

  /// Fold every past DB-account ticket into the totals. Each ticket is
  /// looked up via [ticketProvider] (so the on-disk per-ticket cache wins,
  /// no fresh network) and parsed into a [Journey] via [VendoService]. Only
  /// counted once thanks to the stable `db:<auftragsnummer>/<kwId>` key, so
  /// the lifetime numbers survive across launches and don't double-count.
  Future<void> _reconcileTickets(List<String> ticketKeys) async {
    if (!_loaded || ticketKeys.isEmpty) return;
    final vendo = ref.read(vendoServiceProvider);
    final now = DateTime.now();
    var next = state;
    var changed = false;
    for (final key in ticketKeys) {
      final countedKey = 'db:$key';
      if (_counted.contains(countedKey)) continue;
      try {
        final ticket = await ref.read(ticketProvider(key).future);
        final verb = ticket.verbindungJson;
        if (verb == null) continue;
        final Journey j;
        try {
          j = vendo.parseConnection(verb);
        } catch (_) {
          continue;
        }
        // Only count once the trip has actually completed (else "Pünktlich"
        // would fire for trips that haven't even started).
        final arr = j.plannedArrival ?? j.arrival;
        if (arr == null || arr.isAfter(now)) continue;
        _counted.add(countedKey);
        changed = true;
        next = _foldJourney(next, j, endMs: arr.millisecondsSinceEpoch);
      } catch (e) {
        AppLog.log(
          'stats fold ticket ${AppLog.pii(key, 'Ticket')} failed: $e',
          tag: 'stats',
        );
      }
    }
    if (changed) {
      state = next;
      _save();
    }
  }

  TravelStats _foldJourney(TravelStats s, Journey j, {required int endMs}) {
    final km = TripMetrics.distanceKm(j);
    final delay = TripMetrics.finalArrivalDelayMinutes(j);
    final onTime = delay < TripMetrics.onTimeThresholdMinutes;

    // Jahresrückblick aggregates (#71): accumulate route/line frequency and
    // the transfer tally into fresh maps (the stored ones are const/immutable).
    final routes = Map<String, int>.from(s.routeCounts);
    final routeOnTime = Map<String, int>.from(s.routeOnTime);
    final route = TripMetrics.routeLabel(j);
    if (route.isNotEmpty) {
      routes[route] = (routes[route] ?? 0) + 1;
      // Per-route punctuality (#63) rides along with the count it is compared
      // against, so the two can never drift apart.
      if (onTime) routeOnTime[route] = (routeOnTime[route] ?? 0) + 1;
    }

    final lines = Map<String, int>.from(s.lineCounts);
    for (final line in TripMetrics.linesUsed(j)) {
      lines[line] = (lines[line] ?? 0) + 1;
    }

    return s.copyWith(
      totalKm: s.totalKm + km,
      tripCount: s.tripCount + 1,
      totalDelayMinutes: s.totalDelayMinutes + delay,
      onTimeCount: s.onTimeCount + (onTime ? 1 : 0),
      worstDelayMinutes: delay > s.worstDelayMinutes
          ? delay
          : s.worstDelayMinutes,
      longestTripKm: km > s.longestTripKm ? km : s.longestTripKm,
      firstTripMs: s.firstTripMs == 0 || (endMs != 0 && endMs < s.firstTripMs)
          ? endMs
          : s.firstTripMs,
      routeCounts: routes,
      routeOnTime: routeOnTime,
      lineCounts: lines,
      connectionsTotal: s.connectionsTotal + TripMetrics.transferCount(j),
      connectionsMissed: s.connectionsMissed + TripMetrics.missedConnections(j),
    );
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    try {
      await prefs.setString(_kStatsKey, jsonEncode(state.toJson()));
      await prefs.setString(_kCountedKey, jsonEncode(_counted.toList()));
    } catch (e) {
      AppLog.log('travel stats save failed ($e)', tag: 'stats');
    }
  }

  /// Wipe the lifetime tally (settings "zurücksetzen"). Clears the counted set
  /// too, so still-saved past trips re-accumulate from zero on next reconcile.
  Future<void> reset() async {
    _counted.clear();
    state = TravelStats.empty;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kStatsKey);
    await prefs.remove(_kCountedKey);
    // Re-count whatever past trips are still in the library.
    _reconcile(ref.read(libraryProvider).pastJourneys);
  }
}

final travelStatsProvider = NotifierProvider<TravelStatsNotifier, TravelStats>(
  TravelStatsNotifier.new,
);
