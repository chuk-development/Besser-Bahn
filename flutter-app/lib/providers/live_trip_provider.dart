import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

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
/// (see [TripReminderScheduler] for why that matters at scale). Closed-app live
/// alerts would need a foreground service / server push and are out of scope.
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
    } else {
      _timer?.cancel(); // never poll while backgrounded
    }
  }

  /// Pick the active saved trip and (re)arm polling. Active = now is within the
  /// hour before departure or anytime before final arrival.
  void _evaluate() {
    final enabled = ref.read(settingsProvider).remindersEnabled;
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
    if (_polling || !_foreground) return;
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

    // GPS "Ausstiegsalarm": once on board and closing in on the alighting stop,
    // ring the loud alarm the moment we physically enter its radius — works
    // even when the timetable is wrong.
    if (boarded) await _checkExitGeofence(leg);

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
            next.origin.name, gap, liveDep);
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
        title: 'Gleiswechsel: $station',
        body: 'Jetzt Gleis $live (statt $planned).');
  }

  void _checkTransfer(
      String tripId, String nextLine, String station, int gap, DateTime dep) {
    // Judge the gap the way the rider experiences it, so the push and the
    // on-screen risk banner can't disagree about the same transfer (#11.7).
    final profile = ref.read(settingsProvider).transferProfile;
    final felt = profile.effectiveGap(gap);
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

  /// Radius around the alighting stop that trips the GPS exit alarm.
  static const double _exitRadiusMetres = 1500;

  /// GPS exit alarm. Only runs when the user opted in, the alighting stop has
  /// coordinates, and arrival is within ~20 min (so we don't burn GPS the whole
  /// trip). Fires the loud alarm once when the device is inside the radius.
  Future<void> _checkExitGeofence(JourneyLeg leg) async {
    if (!ref.read(settingsProvider).exitAlarmEnabled) return;
    final dest = leg.destination;
    if (!dest.hasLocation) return;
    final arr = leg.arrival ?? leg.plannedArrival;
    if (arr != null && arr.difference(DateTime.now()) > const Duration(minutes: 20)) {
      return;
    }
    final key = 'exit:${dest.id}';
    if (_lastAlert[key] != null) return; // already rung for this stop
    try {
      final fix = await ref.read(locationServiceProvider).currentFix();
      final metres = const Distance().as(
        LengthUnit.Meter,
        fix.latLng,
        LatLng(dest.latitude!, dest.longitude!),
      );
      if (metres <= _exitRadiusMetres) {
        _lastAlert[key] = '1';
        NotificationService.showExitAlarm(
          id: key.hashCode,
          title: 'Gleich aussteigen: ${dest.name}',
          body: 'Du bist fast da — ${dest.name}. Sachen schnappen!',
        );
        AppLog.log('exit alarm fired near ${dest.name}', tag: 'live');
      }
    } catch (_) {/* no fix / permission denied — stay quiet */}
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
    if (!_foreground || state.activeKey == null) return;
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
