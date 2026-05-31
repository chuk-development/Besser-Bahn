import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/onboarding_provider.dart';
import '../screens/home/home_screen.dart';
import '../screens/onboarding/onboarding_screen.dart';
import '../screens/journeys/journeys_screen.dart';
import '../screens/nearby/nearby_screen.dart';
import '../screens/train_lookup/train_lookup_screen.dart';
import '../screens/connection_search/connection_search_screen.dart';
import '../screens/station_map/station_map_screen.dart';
import '../screens/connection_search/connection_detail_screen.dart';
import '../models/journey.dart';
import '../screens/split_ticket/split_ticket_screen.dart';
import '../screens/settings/settings_screen.dart';
import '../screens/stats/travel_stats_screen.dart';
import '../screens/debug_log/debug_log_screen.dart';
import '../screens/traewelling/traewelling_hub_screen.dart';
import '../screens/traewelling/traewelling_feed_screen.dart';
import '../screens/traewelling/traewelling_friends_screen.dart';
import '../screens/traewelling/traewelling_checkin_screen.dart';

final _rootNavigatorKey = GlobalKey<NavigatorState>();
final _shellNavigatorKey = GlobalKey<NavigatorState>();

/// The app router, exposed as a provider so its first-run redirect can react to
/// the onboarding-seen state. Built once; the redirect re-runs whenever that
/// state changes (the provider notifies GoRouter via [_routerRefresh]).
final appRouterProvider = Provider<GoRouter>((ref) {
  // Bridge Riverpod → GoRouter: when "seen onboarding" resolves/changes, poke
  // the router so its redirect re-evaluates (e.g. leave /onboarding for /search
  // once the flow completes).
  final refresh = _routerRefresh();
  ref.listen<bool?>(onboardingSeenProvider, (_, next) => refresh.bump());
  ref.onDispose(refresh.dispose);

  return GoRouter(
    navigatorKey: _rootNavigatorKey,
    initialLocation: '/search',
    refreshListenable: refresh,
    redirect: (context, state) {
      final seen = ref.read(onboardingSeenProvider);
      // Still loading the flag — don't redirect, avoid flashing a wrong screen.
      if (seen == null) return null;
      final atOnboarding = state.matchedLocation == '/onboarding';
      if (!seen) return atOnboarding ? null : '/onboarding';
      // Already onboarded: never let the onboarding route show.
      if (atOnboarding) return '/search';
      return null;
    },
    routes: [
      GoRoute(
        path: '/onboarding',
        parentNavigatorKey: _rootNavigatorKey,
        builder: (context, state) => const OnboardingScreen(),
      ),
      ShellRoute(
        navigatorKey: _shellNavigatorKey,
        builder: (context, state, child) => HomeScreen(child: child),
        routes: [
          GoRoute(
            path: '/search',
            pageBuilder: (context, state) =>
                const NoTransitionPage(child: ConnectionSearchScreen()),
          ),
          GoRoute(
            path: '/journeys',
            pageBuilder: (context, state) =>
                const NoTransitionPage(child: JourneysScreen()),
          ),
          // Combined Zug + Abfahrten + Karte screen (internal tab bar).
          GoRoute(
            path: '/nearby',
            pageBuilder: (context, state) =>
                const NoTransitionPage(child: NearbyScreen()),
          ),
        ],
      ),
      // Secondary destinations moved out of the bottom bar into the AppBar
      // overflow menu — pushed on the root navigator so they get a back button.
      GoRoute(
        path: '/split',
        parentNavigatorKey: _rootNavigatorKey,
        builder: (context, state) => const SplitTicketScreen(),
      ),
      GoRoute(
        path: '/settings',
        parentNavigatorKey: _rootNavigatorKey,
        builder: (context, state) => const SettingsScreen(),
      ),
      GoRoute(
        path: '/stats',
        parentNavigatorKey: _rootNavigatorKey,
        builder: (context, state) => const TravelStatsScreen(),
      ),
      GoRoute(
        path: '/debug-log',
        parentNavigatorKey: _rootNavigatorKey,
        builder: (context, state) => const DebugLogScreen(),
      ),
      // Full-screen station map pushed from a journey/stop. Lives on the root
      // navigator (above the tab shell) so it gets a real back button, system
      // back and swipe-back — unlike the /map tab which just switches tabs.
      GoRoute(
        path: '/station-map',
        parentNavigatorKey: _rootNavigatorKey,
        // Dedicated mode: opened for a specific station from a journey/stop, so
        // no station search field and no app overflow menu — just this map.
        builder: (context, state) => const StationMapScreen(dedicated: true),
      ),
      // Full multi-leg connection detail (pushed from a search result).
      GoRoute(
        path: '/connection',
        parentNavigatorKey: _rootNavigatorKey,
        builder: (context, state) =>
            ConnectionDetailScreen(journey: state.extra as Journey),
      ),
      // Split-ticket analysis pushed from a connection (above the tab shell) so
      // it gets a real back button — unlike the /split tab which has none.
      GoRoute(
        path: '/split-ticket',
        parentNavigatorKey: _rootNavigatorKey,
        builder: (context, state) =>
            SplitTicketScreen(journey: state.extra as Journey?),
      ),
      // A single train's run, pushed (with back button) from a connection leg
      // or anywhere — renders the same train view as the tab.
      GoRoute(
        path: '/train-run',
        parentNavigatorKey: _rootNavigatorKey,
        builder: (context, state) => const TrainLookupScreen(),
      ),
      // Träwelling check-in / social section, reached via the AppBar avatar.
      // Full-screen routes on the root navigator (real back button).
      GoRoute(
        path: '/trawelling',
        parentNavigatorKey: _rootNavigatorKey,
        builder: (context, state) => const TraewellingHubScreen(),
      ),
      GoRoute(
        path: '/trawelling/feed',
        parentNavigatorKey: _rootNavigatorKey,
        builder: (context, state) => const TraewellingFeedScreen(),
      ),
      GoRoute(
        path: '/trawelling/friends',
        parentNavigatorKey: _rootNavigatorKey,
        builder: (context, state) => const TraewellingFriendsScreen(),
      ),
      GoRoute(
        path: '/trawelling/checkin',
        parentNavigatorKey: _rootNavigatorKey,
        builder: (context, state) => const TraewellingCheckinScreen(),
      ),
    ],
  );
});

/// A tiny [Listenable] the onboarding provider can ping so GoRouter re-runs its
/// redirect (GoRouter only listens to a Listenable, not Riverpod directly).
class _RouterRefresh extends ChangeNotifier {
  void bump() => notifyListeners();
}

_RouterRefresh _routerRefresh() => _RouterRefresh();
