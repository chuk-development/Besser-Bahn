import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/journey.dart';
import '../providers/prediction_provider.dart';

/// Shows the connection-reliability prediction for a [Journey]:
/// - Anschluss (Verbindungsscore) — P(all transfers caught)
/// - Pünktlichkeit — P(final arrival ≤ 10 min late)
///
/// Renders nothing while loading/failed/unavailable so it never disrupts the
/// layout. [axis] controls vertical (card leading strip) vs horizontal
/// (detail summary) arrangement.
class PredictionBadge extends ConsumerWidget {
  final Journey journey;
  final Axis axis;

  const PredictionBadge({
    super.key,
    required this.journey,
    this.axis = Axis.vertical,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(journeyPredictionProvider(PredictionRequest(journey)));

    return async.when(
      loading: () => _loading(context),
      error: (_, _) => const SizedBox.shrink(),
      data: (p) {
        if (p == null || !p.hasAny) return const SizedBox.shrink();
        final pills = <Widget>[
          if (p.verbindungsscore != null)
            _pill(context, Icons.alt_route, 'Anschluss', p.verbindungsscore!),
          if (p.puenktlichkeit != null)
            _pill(context, Icons.schedule, 'Pünktlich', p.puenktlichkeit!),
        ];
        if (pills.isEmpty) return const SizedBox.shrink();
        return axis == Axis.vertical
            ? Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (var i = 0; i < pills.length; i++) ...[
                    if (i > 0) const SizedBox(height: 6),
                    pills[i],
                  ],
                ],
              )
            : Wrap(spacing: 8, runSpacing: 4, children: pills);
      },
    );
  }

  Widget _loading(BuildContext context) => SizedBox(
        width: axis == Axis.vertical ? 30 : 18,
        height: 18,
        child: Center(
          child: SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
          ),
        ),
      );

  Widget _pill(
      BuildContext context, IconData icon, String label, double score) {
    final color = _scoreColor(context, score);
    final pct = '${score.round()}%';

    if (axis == Axis.vertical) {
      // Compact: icon over percentage, color-coded — fits a narrow leading strip.
      return Tooltip(
        message: '$label: $pct',
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(height: 1),
            Text(pct,
                style: TextStyle(
                    fontSize: 12, fontWeight: FontWeight.bold, color: color)),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Text('$label $pct',
              style: TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w600, color: color)),
        ],
      ),
    );
  }

  /// Green ≥ 80, amber ≥ 50, red below — reliability traffic light.
  Color _scoreColor(BuildContext context, double score) {
    if (score >= 80) return const Color(0xFF2E9E5B);
    if (score >= 50) return const Color(0xFFCC8800);
    return Theme.of(context).colorScheme.error;
  }
}
