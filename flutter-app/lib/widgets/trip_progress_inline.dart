import 'dart:async';

import 'package:flutter/material.dart';

import '../core/trip_progress.dart';
import '../models/journey.dart';

/// Compact on-board progress strip meant to live INSIDE another card (e.g. the
/// connection-detail summary), not as a standalone block. Shows a thin progress
/// bar, the remaining time to the destination and the % done while the trip is
/// in progress; collapses to nothing otherwise. Self-ticks every 15 s.
class TripProgressInline extends StatefulWidget {
  final Journey journey;
  const TripProgressInline({super.key, required this.journey});

  @override
  State<TripProgressInline> createState() => _TripProgressInlineState();
}

class _TripProgressInlineState extends State<TripProgressInline> {
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = TripProgress.of(widget.journey);
    // Only while actually on board — pre-departure is covered by DepartureCard.
    if (p == null || p.phase != TripPhase.onBoard) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 10),
        const Divider(height: 1),
        const SizedBox(height: 10),
        Row(
          children: [
            Icon(Icons.train, size: 15, color: theme.colorScheme.primary),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                p.minutesToArrival <= 0
                    ? 'Ankunft jetzt'
                    : 'Noch ${_dur(p.minutesToArrival)} bis ${p.destinationName}',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
            Text('${(p.fraction * 100).round()} %',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                )),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: p.fraction,
            minHeight: 5,
            backgroundColor: theme.colorScheme.surfaceContainerHighest,
            color: theme.colorScheme.primary,
          ),
        ),
        if (p.nextTransferStation != null) ...[
          const SizedBox(height: 6),
          Text(
            'Umstieg in ${p.nextTransferStation}'
            '${p.minutesToTransfer != null ? ' · in ${_dur(p.minutesToTransfer!)}' : ''}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
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
