import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/departure_board_provider.dart';
import '../../providers/nearby_tab_provider.dart';
import '../../providers/station_map_provider.dart';
import '../../widgets/app_menu_button.dart';
import '../../widgets/glass_switcher.dart';
import '../departure_board/departure_board_screen.dart';
import '../station_map/station_map_screen.dart';
import '../train_lookup/train_lookup_screen.dart';

/// Combines the former Zug / Abfahrten / Karte tabs into a single screen with
/// an internal, swipeable switcher — fewer bottom-bar destinations, one place
/// for everything about a station.
///
/// **This screen has no AppBar and no TabBar, on purpose.** It used to wear
/// both: a 56 px bar whose only word was "Bahnhof" — which the bottom nav bar
/// already says, in the tab the rider pressed to get here — over a 72 px
/// icon-and-text [TabBar]. 128 px of chrome before the first departure, under a
/// screen that also gives its bottom to a floating nav bar. In its place one
/// [GlassSwitcher]: the nav bar's own pill, moved to the top, floating over the
/// content instead of pushing it down.
class NearbyScreen extends ConsumerStatefulWidget {
  const NearbyScreen({super.key});

  @override
  ConsumerState<NearbyScreen> createState() => _NearbyScreenState();
}

class _NearbyScreenState extends ConsumerState<NearbyScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;

  /// The board station we've already carried over to the map. Guards against
  /// re-clobbering a station the user then picked on the map itself: we only
  /// propagate a board station that's *newer* than the last one we synced, so
  /// re-entering the Karte tab without a fresh Abfahrten pick leaves the map's
  /// own choice alone.
  String? _lastSyncedStationId;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(
      length: 3,
      vsync: this,
      initialIndex: ref.read(nearbyTabProvider),
    );
    // Mirror manual swipes/taps back into the provider so external jumps stay
    // in sync. Only write once the swipe settles.
    _tabs.addListener(() {
      _applyImmersive(_tabs.index);
      if (_tabs.indexIsChanging) return;
      if (_tabs.index != ref.read(nearbyTabProvider)) {
        ref.read(nearbyTabProvider.notifier).select(_tabs.index);
      }
      // Landing on the Karte tab: carry the Abfahrten station over (#Bahnhof
      // sync). One-directional — the map picking its own station never writes
      // back to the board. Done here, not eagerly on setStation, so the map's
      // bahnhof.de fetch only fires when the rider actually opens the tab.
      if (_tabs.index == nearbyTabMap) _syncBoardStationToMap();
    });
    _applyImmersive(_tabs.index);
  }

  /// Full-screen the map: on the Karte tab hide the status/nav bars so the map
  /// owns the whole screen; restore them on Zug/Abfahrten.
  void _applyImmersive(int index) {
    SystemChrome.setEnabledSystemUIMode(
      index == nearbyTabMap
          ? SystemUiMode.immersiveSticky
          : SystemUiMode.edgeToEdge,
    );
  }

  /// A snappy tab jump. TabController defaults to 300 ms `Curves.ease`; the
  /// switcher felt sluggish at that, so we land it faster on the app's own
  /// easeOutCubic (the same curve the pill highlight and the tab pager use).
  static const _switchDuration = Duration(milliseconds: 200);
  void _goTo(int i) =>
      _tabs.animateTo(i, duration: _switchDuration, curve: Curves.easeOutCubic);

  void _syncBoardStationToMap() {
    final board = ref.read(departureBoardProvider).station;
    if (board == null || board.id == _lastSyncedStationId) return;
    _lastSyncedStationId = board.id;
    // Already showing it (e.g. arrived here from a journey) → don't refetch.
    if (ref.read(stationMapProvider).station?.id == board.id) return;
    ref.read(stationMapProvider.notifier).loadForStation(board);
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // External jumps (e.g. tapping a departure → open its train) drive the tab.
    ref.listen<int>(nearbyTabProvider, (_, next) {
      if (_tabs.index != next) _goTo(next);
    });

    return Scaffold(
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [
          // The three views, full width, starting below the floating switcher.
          //
          // Padded here rather than inside each view: all three open with a
          // search field, which is the one thing on the screen that may never
          // be under the glass — so there is nothing for the switcher to float
          // *over* that the rider would want to reach, and pushing the padding
          // down into three screens would only be three chances to forget it.
          Positioned.fill(
            child: TabBarView(
              controller: _tabs,
              // A stiffer settle so a swipe snaps to the next view instead of
              // drifting — the heavy map made the default drift feel endless.
              physics: const _SnappyTabPhysics(),
              children: [
                // Zug and Abfahrten open with a search field that must clear the
                // floating switcher, so they start below it.
                Padding(
                  padding: EdgeInsets.only(top: GlassSwitcher.insetOf(context)),
                  child: const TrainLookupScreen(embedded: true),
                ),
                Padding(
                  padding: EdgeInsets.only(top: GlassSwitcher.insetOf(context)),
                  child: const DepartureBoardScreen(embedded: true),
                ),
                // The map runs full-bleed *under* the switcher — it floats its
                // own search on glass, so nothing needs to clear the top here.
                const StationMapScreen(embedded: true),
              ],
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            // Rebuilt off the controller, not off `nearbyTabProvider`: the
            // provider is only written once a swipe *settles* (see initState),
            // and the highlight has to leave with the tap that started it.
            child: AnimatedBuilder(
              animation: _tabs,
              builder: (context, _) => SafeArea(
                bottom: false,
                child: GlassSwitcher(
                  index: _tabs.index,
                  onChanged: _goTo,
                  // The AppBar's overflow menu, which had nowhere else to go
                  // once the AppBar did.
                  trailing: const AppMenuButton(),
                  items: const [
                    GlassSwitcherItem(
                      icon: Icons.train_outlined,
                      activeIcon: Icons.train,
                      label: 'Zug',
                    ),
                    GlassSwitcherItem(
                      icon: Icons.departure_board_outlined,
                      activeIcon: Icons.departure_board,
                      label: 'Abfahrten',
                    ),
                    GlassSwitcherItem(
                      icon: Icons.map_outlined,
                      activeIcon: Icons.map,
                      label: 'Karte',
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Page physics with a stiff, quickly-damped spring — a swipe between the three
/// Bahnhof views snaps home instead of the default long, soft glide (which felt
/// interminable behind the heavy map). Clamping physics keeps the edges firm.
class _SnappyTabPhysics extends ScrollPhysics {
  const _SnappyTabPhysics({super.parent});

  @override
  _SnappyTabPhysics applyTo(ScrollPhysics? ancestor) =>
      _SnappyTabPhysics(parent: buildParent(ancestor));

  @override
  SpringDescription get spring => SpringDescription.withDampingRatio(
        mass: 0.5,
        stiffness: 220,
        ratio: 1.1,
      );
}
