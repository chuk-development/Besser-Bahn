import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../models/departure.dart';
import '../../providers/departure_board_provider.dart';
import '../../providers/train_lookup_provider.dart';
import '../../widgets/station_search_field.dart';
import '../../widgets/delay_badge.dart';
import '../../widgets/platform_badge.dart';
import '../../widgets/traewelling_avatar_button.dart';
import '../../core/extensions.dart';

class DepartureBoardScreen extends ConsumerWidget {
  const DepartureBoardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(departureBoardProvider);
    final notifier = ref.read(departureBoardProvider.notifier);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(state.station?.name ?? 'Abfahrtstafel'),
        actions: [
          const TraewellingAvatarButton(),
          if (state.station != null)
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: notifier.load,
            ),
        ],
      ),
      body: Column(
        children: [
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

          const SizedBox(height: 8),

          // Board
          Expanded(
            child: _buildBoard(context, ref, state),
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
      onRefresh: () => ref.read(departureBoardProvider.notifier).load(),
      child: ListView.separated(
        padding: const EdgeInsets.only(bottom: 32),
        itemCount: departures.length,
        separatorBuilder: (_, __) => const Divider(height: 1, indent: 72),
        itemBuilder: (context, index) {
          return _DepartureTile(
            departure: departures[index],
            onTap: () {
              ref
                  .read(trainLookupProvider.notifier)
                  .lookupByTripId(departures[index].tripId);
              context.go('/train');
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
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: SizedBox(
        width: 48,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              time,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                decoration:
                    departure.cancelled ? TextDecoration.lineThrough : null,
              ),
            ),
            DelayBadge(
                delaySeconds: departure.delay, cancelled: departure.cancelled),
          ],
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
                  fontSize: 13, fontWeight: FontWeight.bold),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              departure.direction,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 14),
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
