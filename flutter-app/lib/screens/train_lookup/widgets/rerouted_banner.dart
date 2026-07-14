import 'package:flutter/material.dart';

import '../../../models/trip.dart';

/// "Umleitung / geänderter Zuglauf" — shown above a train block whose run
/// deviates from the timetable.
///
/// A diversion is not a delay: the *route* changed, so "which stops does this
/// train still make" matters more than "how late is it". Writing the delay onto
/// an unchanged stop list, as the app used to, actively misleads — it reads as
/// "same route, just late" (#17).
///
/// Amber, not red: the train still runs and the rider isn't stranded, unlike
/// the red full-cancellation banner.
class ReroutedBanner extends StatelessWidget {
  final Trip trip;
  const ReroutedBanner({super.key, required this.trip});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final added = trip.additionalStops;
    final dropped = trip.cancelledStops;

    // Prefer DB's own words over our guess — it names the actual cause
    // ("Streckensperrung", "Bauarbeiten"). Fall back to a generic line.
    final cause = trip.disruptions.firstWhere(
      (d) {
        final t = d.toLowerCase();
        return t.contains('umleitung') ||
            t.contains('umgeleitet') ||
            t.contains('laufweg');
      },
      orElse: () => '',
    );

    final details = <String>[
      if (added.isNotEmpty)
        'Zusätzliche Halte: ${added.map((s) => s.stop.name).join(', ')}',
      if (dropped.isNotEmpty)
        'Halt entfällt: ${dropped.map((s) => s.stop.name).join(', ')}',
    ];

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.amber.shade700.withValues(alpha: 0.15),
        border: Border.all(color: Colors.amber.shade700),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.alt_route, size: 20, color: Colors.amber.shade800),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Umleitung / geänderter Zuglauf',
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 3),
                Text(
                  cause.isNotEmpty
                      ? cause
                      : 'Dieser Zug weicht vom planmäßigen Laufweg ab. '
                          'Halte und Zeiten können abweichen.',
                  style: theme.textTheme.bodySmall,
                ),
                for (final d in details) ...[
                  const SizedBox(height: 3),
                  Text(d,
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant)),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
