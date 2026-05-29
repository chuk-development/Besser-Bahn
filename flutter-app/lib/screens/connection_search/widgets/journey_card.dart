import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../models/journey.dart';
import '../../../core/extensions.dart';
import '../../../widgets/delay_badge.dart';
import '../../../widgets/platform_badge.dart';
import '../../../widgets/occupancy_indicator.dart';
import '../../../widgets/prediction_badge.dart';

class JourneyCard extends ConsumerWidget {
  final Journey journey;

  const JourneyCard({super.key, required this.journey});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final transitLegs = journey.legs.where((l) => !l.isWalking).toList();

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () {
          // Show the FULL connection (all legs + transfers), not just leg 1.
          context.push('/connection', extra: journey);
        },
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // Prediction strip (Anschluss / Pünktlichkeit) on the left.
              PredictionBadge(journey: journey),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
            children: [
              // Route row: which station to which station — so a saved/searched
              // connection is identifiable at a glance, not just by its times.
              Row(
                children: [
                  Expanded(
                    child: Text(
                      journey.origin?.name ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w600),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Icon(Icons.arrow_forward,
                        size: 13, color: theme.colorScheme.onSurfaceVariant),
                  ),
                  Expanded(
                    child: Text(
                      journey.destination?.name ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.end,
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),

              // Time row
              Row(
                children: [
                  // Departure
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _timeWithDelay(context, journey.plannedDeparture,
                          journey.legs.firstOrNull?.departureDelay),
                      if (journey.legs.firstOrNull?.departurePlatform != null)
                        PlatformBadge(
                          platform:
                              journey.legs.firstOrNull?.departurePlatform,
                          plannedPlatform: journey
                              .legs.firstOrNull?.plannedDeparturePlatform,
                        ),
                    ],
                  ),

                  // Duration & transfers
                  Expanded(
                    child: Column(
                      children: [
                        Text(
                          journey.durationString,
                          style: theme.textTheme.bodySmall?.copyWith(
                              fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 2),
                        _transferIndicator(context, journey.transfers,
                            transitLegs),
                      ],
                    ),
                  ),

                  // Arrival
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      _timeWithDelay(context, journey.plannedArrival,
                          journey.legs.lastOrNull?.arrivalDelay),
                      if (journey.legs.lastOrNull?.arrivalPlatform != null)
                        PlatformBadge(
                          platform:
                              journey.legs.lastOrNull?.arrivalPlatform,
                          plannedPlatform: journey
                              .legs.lastOrNull?.plannedArrivalPlatform,
                        ),
                    ],
                  ),
                ],
              ),

              const SizedBox(height: 8),

              // Product chips + occupancy
              Row(
                children: [
                  Expanded(
                    child: Wrap(
                      spacing: 4,
                      runSpacing: 4,
                      children: [
                        for (final leg in transitLegs)
                          _productChip(context, leg),
                      ],
                    ),
                  ),
                  if (journey.price != null)
                    Text(
                      journey.price!.formatted,
                      style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: theme.colorScheme.primary),
                    ),
                ],
              ),
            ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _timeWithDelay(
      BuildContext context, DateTime? planned, int? delaySec) {
    if (planned == null) return const SizedBox.shrink();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          planned.hhmm,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        const SizedBox(width: 4),
        DelayBadge(delaySeconds: delaySec),
      ],
    );
  }

  Widget _transferIndicator(
      BuildContext context, int transfers, List<JourneyLeg> legs) {
    final theme = Theme.of(context);
    if (transfers == 0) {
      return Text('Direkt',
          style: TextStyle(
              fontSize: 11, color: theme.colorScheme.onSurfaceVariant));
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (int i = 0; i < legs.length; i++) ...[
          Container(
            width: 20,
            height: 3,
            decoration: BoxDecoration(
              color: theme.colorScheme.primary,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          if (i < legs.length - 1)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Container(
                width: 4,
                height: 4,
                decoration: BoxDecoration(
                  color: theme.colorScheme.onSurfaceVariant,
                  shape: BoxShape.circle,
                ),
              ),
            ),
        ],
      ],
    );
  }

  Widget _productChip(BuildContext context, JourneyLeg leg) {
    final name = leg.line?.displayName ?? '';
    if (name.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(name, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
          if (leg.occupancy != null) ...[
            const SizedBox(width: 4),
            OccupancyIndicator(level: leg.occupancy!.level),
          ],
        ],
      ),
    );
  }
}
