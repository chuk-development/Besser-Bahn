import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/app_log.dart';
import 'core/constants.dart';
import 'core/missed_connection.dart';
import 'models/library_models.dart';
import 'providers/background_trip_provider.dart';
import 'providers/journey_search_provider.dart';
import 'providers/library_provider.dart';
import 'providers/live_trip_provider.dart';
import 'providers/reminder_provider.dart';
import 'providers/travel_stats_provider.dart';
import 'router/app_router.dart';
import 'services/notification_service.dart';
import 'theme/app_theme.dart';

class BessereBahnApp extends ConsumerStatefulWidget {
  const BessereBahnApp({super.key});

  @override
  ConsumerState<BessereBahnApp> createState() => _BessereBahnAppState();
}

class _BessereBahnAppState extends ConsumerState<BessereBahnApp> {
  StreamSubscription<MissedConnectionRescue>? _missedSubscription;
  StreamSubscription<String>? _tripOpenSubscription;

  @override
  void initState() {
    super.initState();
    _missedSubscription = NotificationService.missedRescues.listen((rescue) {
      unawaited(_openMissedAlternatives(rescue, consumePersisted: true));
    });
    _tripOpenSubscription = NotificationService.tripOpens.listen((key) {
      unawaited(_openTrip(key, consumePersisted: true));
    });
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final rescue = await NotificationService.takePendingMissedRescue();
      if (rescue != null && mounted) await _openMissedAlternatives(rescue);
      // A tap that cold-started the app: the response was handled before any
      // of this existed, so it waited on disk.
      final tripKey = await NotificationService.takePendingTripKey();
      if (tripKey != null && mounted) await _openTrip(tripKey);
    });
  }

  @override
  void dispose() {
    _missedSubscription?.cancel();
    _tripOpenSubscription?.cancel();
    super.dispose();
  }

  /// A trip notification was tapped: show THAT trip's Reiseplan.
  ///
  /// "Dein Zug fährt in 30 Min" that merely opens the app puts the rider back
  /// where they left off — usually the search — and makes them find the trip
  /// themselves. The Reisen tab is selected first, so Back leads to the trip
  /// list rather than to whatever screen the app happened to be on.
  Future<void> _openTrip(String key, {bool consumePersisted = false}) async {
    // The stream fired, so the persisted copy (written for the cold-start case)
    // is now stale — drop it before it opens the same trip a second time.
    if (consumePersisted) await NotificationService.takePendingTripKey();
    final saved = await _awaitSavedJourney(key);
    if (!mounted) return;
    final router = ref.read(appRouterProvider);
    router.go('/journeys');
    if (saved == null) {
      // Deleted, or aged out of the library — the trip list is still a better
      // answer than the screen the rider happened to be on.
      AppLog.log(
        'notification trip ${AppLog.pii(key, 'Reise')} not in library',
        tag: 'notify',
      );
      return;
    }
    router.push('/connection', extra: saved.journey);
  }

  /// The saved trip for [key], waiting out the library's async load.
  ///
  /// On a cold start this runs while `libraryProvider` is still reading from
  /// disk, where an empty list means "not yet" rather than "not there" — giving
  /// up immediately would send every notification tap to an empty trip list.
  Future<SavedJourney?> _awaitSavedJourney(String key) async {
    for (var i = 0; i < 20; i++) {
      final library = ref.read(libraryProvider);
      if (library.loaded) {
        return library.journeys.where((j) => j.key == key).firstOrNull;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
      if (!mounted) return null;
    }
    return null;
  }

  Future<void> _openMissedAlternatives(
    MissedConnectionRescue rescue, {
    bool consumePersisted = false,
  }) async {
    if (consumePersisted) await NotificationService.takePendingMissedRescue();
    if (!mounted) return;
    _silenceMissedJourney(rescue);
    final search = ref.read(journeySearchProvider.notifier);
    search.setFrom(rescue.from);
    search.setTo(rescue.to);
    search.setDateTime(DateTime.now().add(const Duration(minutes: 1)));
    search.setIsArrival(false);
    ref.read(appRouterProvider).go('/search');
    await search.search();
  }

  /// The rider just told us they missed [rescue]'s train, so that itinerary is
  /// over — switch its alerts off before offering replacements, otherwise the
  /// abandoned trip keeps pinging alongside the new one (#58). Matched by the
  /// missed boarding stop and its scheduled departure; the trip stays saved and
  /// the bell in its Reiseplan turns the alerts back on.
  void _silenceMissedJourney(MissedConnectionRescue rescue) {
    final library = ref.read(libraryProvider.notifier);
    for (final saved in ref.read(libraryProvider).journeys) {
      if (!saved.watched) continue;
      final matches = saved.journey.legs.where((l) => !l.isWalking).any((leg) {
        final departure = leg.departure ?? leg.plannedDeparture;
        return leg.origin.id == rescue.from.id &&
            departure == rescue.scheduledDeparture;
      });
      if (matches) library.setJourneyWatched(saved.key, false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Keep the trip-reminder scheduler alive: it watches saved trips + settings
    // and (re)schedules offline OS reminders whenever they change.
    ref.watch(reminderSchedulerProvider);
    // Keep the live-trip tracker alive: while the app is foreground and a saved
    // trip is active, it polls live data and fires delay/platform/transfer
    // alerts.
    ref.watch(liveTripTrackerProvider);
    // Keep the GPS companion aligned with the active watched journey. Its
    // native foreground service continues independently when this UI closes.
    ref.watch(backgroundTripControllerProvider);
    // Keep the lifetime travel-stats accumulator alive: it watches saved trips
    // and folds each completed one into the on-device km/punctuality totals.
    ref.watch(travelStatsProvider);
    return MaterialApp.router(
      title: AppConstants.appName,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: ThemeMode.system,
      routerConfig: ref.watch(appRouterProvider),
    );
  }
}
