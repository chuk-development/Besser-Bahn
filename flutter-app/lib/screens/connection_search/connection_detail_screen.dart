import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../models/coach_sequence.dart';
import '../../models/journey.dart';
import '../../models/trip.dart';
import '../../providers/service_providers.dart';
import '../../providers/station_map_provider.dart';
import '../train_lookup/widgets/train_detail_view.dart';

/// In-memory cache (app session) so a leg's train data is fetched once and
/// reused — scrolling away and back never re-downloads or rebuilds from
/// scratch; cached data shows instantly and refreshes in the background.
final Map<String, Trip> _tripCache = {};
final Map<String, CoachSequence> _coachCache = {};

/// Full multi-leg connection as ONE screen: each train's complete detail
/// (header, live map, coach sequence, stops) stacked vertically — scroll down
/// to the next train. No intermediate "pick a leg" screen.
class ConnectionDetailScreen extends ConsumerWidget {
  final Journey journey;

  const ConnectionDetailScreen({super.key, required this.journey});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final legs = journey.legs;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          '${journey.origin?.name ?? ''} → ${journey.destination?.name ?? ''}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          _summary(context),
          for (var i = 0; i < legs.length; i++) ...[
            if (i > 0) _transfer(context, legs[i - 1], legs[i]),
            if (legs[i].isWalking)
              _walkLeg(context, legs[i])
            else
              _LegSection(leg: legs[i]),
          ],
        ],
      ),
    );
  }

  Widget _summary(BuildContext context) {
    final theme = Theme.of(context);
    final t = journey.transfers;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Row(
        children: [
          Text(journey.durationString,
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(width: 12),
          Text(t == 0 ? 'Direkt' : '$t Umstieg${t > 1 ? 'e' : ''}',
              style: theme.textTheme.bodyMedium),
          const Spacer(),
          if (journey.price != null)
            Text(journey.price!.formatted,
                style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.primary)),
        ],
      ),
    );
  }

  Widget _walkLeg(BuildContext context, JourneyLeg leg) {
    final mins = (leg.arrival != null && leg.departure != null)
        ? leg.arrival!.difference(leg.departure!).inMinutes
        : null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 16),
      child: Row(
        children: [
          const Icon(Icons.directions_walk, size: 18),
          const SizedBox(width: 8),
          Text(mins != null ? 'Fußweg · $mins min' : 'Fußweg',
              style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }

  Widget _transfer(BuildContext context, JourneyLeg prev, JourneyLeg next) {
    if (prev.isWalking || next.isWalking) return const SizedBox(height: 8);
    final gap = (next.departure != null && prev.arrival != null)
        ? next.departure!.difference(prev.arrival!).inMinutes
        : null;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(Icons.swap_calls,
              size: 18, color: Theme.of(context).colorScheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Text(
            gap != null
                ? 'Umstieg in ${prev.destination.name} · $gap min'
                : 'Umstieg in ${prev.destination.name}',
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

/// One leg = one train, shown with its full detail (fetched on demand).
class _LegSection extends ConsumerStatefulWidget {
  final JourneyLeg leg;
  const _LegSection({required this.leg});

  @override
  ConsumerState<_LegSection> createState() => _LegSectionState();
}

class _LegSectionState extends ConsumerState<_LegSection>
    with AutomaticKeepAliveClientMixin {
  Trip? _trip;
  CoachSequence? _coach;
  bool _loading = true;

  // Keep the leg alive when scrolled off-screen → no dispose, no re-fetch,
  // no UI rebuild when scrolling back to it.
  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final id = widget.leg.tripId;
    if (id == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    // Serve cached data instantly, then refresh silently in the background.
    final cached = _tripCache[id];
    if (cached != null) {
      _trip = cached;
      _coach = _coachCache[id];
      _loading = false;
    }
    await _fetchFresh(id, silent: cached != null);
  }

  Future<void> _fetchFresh(String id, {required bool silent}) async {
    final leg = widget.leg;
    try {
      final trip = await ref.read(hafasServiceProvider).getTrip(id);
      _tripCache[id] = trip;
      if (mounted) setState(() => _trip = trip);
      try {
        final cs = await ref
            .read(coachSequenceServiceProvider)
            .getCoachSequenceForDeparture(
              lineName: leg.line?.displayName ?? '',
              stationEva: leg.origin.id,
              departureTime: leg.departure,
            );
        if (cs != null) {
          _coachCache[id] = cs;
          if (mounted) setState(() => _coach = cs);
        }
      } catch (_) {/* optional */}
    } catch (_) {/* keep cached/fallback */} finally {
      if (mounted && !silent) setState(() => _loading = false);
    }
  }

  void _openStopMap(Stopover stop) {
    if (stop.stop.name.isEmpty) return;
    ref.read(stationMapProvider.notifier).loadForStation(
          stop.stop,
          highlightGleis: stop.platform,
        );
    context.push('/station-map');
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // required by AutomaticKeepAliveClientMixin
    final trip = _trip;
    if (trip != null) {
      final leg = widget.leg;
      return TrainDetailView(
        trip: trip,
        coach: _coach,
        onStopTap: _openStopMap,
        boardingId: leg.origin.id.isNotEmpty ? leg.origin.id : leg.origin.name,
        alightingId: leg.destination.id.isNotEmpty
            ? leg.destination.id
            : leg.destination.name,
      );
    }
    // Loading / fallback: still show the leg summary so the user sees the train.
    final leg = widget.leg;
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: ListTile(
        leading: _loading
            ? const SizedBox(
                width: 20, height: 20,
                child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.train),
        title: Text(leg.line?.displayName ?? 'Zug'),
        subtitle: Text(
            '${leg.origin.name} → ${leg.destination.name}'
            '${leg.direction != null ? '  ·  Richtung ${leg.direction}' : ''}'),
      ),
    );
  }
}
