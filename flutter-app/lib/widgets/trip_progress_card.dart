import 'dart:async';

import 'package:flutter/material.dart';

import '../core/extensions.dart';
import '../models/journey.dart';

/// Client-side "Reisefortschritt": a live countdown + progress bar for an
/// upcoming or in-progress journey. Computes everything on-device from the
/// itinerary's times (ticking each 15 s) — the same model a future Live
/// Activity / home-screen widget / watch face would render.
///
/// Phases: before departure → "Zug fährt in X Min"; on board → a progress bar
/// to the destination plus the next transfer's countdown; after arrival it
/// removes itself.
class TripProgressCard extends StatefulWidget {
  final Journey journey;
  const TripProgressCard({super.key, required this.journey});

  @override
  State<TripProgressCard> createState() => _TripProgressCardState();
}

class _TripProgressCardState extends State<TripProgressCard> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  List<JourneyLeg> get _transit =>
      widget.journey.legs.where((l) => !l.isWalking).toList();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final now = DateTime.now();
    final transit = _transit;
    if (transit.isEmpty) return const SizedBox.shrink();

    final dep = transit.first.departure ?? transit.first.plannedDeparture;
    final arr = transit.last.arrival ?? transit.last.plannedArrival;
    if (dep == null || arr == null) return const SizedBox.shrink();

    // Trip already over → nothing to count down.
    if (now.isAfter(arr)) return const SizedBox.shrink();

    final beforeDeparture = now.isBefore(dep);

    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      color: theme.colorScheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: beforeDeparture
            ? _beforeDeparture(theme, now, dep)
            : _onBoard(theme, now, dep, arr),
      ),
    );
  }

  Widget _beforeDeparture(ThemeData theme, DateTime now, DateTime dep) {
    final mins = dep.difference(now).inMinutes;
    final origin = _transit.first.origin.name;
    final plat = _transit.first.departurePlatform ??
        _transit.first.plannedDeparturePlatform;
    return Row(
      children: [
        Icon(Icons.schedule, color: theme.colorScheme.onSecondaryContainer),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                mins <= 0 ? 'Fährt jetzt ab' : 'Abfahrt in ${_dur(mins)}',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.onSecondaryContainer,
                ),
              ),
              Text(
                'ab $origin · ${dep.hhmm}${plat != null ? ' · Gleis $plat' : ''}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSecondaryContainer
                      .withValues(alpha: 0.8),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _onBoard(ThemeData theme, DateTime now, DateTime dep, DateTime arr) {
    final total = arr.difference(dep).inSeconds;
    final done = now.difference(dep).inSeconds;
    final progress = total <= 0 ? 1.0 : (done / total).clamp(0.0, 1.0);
    final remaining = arr.difference(now).inMinutes;

    // Next transfer still ahead?
    final nextDep = _transit
        .map((l) => l.departure ?? l.plannedDeparture)
        .where((t) => t != null && t.isAfter(now))
        .cast<DateTime?>()
        .firstWhere((_) => true, orElse: () => null);
    JourneyLeg? nextLeg;
    if (nextDep != null) {
      nextLeg = _transit.firstWhere(
        (l) => (l.departure ?? l.plannedDeparture) == nextDep,
        orElse: () => _transit.last,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.train, color: theme.colorScheme.onSecondaryContainer),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                remaining <= 0
                    ? 'Ankunft jetzt'
                    : 'Noch ${_dur(remaining)} bis ${_transit.last.destination.name}',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.onSecondaryContainer,
                ),
              ),
            ),
            Text('${(progress * 100).round()} %',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: theme.colorScheme.onSecondaryContainer,
                )),
          ],
        ),
        const SizedBox(height: 10),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: progress,
            minHeight: 6,
            backgroundColor:
                theme.colorScheme.onSecondaryContainer.withValues(alpha: 0.15),
            color: theme.colorScheme.onSecondaryContainer,
          ),
        ),
        if (nextLeg != null && nextLeg != _transit.first) ...[
          const SizedBox(height: 10),
          Builder(builder: (_) {
            final tDep = nextLeg!.departure ?? nextLeg.plannedDeparture;
            final mins = tDep?.difference(now).inMinutes;
            final plat = nextLeg.departurePlatform ??
                nextLeg.plannedDeparturePlatform;
            return Text(
              'Umstieg in ${nextLeg.origin.name}'
              '${mins != null ? ' · ${nextLeg.line?.displayName ?? "Anschluss"} in ${_dur(mins)}' : ''}'
              '${plat != null ? ' · Gleis $plat' : ''}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSecondaryContainer
                    .withValues(alpha: 0.85),
              ),
            );
          }),
        ],
      ],
    );
  }

  String _dur(int minutes) {
    if (minutes < 60) return '$minutes Min';
    final h = minutes ~/ 60, m = minutes % 60;
    return m == 0 ? '$h h' : '$h h $m Min';
  }
}
