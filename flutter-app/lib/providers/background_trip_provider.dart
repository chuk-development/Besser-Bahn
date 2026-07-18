import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:libre_location/libre_location.dart';

import '../core/app_log.dart';
import '../models/library_models.dart';
import '../services/background_trip_tracking.dart';
import 'library_provider.dart';
import 'live_trip_provider.dart';
import 'settings_provider.dart';

/// Keeps the native location service aligned with the one watched journey.
/// The service itself survives process death; this controller only refreshes
/// its persisted timetable whenever app/live data changes.
class BackgroundTripController extends Notifier<bool> {
  StreamSubscription<Position>? _locations;
  bool _libraryLoaded = false;
  bool _settingsLoaded = false;
  Future<void> _syncQueue = Future<void>.value();

  @override
  bool build() {
    ref.listen(libraryProvider, (previous, next) {
      _libraryLoaded = true;
      _queueSync();
    });
    ref.listen(settingsProvider, (previous, next) {
      _settingsLoaded = true;
      _queueSync();
    });
    ref.listen(liveTripTrackerProvider, (previous, next) => _queueSync());
    ref.onDispose(() => _locations?.cancel());
    return false;
  }

  void _queueSync() {
    _syncQueue = _syncQueue.then((_) => _sync()).catchError((Object e) {
      AppLog.log('background tracking sync failed ($e)', tag: 'live');
    });
  }

  Future<void> _sync() async {
    // Both providers hydrate asynchronously from SharedPreferences. Waiting
    // for both prevents their temporary default states from stopping a valid
    // service every time the app launches.
    if (!_libraryLoaded || !_settingsLoaded) return;
    final settings = ref.read(settingsProvider);
    final active = settings.exitAlarmEnabled
        ? _pickActive(ref.read(libraryProvider).journeys)
        : null;

    if (active == null) {
      await _deactivate();
      return;
    }

    final live = ref.read(liveTripTrackerProvider);
    final plan = BackgroundJourneyPlan.fromJourney(
      active,
      ringAlarm: settings.arrivalAlarmSound,
      liveTrips: live.activeKey == active.key ? live.trips : const {},
    );
    // No usable route (e.g. a leg without coordinates): tear down any service
    // still running the previous plan — otherwise it keeps processing positions
    // for a journey that's no longer being tracked.
    if (plan.legs.isEmpty) {
      await _deactivate();
      return;
    }
    await BackgroundTripTracking.writePlan(plan);

    try {
      final permission = await LibreLocation.checkPermission();
      if (permission != LocationPermission.always) {
        await _deactivate();
        return;
      }
      _locations ??= LibreLocation.onLocation.listen(
        BackgroundTripTracking.processPosition,
        onError: (Object e) =>
            AppLog.log('background location stream failed ($e)', tag: 'live'),
      );
      if (!await LibreLocation.isTracking) {
        await LibreLocation.start(
          preset: TrackingPreset.balanced,
          config: const LocationConfig(
            notification: NotificationConfig(
              title: 'Live-Reisebegleitung aktiv',
              text: 'Ausstieg und Reiseverlauf werden im Hintergrund erkannt.',
            ),
            stopOnTerminate: false,
            startOnBoot: true,
            enableHeadless: true,
          ),
        );
      }
      state = true;
    } catch (e) {
      AppLog.log('background tracking start failed ($e)', tag: 'live');
      state = false;
    }
  }

  /// Tear the tracker down completely: drop the persisted plan, cancel our
  /// location subscription (so no stale listener survives a later re-enable),
  /// and stop the native service. Every path that decides "nothing to track"
  /// routes through here so a previous plan can never keep running.
  Future<void> _deactivate() async {
    await _locations?.cancel();
    _locations = null;
    await BackgroundTripTracking.clearPlan();
    try {
      if (await LibreLocation.isTracking) await LibreLocation.stop();
    } catch (e) {
      AppLog.log('background tracking stop failed ($e)', tag: 'live');
    }
    state = false;
  }

  // The watched trip whose window (departure −1h … arrival +4h) contains now.
  //
  // KNOWN LIMITATION (tracked): activation is driven by provider emissions, so
  // it fires when the app is in the foreground at any point in the window —
  // including when the user taps the scheduled "Bereit machen" reminder, which
  // opens the app and re-runs [_sync]. If the app stays fully closed for the
  // whole pre-departure hour, nothing starts the service until it's next
  // opened. Truly unattended start would need a native exact-alarm →
  // foreground-service bridge (AlarmManager receiver); deferred because modern
  // Android forbids starting a foreground service from the background without
  // it, and that native plumbing lives in MainActivity.
  SavedJourney? _pickActive(List<SavedJourney> journeys) {
    final now = DateTime.now();
    final candidates = journeys.where((saved) {
      if (!saved.watched) return false;
      final departure =
          saved.journey.plannedDeparture ?? saved.journey.departure;
      final arrival = saved.journey.plannedArrival ?? saved.journey.arrival;
      if (departure == null || arrival == null) return false;
      return now.isAfter(departure.subtract(const Duration(hours: 1))) &&
          now.isBefore(arrival.add(const Duration(hours: 4)));
    }).toList();
    if (candidates.isEmpty) return null;

    // Prefer a trip that should still be running. If all are nominally over,
    // the latest departure is the plausible badly delayed one.
    candidates.sort((a, b) {
      final aArrival = a.journey.plannedArrival ?? a.journey.arrival!;
      final bArrival = b.journey.plannedArrival ?? b.journey.arrival!;
      final aRunning = now.isBefore(aArrival.add(const Duration(minutes: 30)));
      final bRunning = now.isBefore(bArrival.add(const Duration(minutes: 30)));
      if (aRunning != bRunning) return aRunning ? -1 : 1;
      final aDeparture = a.journey.plannedDeparture ?? a.journey.departure!;
      final bDeparture = b.journey.plannedDeparture ?? b.journey.departure!;
      return bDeparture.compareTo(aDeparture);
    });
    return candidates.first;
  }
}

final backgroundTripControllerProvider =
    NotifierProvider<BackgroundTripController, bool>(
      BackgroundTripController.new,
    );
