import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../models/departure.dart';
import '../../providers/departure_board_provider.dart';
import '../../providers/nearby_tab_provider.dart';
import '../../providers/train_lookup_provider.dart';
import '../../widgets/bahnhof_search_bar.dart';
import '../../widgets/app_nav_bar.dart';
import '../../widgets/station_search_field.dart';
import '../../widgets/delay_badge.dart';
import '../../widgets/platform_badge.dart';
import '../../widgets/app_menu_button.dart';
import '../../core/extensions.dart';
import '../../core/auto_refresh.dart';

class DepartureBoardScreen extends ConsumerStatefulWidget {
  /// When embedded in the combined "Bahnhof" screen, drop our own AppBar — the
  /// parent screen's floating switcher is the chrome there.
  final bool embedded;

  const DepartureBoardScreen({super.key, this.embedded = false});

  @override
  ConsumerState<DepartureBoardScreen> createState() =>
      _DepartureBoardScreenState();
}

class _DepartureBoardScreenState extends ConsumerState<DepartureBoardScreen>
    with AutoRefreshMixin {
  @override
  Future<void> onAutoRefresh() =>
      ref.read(departureBoardProvider.notifier).refreshSilent();

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(departureBoardProvider);
    final notifier = ref.read(departureBoardProvider.notifier);
    final theme = Theme.of(context);

    // What this screen can do with the station it has open — in the search
    // row, next to the station they act on, exactly as on the Zug tab.
    final actions = <Widget>[
      if (state.station != null)
        IconButton(
          visualDensity: VisualDensity.compact,
          tooltip: 'Auf der Karte zeigen',
          icon: const Icon(Icons.map_outlined),
          // Go to the Karte tab rather than opening a second map here. There
          // used to be one — a whole other station map with its own floor
          // switcher, living inside this tab — and it was the same map the tab
          // next door already is. The switcher's listener carries this station
          // over on the way (see `NearbyScreen`), so the map lands on the
          // station the rider was just reading.
          onPressed: () =>
              ref.read(nearbyTabProvider.notifier).select(nearbyTabMap),
        ),
      if (state.station != null)
        IconButton(
          visualDensity: VisualDensity.compact,
          tooltip: 'Aktualisieren',
          icon: const Icon(Icons.refresh),
          onPressed: notifier.load,
        ),
    ];

    return Scaffold(
      // Station search dropdown is an overlay; don't resize the body when the
      // keyboard opens (avoids the list jumping under the search field).
      resizeToAvoidBottomInset: false,
      appBar: widget.embedded
          ? null
          : AppBar(
              title: Text(state.station?.name ?? 'Abfahrtstafel'),
              actions: const [AppMenuButton()],
            ),
      body: Column(
        children: [
          // Station search — the shared Bahnhof search bar (same on Zug/Karte).
          BahnhofSearchBar(
            trailing: actions,
            child: StationSearchField(
              hint: 'Bahnhof suchen...',
              prefixIcon: Icons.location_city,
              initialStation: state.station,
              onSelected: notifier.setStation,
              dense: true,
              bare: true,
            ),
          ),

          // Departure / Arrival toggle
          if (state.station != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Row(
                children: [
                  // This row overflowed — the yellow-and-black stripes — on
                  // every phone narrower than ~440 px, which is every phone.
                  // Two fixes, because one alone would only move the cliff:
                  //
                  //  * the checkmark and the arrows are gone. Decoration on
                  //    top of two words that already say which way the trains
                  //    are going, and between them ~90 px of the overflow;
                  //  * what is left scales down rather than overflowing. A
                  //    [SegmentedButton] sizes itself to its labels and does
                  //    not care what it was given, so *any* fixed layout here
                  //    is one system text scale away from the stripes again.
                  //    scaleDown only bites when it has to (the departure
                  //    tile's own trick — see `_DepartureTile.leading`).
                  Expanded(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: SegmentedButton<BoardMode>(
                        showSelectedIcon: false,
                        style: SegmentedButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                        ),
                        segments: const [
                          ButtonSegment(
                            value: BoardMode.departures,
                            label: Text('Abfahrten'),
                          ),
                          ButtonSegment(
                            value: BoardMode.arrivals,
                            label: Text('Ankünfte'),
                          ),
                        ],
                        selected: {state.mode},
                        onSelectionChanged: (v) => notifier.setMode(v.first),
                      ),
                    ),
                  ),
                  // Product filter
                  PopupMenuButton<String?>(
                    icon: Icon(
                      Icons.filter_list,
                      color: state.filterProduct != null
                          ? theme.colorScheme.primary
                          : null,
                    ),
                    tooltip: 'Filter',
                    onSelected: notifier.setFilter,
                    itemBuilder: (_) => [
                      const PopupMenuItem(value: null, child: Text('Alle')),
                      const PopupMenuItem(
                          value: 'nationalExpress', child: Text('ICE')),
                      const PopupMenuItem(
                          value: 'national', child: Text('IC/EC')),
                      const PopupMenuItem(
                          value: 'regionalExpress', child: Text('RE')),
                      const PopupMenuItem(
                          value: 'regional', child: Text('RB')),
                      const PopupMenuItem(
                          value: 'suburban', child: Text('S-Bahn')),
                    ],
                  ),
                ],
              ),
            ),

          // Quiet "last updated" line — auto-refreshes in the background.
          if (state.station != null && state.lastUpdated != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 2),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Icon(Icons.sync,
                      size: 13, color: theme.colorScheme.onSurfaceVariant),
                  const SizedBox(width: 4),
                  Text(
                    'Aktualisiert ${state.lastUpdated!.hhmm}',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            )
          else
            const SizedBox(height: 8),

          // The board.
          Expanded(child: _buildBoard(context, ref, state)),
        ],
      ),
    );
  }

  Widget _buildBoard(
      BuildContext context, WidgetRef ref, DepartureBoardState state) {
    if (state.station == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text(
            'Bahnhof eingeben, um Abfahrten zu sehen.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    if (state.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (state.error != null) {
      return Center(child: Text(state.error!));
    }

    final departures = state.filteredDepartures;
    if (departures.isEmpty) {
      return const Center(child: Text('Keine Ergebnisse.'));
    }

    return RefreshIndicator(
      onRefresh: () =>
          ref.read(departureBoardProvider.notifier).refreshSilent(),
      child: ListView.separated(
        // Clear the floating nav bar — it hovers over this list.
        padding: EdgeInsets.only(bottom: 32 + AppNavBar.insetOf(context)),
        itemCount: departures.length,
        separatorBuilder: (_, __) => const Divider(height: 1, indent: 72),
        itemBuilder: (context, index) {
          return _DepartureTile(
            departure: departures[index],
            onTap: () {
              ref.read(trainLookupProvider.notifier).lookupByTripId(
                    departures[index].tripId,
                    lineLabel: departures[index].line.name,
                  );
              ref.read(nearbyTabProvider.notifier).select(nearbyTabTrain);
              context.go('/nearby');
            },
          );
        },
      ),
    );
  }
}

