import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/app_log.dart';
import '../core/trip_metrics.dart';
import '../models/library_models.dart';
import '../models/travel_stats.dart';
import 'library_provider.dart';

const _kStatsKey = 'travel_stats_v1';
const _kCountedKey = 'travel_stats_counted_v1';

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
    return TravelStats.empty;
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    try {
      final rawStats = prefs.getString(_kStatsKey);
      if (rawStats != null && rawStats.isNotEmpty) {
        state = TravelStats.fromJson(
            jsonDecode(rawStats) as Map<String, dynamic>);
      }
      final rawCounted = prefs.getString(_kCountedKey);
      if (rawCounted != null && rawCounted.isNotEmpty) {
        _counted
          ..clear()
          ..addAll((jsonDecode(rawCounted) as List).cast<String>());
      }
    } catch (e) {
      AppLog.log('travel stats load failed ($e)', tag: 'stats');
    }
    _loaded = true;
    // Catch up on any trips that completed while we were away.
    _reconcile(ref.read(libraryProvider).pastJourneys);
  }

  /// Fold every not-yet-counted completed trip into the running totals.
  void _reconcile(List<SavedJourney> past) {
    if (!_loaded || past.isEmpty) return;
    var next = state;
    var changed = false;
    for (final saved in past) {
      if (_counted.contains(saved.key)) continue;
      _counted.add(saved.key);
      changed = true;
      next = _fold(next, saved);
    }
    if (changed) {
      state = next;
      _save();
    }
  }

  TravelStats _fold(TravelStats s, SavedJourney saved) {
    final km = TripMetrics.distanceKm(saved.journey);
    final delay = TripMetrics.finalArrivalDelayMinutes(saved.journey);
    final onTime = delay < TripMetrics.onTimeThresholdMinutes;
    final endMs = saved.endTime?.millisecondsSinceEpoch ?? saved.savedAtMs;
    return s.copyWith(
      totalKm: s.totalKm + km,
      tripCount: s.tripCount + 1,
      totalDelayMinutes: s.totalDelayMinutes + delay,
      onTimeCount: s.onTimeCount + (onTime ? 1 : 0),
      worstDelayMinutes: delay > s.worstDelayMinutes ? delay : s.worstDelayMinutes,
      longestTripKm: km > s.longestTripKm ? km : s.longestTripKm,
      firstTripMs: s.firstTripMs == 0 || (endMs != 0 && endMs < s.firstTripMs)
          ? endMs
          : s.firstTripMs,
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

final travelStatsProvider =
    NotifierProvider<TravelStatsNotifier, TravelStats>(TravelStatsNotifier.new);
