import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';

import '../../../models/journey.dart';
import '../../../providers/journey_search_provider.dart';
import '../../../utils/journey_highlights.dart';
import '../../../core/extensions.dart';
import '../../../core/share_text.dart';
import '../../../providers/service_providers.dart';
import '../../../theme/app_colors.dart';
import '../../../widgets/delay_badge.dart';
import '../../../widgets/occupancy_indicator.dart';
import '../../../widgets/prediction_badge.dart';

class JourneyCard extends ConsumerWidget {
  final Journey journey;

  /// Optional tap override — used to open the ticket detail when the card
  /// stands in for a booked ticket in the Reisen tab. Defaults to pushing the
  /// full connection-detail screen.
  final VoidCallback? onTap;

  const JourneyCard({
    super.key,
    required this.journey,
    this.onTap,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final transitLegs = journey.legs.where((l) => !l.isWalking).toList();
    // "Schnellste / Günstigste / Sicherste / Bester Kompromiss" (#11.9). Only
    // in a result list: the same card stands in for a booked ticket in the
    // Reisen tab, where there's nothing to compare against.
    final highlights = onTap == null
        ? ref
            .watch(journeyHighlightsProvider)
            .entries
            .where((e) => identical(e.value, journey))
            .map((e) => e.key)
            .toList()
        : const <JourneyHighlight>[];

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap ??
            () {
              // Show the FULL connection (all legs + transfers), not just leg 1.
              context.push('/connection', extra: journey);
            },
        // Long-press shares the official bahn.de "Reise teilen" link to this
        // exact connection — no need to open the detail screen first.
        onLongPress: () => _share(context, ref),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // Prediction strip (Anschluss / Pünktlichkeit) on the left.
              PredictionBadge(journey: journey),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
            children: [
              if (highlights.isNotEmpty) ...[
                Wrap(
                  spacing: 4,
                  runSpacing: 4,
                  children: [
                    for (final h in highlights) _HighlightChip(highlight: h),
                  ],
                ),
                const SizedBox(height: 6),
              ],
              // Cancellation banner — full width, red, above everything else so
              // a dead connection can't be mistaken for a normal one.
              if (journey.hasCancelledLeg || journey.hasPartialCancellation) ...[
                _CancelBanner(
                  partial: !journey.hasCancelledLeg,
                ),
                const SizedBox(height: 6),
              ],
              // Route row: origin (left) and destination (right). No arrow —
              // a search always runs left→right, so it adds nothing.
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
                  const SizedBox(width: 8),
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
              const SizedBox(height: 4),

              // Time row
              Row(
                children: [
                  // Departure
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _timeWithDelay(context, journey.plannedDeparture,
                          journey.legs.firstOrNull?.departureDelay),
                    ],
                  ),

                  // Duration — bigger; the transfer count is obvious from the
                  // train pills below, so no "N Umstiege" text here.
                  Expanded(
                    child: Center(
                      child: Text(
                        journey.durationString,
                        style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold, fontSize: 18),
                      ),
                    ),
                  ),

                  // Arrival
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      _timeWithDelay(context, journey.plannedArrival,
                          journey.legs.lastOrNull?.arrivalDelay),
                    ],
                  ),
                ],
              ),

              const SizedBox(height: 6),

              // Per-train length comparison (one row each) on the left; price
              // pinned top-right with the rows free to extend below it.
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: _LegLengthBar(legs: transitLegs)),
                  if (journey.price != null) ...[
                    const SizedBox(width: 8),
                    Text(
                      journey.price!.formatted,
                      style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: theme.colorScheme.primary),
                    ),
                  ],
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

  Future<void> _share(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    String? link;
    try {
      link = await ref.read(vendoServiceProvider).shareJourney(journey);
    } catch (_) {/* no shareable link */}
    if (link == null) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Reise lässt sich nicht teilen.')),
      );
      return;
    }
    final o = journey.origin?.name ?? '';
    final d = journey.destination?.name ?? '';
    await SharePlus.instance.share(
      ShareParams(
        text: journeyShareText(journey, link),
        subject: o.isNotEmpty && d.isNotEmpty ? '$o → $d' : 'Bahn-Reise',
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

}

/// Full-width red (cancelled) / amber (partial) strip warning that this
/// connection can't be travelled as shown.
/// "⚡ Schnellste" / "🛡️ Sicherste" … — why this connection stands out from
/// the rest of the list (#11, point 9).
class _HighlightChip extends StatelessWidget {
  final JourneyHighlight highlight;
  const _HighlightChip({required this.highlight});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        '${highlight.emoji} ${highlight.label}',
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: scheme.onPrimaryContainer,
        ),
      ),
    );
  }
}

class _CancelBanner extends StatelessWidget {
  final bool partial;
  const _CancelBanner({required this.partial});