class _DepartureTile extends StatelessWidget {
  final Departure departure;
  final VoidCallback onTap;

  const _DepartureTile({required this.departure, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final time = departure.plannedWhen?.hhmm ?? '';

    return ListTile(
      onTap: onTap,
      dense: true,
      visualDensity: VisualDensity.compact,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      leading: SizedBox(
        width: 44,
        // Time + badge want ~43 px; the dense ListTile caps leading at 40, so
        // a delayed/cancelled row overflowed by 3 px. scaleDown shrinks the
        // pair to fit only when the badge is there — a plain row is untouched.
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                time,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  decoration:
                      departure.cancelled ? TextDecoration.lineThrough : null,
                ),
              ),
              DelayBadge(
                  delaySeconds: departure.delay,
                  cancelled: departure.cancelled),
            ],
          ),
        ),
      ),
      title: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              departure.line.displayName,
              style: const TextStyle(
                  fontSize: 12, fontWeight: FontWeight.bold),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              departure.direction,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13),
            ),
          ),
        ],
      ),
      subtitle: Row(
        children: [
          PlatformBadge(
            platform: departure.platform,
            plannedPlatform: departure.plannedPlatform,
          ),
          if (departure.remarks.isNotEmpty) ...[
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                departure.remarks.first,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 11,
                    color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
          ],
        ],
      ),
      trailing: const Icon(Icons.chevron_right, size: 20),
    );
  }
}
