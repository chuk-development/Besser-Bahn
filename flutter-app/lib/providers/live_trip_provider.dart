import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/app_log.dart';
import '../core/extensions.dart';
import '../models/journey.dart';
import '../models/library_models.dart';
import '../models/transfer_profile.dart';
import '../models/trip.dart';
import '../services/notification_service.dart';
import 'library_provider.dart';
import 'service_providers.dart';
import 'settings_provider.dart';

/// Live snapshot of the trip currently being tracked, for any UI that wants to
/// show it. [trips] maps a leg's tripId → its freshest live run.
class LiveTripState {
  final String? activeKey; // SavedJourney.key being tracked, null if none
  final Map<String, Trip> trips;
  const LiveTripState({this.activeKey, this.trips = const {}});

  LiveTripState copyWith({String? activeKey, Map<String, Trip>? trips}) =>
      LiveTripState(
        activeKey: activeKey ?? this.activeKey,
        trips: trips ?? this.trips,
      );
}

/// The foreground half of the notification feature: while the app is in the
/// foreground and one of the user's saved trips is "active" (departing within
/// the hour, or in progress), this polls that trip's live run on an adaptive
/// cadence — every 30 s near a stop or transfer, slower in between — and fires
/// an OS alert the moment something the user cares about changes: a delay jump,
/// a platform change at *their* stop, a cancellation, or a connection that no
/// longer holds.
///
/// It deliberately polls only the active trip's one or two relevant legs, and
/// only while foreground, so each device touches DB exactly like the official
/// app's own live view — distributed across all users, no server in the loop
/// (see [TripReminderScheduler] for why that matters at scale). GPS intelligence
/// is handled separately by the persistent background companion and needs no
/// server polling while the app is closed.
class LiveTripTracker extends Notifier<LiveTripState>
    with WidgetsBindingObserver {
  Timer? _timer;
  bool _foreground = true;
  bool _polling = false;
  bool _disposed = false;

  /// Last value we alerted per category, so a steady delay doesn't re-ping
  /// every 30 s — only a *change* does.
  final Map<String, String> _lastAlert = {};

  @override
  LiveTripState build() {
    WidgetsBinding.instance.addObserver(this);
    ref.onDispose(() {
      _disposed = true;
      WidgetsBinding.instance.removeObserver(this);
      _timer?.cancel();
    });
    // Re-evaluate the active trip whenever the saved trips or the master
    // notification toggle change.
    ref.listen(libraryProvider, (prev, next) => _evaluate());
    ref.listen(settingsProvider.select((s) => s.remindersEnabled),
        (prev, next) => _evaluate());
    // The GPS companion toggle also gates us: while it's on, a foreground
    // service keeps this isolate alive in the background, so we keep polling
    // and can push a Gleiswechsel with the app pocketed (#50).
    ref.listen(settingsProvider.select((s) => s.exitAlarmEnabled),
        (prev, next) => _evaluate());
    // Defer the first evaluation: it reads `state`, which isn't valid until
    // this build() returns the initial value. Running it in a microtask lets
    // the provider finish initialising first (else Riverpod throws "tried to
    // read the state of an uninitialized provider" and the whole app crashes).
    Future.microtask(() {
      if (!_disposed) _evaluate();
    });
    return const LiveTripState();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) {
      _evaluate(); // came back → refresh now
    } else if (!_keepAliveInBackground) {
      _timer?.cancel(); // no foreground service → the isolate freezes; stand down
    }
    // else: the GPS companion's foreground service is holding this isolate
    // alive, so leave the poll timer running to catch a Gleiswechsel in the
    // background (#50).
  }

  /// Whether we may keep polling once the app is backgrounded. Only true while
  /// the GPS journey companion is enabled — its libre_location foreground
  /// service is what keeps this isolate (and its timers) running; without it
  /// Android freezes us the moment we lose the foreground.
  bool get _keepAliveInBackground =>
      ref.read(settingsProvider).exitAlarmEnabled;

  /// Pick the active saved trip and (re)arm polling. Active = now is within the
  /// hour before departure or anytime before final arrival.
  void _evaluate() {
    final settings = ref.read(settingsProvider);
    // Either half can drive live tracking: reminders (foreground alerts) or the
    // GPS companion (which keeps us alive to alert in the background too, #50).
    final enabled = settings.remindersEnabled || settings.exitAlarmEnabled;
    final active = enabled
        ? _pickActive(ref.read(libraryProvider).upcomingJourneys)
        : null;
    if (active == null) {
      _timer?.cancel();
      _lastAlert.clear();
      if (state.activeKey != null) {
        state = const LiveTripState();
      }
      return;
    }
    if (active.key != state.activeKey) {
      _lastAlert.clear();
      state = LiveTripState(activeKey: active.key);
    }
    _poll(); // immediate, then self-arms
  }

  SavedJourney? _pickActive(List<SavedJourney> upcoming) {
    final now = DateTime.now();
    for (final j in upcoming) {
      // Per-trip opt-out: this trip's live tracking was switched off (#11.2).
      if (!j.watched) continue;
      final dep = j.journey.plannedDeparture ?? j.journey.departure;
      final arr = j.journey.arrival ?? j.journey.plannedArrival;
      if (dep == null) continue;
      final from = dep.subtract(const Duration(hours: 1));
      final to = arr ?? dep.add(const Duration(hours: 3));
      if (now.isAfter(from) && now.isBefore(to)) return j;
    }
    return null;
  }

  Future<void> _poll() async {
    if (_polling || !(_foreground || _keepAliveInBackground)) return;
    final key = state.activeKey;
    final journey = ref
        .read(libraryProvider)
        .upcomingJourneys
        .where((j) => j.key == key)
        .firstOrNull;
    if (journey == null) {
      _evaluate();
      return;
    }
    _polling = true;
    try {
      await _refreshAndAlert(journey.journey);
    } catch (e) {
      AppLog.log('live poll failed ($e)', tag: 'live');
    } finally {
      _polling = false;
    }
    _armNext();
  }

  /// Fetch the current leg (and the next one, for transfer risk), diff against
  /// what we last alerted, and fire notifications for meaningful changes.
  Future<void> _refreshAndAlert(Journey journey) async {
    final transit = journey.legs.where((l) => !l.isWalking).toList();
    final now = DateTime.now();

    // Current leg = first one not yet completed (its arrival still ahead).
    final idx = transit.indexWhere((l) {
      final arr = l.arrival ?? l.plannedArrival;
      return arr == null || arr.isAfter(now.subtract(const Duration(minutes: 2)));
    });
    if (idx < 0) {
      _evaluate(); // whole trip done
      return;
    }
    final leg = transit[idx];
    final hafas = ref.read(hafasServiceProvider);
    final trips = Map<String, Trip>.from(state.trips);

    Trip? curTrip;
    if (leg.tripId != null) {
      curTrip = await hafas.getTrip(leg.tripId!);
      trips[leg.tripId!] = curTrip;
    }

    final boarded = (leg.departure ?? leg.plannedDeparture)
            ?.isBefore(now) ??
        false;

    if (curTrip != null) {
      final lineName = leg.line?.displayName ?? 'Zug';
      if (!boarded) {
        // Before boarding: watch the departure at *my* boarding stop.
        final s = _stopFor(curTrip, leg.origin.id, leg.origin.name);
        if (s != null) {
          _checkCancelled(s, lineName);
          _checkDelay(curTrip.id, '$lineName ab ${leg.origin.name}',
              s.departureDelay, s.departure ?? s.plannedDeparture,
              tag: 'dep');
          _checkPlatform(curTrip.id, leg.origin.name, s.departurePlatform,
              s.plannedDeparturePlatform,
              tag: 'depplat');
        }
      } else {
        // On board: watch arrival at the leg's end (the transfer / final stop).
        final s = _stopFor(curTrip, leg.destination.id, leg.destination.name);
        if (s != null) {
          _checkCancelled(s, lineName);
          _checkDelay(curTrip.id, '$lineName an ${leg.destination.name}',
              s.arrivalDelay, s.arrival ?? s.plannedArrival,
              tag: 'arr');
        }
      }
    }

    // Transfer risk: is there still time to catch the next train?
    final next = idx + 1 < transit.length ? transit[idx + 1] : null;
    if (next != null && next.tripId != null) {
      final nextTrip = await hafas.getTrip(next.tripId!);
      trips[next.tripId!] = nextTrip;
      final arrStop =
          curTrip != null ? _stopFor(curTrip, leg.destination.id, leg.destination.name) : null;
      final depStop = _stopFor(nextTrip, next.origin.id, next.origin.name);
      final liveArr = arrStop?.arrival ?? arrStop?.plannedArrival;
      final liveDep = depStop?.departure ?? depStop?.plannedDeparture;
      _checkPlatform(nextTrip.id, next.origin.name, depStop?.departurePlatform,
          depStop?.plannedDeparturePlatform,
          tag: 'nextplat');
      if (liveArr != null && liveDep != null) {
        final gap = liveDep.difference(liveArr).inMinutes;
        _checkTransfer(next.tripId!, next.line?.displayName ?? 'Anschluss',
            next.origin.name, gap, liveDep,
            samePlatform: journey.samePlatformTransferInto(next));
      }
    }

    state = state.copyWith(trips: trips);
  }

  // ---- change detectors (only ping when the value actually changes) ----

  void _checkCancelled(Stopover s, String line) {
    if (!s.cancelled) return;
    _alertOnce('cancel:${s.stop.id}', 'fällt aus',
        title: 'Fahrt fällt aus', body: '$line entfällt an ${s.stop.name}.');
  }

  void _checkDelay(String tripId, String what, int? delaySec, DateTime? when,
      {required String tag}) {
    if (delaySec == null || delaySec < 300) return; // only ≥5 min
    final min = delaySec ~/ 60;
    // Bucket to 5-min steps so we re-ping when it worsens, not every minute.
    final bucket = (min ~/ 5) * 5;
    _alertOnce('delay:$tag:$tripId', '$bucket',
        title: '+$min Min: $what',
        body: when != null ? 'Neu: ${when.hhmm}.' : 'Verspätung +$min Min.');
  }

  void _checkPlatform(
      String tripId, String station, String? live, String? planned,
      {required String tag}) {
    if (live == null || planned == null || live == planned) return;
    _alertOnce('plat:$tag:$tripId', live,
        title: '⚠️ Gleiswechsel: $station',
        body: 'Jetzt Gleis $live (statt $planned).');
  }

  void _checkTransfer(
      String tripId, String nextLine, String station, int gap, DateTime dep,
      {bool samePlatform = false}) {
    // Judge the gap the way the rider experiences it, so the push and the
    // on-screen risk banner can't disagree about the same transfer (#11.7).
    // Same platform → nothing to walk, so the profile doesn't scale it (#20.6)
    // and we don't buzz someone's pocket over a 6-minute step across.
    final profile = ref.read(settingsProvider).transferProfile;
    final felt = profile.effectiveGap(gap, samePlatform: samePlatform);
    if (felt >= 5) return; // comfortable, stay quiet
    final String title, body;
    if (gap < 0) {
      title = 'Anschluss gefährdet: $nextLine';
      body = 'In $station ${gap.abs()} Min zu spät — Anschluss könnte weg sein.';
    } else {
      title = 'Knapper Umstieg: $nextLine';
      // Quote the planned minutes (that's what the board says) and name the
      // profile when IT is the reason we're pinging at all — "Nur 10 Min ·
      // beeil dich" would otherwise look like a miscalculation.
      final why = (gap > 5 && profile != TransferProfile.normal)
          ? ' (Profil „${profile.label}")'
          : '';
      body = 'Nur $gap Min in $station$why · ab ${dep.hhmm}, beeil dich.';
    }
    _alertOnce('transfer:$tripId', '$gap', title: title, body: body);
  }

  /// Fire an alert for [key] only when [value] differs from what we last sent
  /// for it — kills repeat-pings on every poll.
  void _alertOnce(String key, String value,
      {required String title, required String body}) {
    if (_lastAlert[key] == value) return;
    _lastAlert[key] = value;
    NotificationService.showTripAlert(id: key.hashCode, title: title, body: body);
    AppLog.log('live alert: $title — $body', tag: 'live');
  }

  /// The stopover for a station on a live run, matched by id then by name.
  Stopover? _stopFor(Trip trip, String id, String name) {
    for (final s in trip.stopovers) {
      if (id.isNotEmpty && s.stop.id == id) return s;
    }
    for (final s in trip.stopovers) {
      if (s.stop.name == name) return s;
    }
    return null;
  }

  /// Re-arm the next poll: 30 s when a stop event is within 6 min, else 2 min.
  /// Stops entirely if the active trip has ended.
  void _armNext() {
    _timer?.cancel();
    if (!(_foreground || _keepAliveInBackground) || state.activeKey == null) {
      return;
    }
    final now = DateTime.now();
    var soon = false;
    for (final t in state.trips.values) {
      for (final s in t.stopovers) {
        final e = s.departure ?? s.plannedDeparture ?? s.arrival ?? s.plannedArrival;
        if (e != null && e.isAfter(now)) {
          if (e.difference(now) <= const Duration(minutes: 6)) soon = true;
          break;
        }
      }
    }
    _timer = Timer(
        soon ? const Duration(seconds: 30) : const Duration(minutes: 2),
        _poll);
  }
}

final liveTripTrackerProvider =
    NotifierProvider<LiveTripTracker, LiveTripState>(LiveTripTracker.new);
