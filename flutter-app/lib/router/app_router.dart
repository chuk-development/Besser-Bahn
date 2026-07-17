import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/onboarding_provider.dart';
import '../screens/home/home_screen.dart';
import '../screens/onboarding/onboarding_screen.dart';
import '../screens/journeys/journeys_screen.dart';
import '../screens/nearby/nearby_screen.dart';
import '../screens/train_lookup/train_lookup_screen.dart';
import '../screens/profile/profile_screen.dart';
import '../screens/profile/ticket_detail_screen.dart';
import '../screens/connection_search/connection_detail_screen.dart' show TicketRef;
import '../screens/connection_search/connection_search_screen.dart';
import '../screens/connection_search/best_price_screen.dart';
import '../screens/station_map/station_map_screen.dart';
import '../screens/connection_search/connection_detail_screen.dart';
import '../models/journey.dart';
import 'tab_pager.dart';
import '../screens/split_ticket/split_ticket_screen.dart';
import '../screens/split_ticket/bulk_split_screen.dart';
import '../screens/settings/settings_screen.dart';
import '../screens/stats/travel_stats_screen.dart';
import '../screens/debug_log/debug_log_screen.dart';
import '../screens/traewelling/traewelling_hub_screen.dart';
import '../screens/traewelling/traewelling_feed_screen.dart';
import '../screens/traewelling/traewelling_friends_screen.dart';
import '../screens/traewelling/traewelling_checkin_screen.dart';

final _rootNavigatorKey = GlobalKey<NavigatorState>();

/// One Navigator per tab — that is what makes them branches and not pages: each
/// keeps its own stack and its own state while the others are parked off to the
/// side of the strip.
final _searchNavigatorKey = GlobalKey<NavigatorState>();
final _journeysNavigatorKey = GlobalKey<NavigatorState>();
final _nearbyNavigatorKey = GlobalKey<NavigatorState>();
final _profileNavigatorKey = GlobalKey<NavigatorState>();

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
      // The four tabs, as branches of one stateful shell. Their order here is
      // the order they lie on the strip and the order the nav bar shows them —
      // it is the only place that decides which tab is index 2.
      StatefulShellRoute(
        builder: (context, state, navigationShell) =>
            HomeScreen(navigationShell: navigationShell),
        // The tabs side by side, panned between — see `tab_pager.dart`.
        navigatorContainerBuilder: (context, navigationShell, children) =>
            TabPager(navigationShell: navigationShell, children: children),
        branches: [
          // Every branch is preloaded, and the pager is why. A jump pans the
          // strip *across* the tabs in between, and a swipe drags the next tab
          // in under the finger — both put a tab on screen before it is the
          // route. A branch that has not been loaded yet has no Navigator, and
          // renders as an empty box: you'd pan over blank screens, and drag a
          // blank page in behind your thumb.
          //
          // The cost is small and worth naming: preloading builds the branch's
          // *Navigator widget*, it does not mount the screen. Each tab's
          // `initState` still waits until the pager first lays that page out —
          // so nothing fetches at startup, only when a tab is actually
          // travelled to or over.
          StatefulShellBranch(
            navigatorKey: _searchNavigatorKey,
            preload: true,
            routes: [
              GoRoute(
                path: '/search',
                builder: (context, state) => const ConnectionSearchScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            navigatorKey: _journeysNavigatorKey,
            preload: true,
            routes: [
              GoRoute(
                path: '/journeys',
                builder: (context, state) => const JourneysScreen(),
              ),
            ],
          ),
          // Combined Zug + Abfahrten + Karte screen (internal tab bar) — the
          // one tab the strip cannot be swiped off, see [TabPager.swipeBlocked].
          StatefulShellBranch(
            navigatorKey: _nearbyNavigatorKey,
            preload: true,
            routes: [
              GoRoute(
                path: '/nearby',
                builder: (context, state) => const NearbyScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            navigatorKey: _profileNavigatorKey,
            preload: true,
            routes: [
              GoRoute(
                path: '/profile',
                builder: (context, state) => const ProfileScreen(),
              ),
            ],
          ),
        ],
      ),
      // A single booked ticket. Loads the order, parses its Reiseplan, and
      // hands off to ConnectionDetailScreen — so a bought ticket reads the
      // SAME route view as a search result, with a Ticket action top-right.
      GoRoute(
        path: '/ticket',
        parentNavigatorKey: _rootNavigatorKey,
        builder: (context, state) {
          final args = state.extra as Map<String, dynamic>? ?? const {};
          return TicketDetailScreen(
            auftragsnummer: args['auftragsnummer'] as String? ?? '',
            kundenwunschId: args['kundenwunschId'] as String? ?? '',
          );
        },
      ),
      // The official Handyticket WebView itself (white background, scrollable),
      // opened from the Ticket icon on the Reiseplan.
      GoRoute(
        path: '/ticket-view',
        parentNavigatorKey: _rootNavigatorKey,
        builder: (context, state) =>
            TicketViewScreen(ticketRef: state.extra as TicketRef),
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
      // Full multi-leg connection detail. `?src=search` marks the ways in that
      // came from a result list — those hide the "search this route again"
      // action, which there is just the back button (#25).
      GoRoute(
        path: '/connection',
        parentNavigatorKey: _rootNavigatorKey,
        builder: (context, state) => ConnectionDetailScreen(
          journey: state.extra as Journey,
          fromSearch: state.uri.queryParameters['src'] == 'search',
        ),
      ),
      // Split-ticket analysis pushed from a connection (above the tab shell) so
      // it gets a real back button — unlike the /split tab which has none.
      GoRoute(
        path: '/split-ticket',
        parentNavigatorKey: _rootNavigatorKey,
        builder: (context, state) =>
            SplitTicketScreen(journey: state.extra as Journey?),
      ),
      // Bulk price comparison: split-ticket every connection of a search at
      // once, so the rider can compare departure times by total price.
      // `?dticket=1` opens the same comparison as the D-Ticket-Optimierer —
      // ordered by what each connection costs on top of the ticket (#28).
      GoRoute(
        path: '/split-compare',
        parentNavigatorKey: _rootNavigatorKey,
        builder: (context, state) => BulkSplitScreen(
          journeys: (state.extra as List<Journey>?) ?? const [],
          dTicketMode: state.uri.queryParameters['dticket'] == '1',
        ),
      ),
      // Bestpreis calendar: what this trip costs across the whole day (#21).
      GoRoute(
        path: '/best-price',
        parentNavigatorKey: _rootNavigatorKey,
        builder: (context, state) {
          final args = state.extra as BestPriceArgs;
          return BestPriceScreen(
              from: args.from, to: args.to, date: args.date);
        },
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