  @override
  Widget build(BuildContext context) {
    final color = partial ? AppColors.warning : AppColors.dbRed;
    final label = partial ? 'Teilausfall — Halt entfällt' : 'Fällt aus';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(partial ? Icons.warning_amber_rounded : Icons.cancel,
              size: 15, color: color),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  color: color, fontSize: 12, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }
}

/// Proportional length comparison: each train is a coloured segment whose
/// WIDTH ∝ time spent on it (RE7 longer than IC, etc.). The line name sits
/// inside the segment; the occupancy "Männchen" sits underneath it.
///
/// Each segment ALSO fills left→right with a darker shade of its own colour
/// showing how far THAT leg has progressed (elapsed time on that train): the
/// first leg fills up completely, then the next leg starts filling — so the
/// coloured bars themselves are the live progress, no separate bar needed.
///
/// Self-ticks (20 s) only while the journey is under way, so a long saved-trips
/// list stays idle otherwise.
class _LegLengthBar extends StatefulWidget {
  final List<JourneyLeg> legs;
  const _LegLengthBar({required this.legs});

  @override
  State<_LegLengthBar> createState() => _LegLengthBarState();
}

class _LegLengthBarState extends State<_LegLengthBar> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _syncTimer();
  }

  @override
  void didUpdateWidget(covariant _LegLengthBar old) {
    super.didUpdateWidget(old);
    _syncTimer();
  }

  /// Tick only while at least one leg is mid-ride (0 < progress < 1).
  void _syncTimer() {
    _timer?.cancel();
    final live = widget.legs.any((l) {
      final f = _legProgress(l);
      return f > 0 && f < 1;
    });
    if (live) {
      _timer = Timer.periodic(const Duration(seconds: 20), (_) {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  static int _legMinutes(JourneyLeg l) {
    final d = l.departure ?? l.plannedDeparture;
    final a = l.arrival ?? l.plannedArrival;
    if (d != null && a != null) {
      final m = a.difference(d).inMinutes;
      if (m > 0) return m;
    }
    return 1;
  }

  /// How far this leg has been travelled, as a fraction [0,1] of its ride time.
  static double _legProgress(JourneyLeg l) {
    final d = l.departure ?? l.plannedDeparture;
    final a = l.arrival ?? l.plannedArrival;
    if (d == null || a == null) return 0;
    final total = a.difference(d).inSeconds;
    if (total <= 0) return DateTime.now().isBefore(a) ? 0 : 1;
    return (DateTime.now().difference(d).inSeconds / total).clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    final legs = widget.legs;
    if (legs.isEmpty) return const SizedBox.shrink();
    final mins = legs.map(_legMinutes).toList();
    final total = mins.fold<int>(0, (s, m) => s + m);
    if (total <= 0) return const SizedBox.shrink();
    // Floor so even a short leg keeps enough width for its line label.
    final minFlex = (total * 0.16).round().clamp(1, total);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < legs.length; i++) ...[
          if (i > 0) const SizedBox(width: 4),
          Expanded(
            flex: mins[i] < minFlex ? minFlex : mins[i],
            child: _legSegment(
              context,
              legs[i].line?.displayName ?? '–',
              _productColor(context, legs[i]),
              legs[i].occupancy?.level,
              _legProgress(legs[i]),
            ),
          ),
        ],
      ],
    );
  }

  Widget _legSegment(BuildContext context, String label, Color color,
      OccupancyLevel? occupancy, double progress) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Proportional segment: light tinted base + coloured border, and a
        // DARKER fill that grows from the left with this leg's progress, so the
        // bar itself shows how much of this train you've already ridden.
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: Container(
            height: 26,
            decoration: BoxDecoration(
              color: color.withAlpha(28),
              border: Border.all(color: color.withAlpha(150)),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Stack(
              fit: StackFit.expand,
              children: [
                // The darker progress fill, anchored left, fractional width.
                if (progress > 0)
                  FractionallySizedBox(
                    alignment: Alignment.centerLeft,
                    widthFactor: progress,
                    child: Container(color: color.withAlpha(50)),
                  ),
                // Line name on top of the fill.
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Center(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        label,
                        maxLines: 1,
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: color),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        // Occupancy "Männchen" under the name.
        if (occupancy != null && occupancy != OccupancyLevel.unknown)
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Center(child: OccupancyIndicator(level: occupancy)),
          ),
      ],
    );
  }

  /// Colour per train product, so segments are visually distinct.
  Color _productColor(BuildContext context, JourneyLeg leg) {
    final p =
        (leg.line?.productName ?? leg.line?.displayName ?? '').toUpperCase();
    if (p.startsWith('ICE')) return Colors.red.shade700;
    if (p.startsWith('IC') || p.startsWith('EC')) return Colors.blue.shade700;
    if (p.startsWith('RE') || p.startsWith('RB')) return Colors.teal.shade700;
    if (p.startsWith('S')) return Colors.green.shade700;
    return Theme.of(context).colorScheme.primary;
  }
}
