import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers/live_trip_provider.dart';
import 'providers/reminder_provider.dart';
import 'providers/travel_stats_provider.dart';
import 'router/app_router.dart';
import 'theme/app_theme.dart';
import 'core/constants.dart';

class BessereBahnApp extends ConsumerWidget {
  const BessereBahnApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Keep the trip-reminder scheduler alive: it watches saved trips + settings
    // and (re)schedules offline OS reminders whenever they change.
    ref.watch(reminderSchedulerProvider);
    // Keep the live-trip tracker alive: while the app is foreground and a saved
    // trip is active, it polls live data and fires delay/platform/transfer
    // alerts.
    ref.watch(liveTripTrackerProvider);
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
