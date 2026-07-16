import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../models/departure.dart';
import '../../providers/departure_board_provider.dart';
import '../../providers/nearby_tab_provider.dart';
import '../../providers/train_lookup_provider.dart';
import '../../widgets/station_search_field.dart';
import '../../widgets/delay_badge.dart';
import '../../widgets/platform_badge.dart';
import '../../widgets/app_menu_button.dart';
import '../../widgets/embedded_action_bar.dart';
import '../../core/extensions.dart';
import '../../core/auto_refresh.dart';
import 'departure_map_view.dart';

class DepartureBoardScreen extends ConsumerStatefulWidget {
  /// When embedded in the combined "Bahnhof" screen, drop our own AppBar and
  /// surface its actions as a slim row at the top of the body.
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

    final actions = <Widget>[
      if (state.station != null)
        IconButton(
          tooltip: state.view == BoardView.map ? 'Liste' : 'Karte',
          icon: Icon(state.view == BoardView.map
              ? Icons.format_list_bulleted
              : Icons.map_outlined),
          onPressed: () => notifier.setView(
            state.view == BoardView.map ? BoardView.list : BoardView.map,
          ),
        ),
      if (state.station != null)
        IconButton(
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
              actions: [const AppMenuButton(), ...actions],
            ),
      body: Column(
        children: [
          if (widget.embedded && actions.isNotEmpty)
            EmbeddedActionBar(actions: actions),
          // Station search
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: StationSearchField(
              hint: 'Bahnhof suchen...',
              prefixIcon: Icons.location_city,
              initialStation: state.station,
              onSelected: notifier.setStation,
            ),
          ),

          // Departure / Arrival toggle
          if (state.station != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Row(
                children: [
                  SegmentedButton<BoardMode>(
                    segments: const [
                      ButtonSegment(
                          value: BoardMode.departures,
                          label: Text('Abfahrten'),
                          icon: Icon(Icons.arrow_upward, size: 18)),
                      ButtonSegment(
                          value: BoardMode.arrivals,
                          label: Text('Ankünfte'),
                          icon: Icon(Icons.arrow_downward, size: 18)),
                    ],
                    selected: {state.mode},
                    onSelectionChanged: (v) => notifier.setMode(v.first),
                  ),
                  const Spacer(),
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

          // Board — list or map.
          Expanded(
            child: state.view == BoardView.map
                ? const DepartureMapView()
                : _buildBoard(context, ref, state),
          ),
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
        padding: const EdgeInsets.only(bottom: 32),
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
