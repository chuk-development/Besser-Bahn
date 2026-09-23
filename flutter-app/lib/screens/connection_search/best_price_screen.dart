import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../models/best_price.dart';
import '../../models/station.dart';
import '../../providers/best_price_provider.dart';
import 'widgets/journey_card.dart';
import '../../widgets/app_nav_bar.dart';

/// Route arguments for `/best-price` — GoRouter's `extra`, so the stations
/// travel as objects instead of being re-resolved from a query string.
class BestPriceArgs {
  final Station from;
  final Station to;
  final DateTime date;
  const BestPriceArgs({
    required this.from,
    required this.to,
    required this.date,
  });
}

/// "Bestpreis" — what the trip costs across the whole day, and when it's
/// cheapest (#21).
///
/// One request per day gives every slot with its cheapest offer AND the
/// connections behind it, so tapping a slot needs no second call. Days are
/// paged with ‹ ›; each day is cached, because the backend starts refusing a
/// client that asks too often.
class BestPriceScreen extends ConsumerStatefulWidget {
  final Station from;
  final Station to;
  final DateTime date;

  const BestPriceScreen({
    super.key,
    required this.from,
    required this.to,
    required this.date,
  });

  @override
  ConsumerState<BestPriceScreen> createState() => _BestPriceScreenState();
}

class _BestPriceScreenState extends ConsumerState<BestPriceScreen> {
  late DateTime _day = DateTime(
    widget.date.year,
    widget.date.month,
    widget.date.day,
  );

  /// Which slot is open. Only one at a time — the whole point is comparing
  /// slots, and five expanded lists would bury the prices.
  int? _expanded;

  /// DB sells about six months out; searching past that returns nothing and
  /// looks broken, so the arrows stop there.
  static const _horizon = Duration(days: 180);

  bool get _canGoBack => _day.isAfter(_today);
  bool get _canGoForward => _day.isBefore(_today.add(_horizon));

  DateTime get _today {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }

  void _shift(int days) {
    setState(() {
      _day = _day.add(Duration(days: days));
      _expanded = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final req = BestPriceRequest(from: widget.from, to: widget.to, date: _day);
    final async = ref.watch(bestPriceProvider(req));
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Bestpreis'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(48),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.chevron_left),
                  tooltip: 'Tag zurück',
                  onPressed: _canGoBack ? () => _shift(-1) : null,
                ),
                Expanded(
                  child: Column(
                    children: [
                      Text(
                        DateFormat('EEEE, d. MMMM', 'de').format(_day),
                        style: theme.textTheme.titleSmall,
                      ),
                      Text(
                        '${widget.from.name} → ${widget.to.name}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.chevron_right),
                  tooltip: 'Tag vor',
                  onPressed: _canGoForward ? () => _shift(1) : null,
                ),
              ],
            ),
          ),
        ),
      ),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.error_outline,
                  size: 40,
                  color: theme.colorScheme.error,
                ),
                const SizedBox(height: 12),
                Text(
                  '$e',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: theme.colorScheme.error),
                ),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: () => ref.invalidate(bestPriceProvider(req)),
                  child: const Text('Nochmal'),
                ),
              ],
            ),
          ),
        ),
        data: (day) => _body(context, day),
      ),
    );
  }

  Widget _body(BuildContext context, BestPriceDay day) {
    if (day.intervals.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text(
            'Für diesen Tag gibt es keine Preise.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return ListView(
      padding: EdgeInsets.only(bottom: 32 + AppNavBar.insetOf(context)),
      children: [
        if (!day.hasPrices)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              'Für diesen Tag nennt die Bahn keine Preise — die Verbindungen '
              'stehen aber unten.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        for (var i = 0; i < day.intervals.length; i++)
          _IntervalTile(
            interval: day.intervals[i],
            cheapest: day.cheapest,
            dearest: day.dearest,
            expanded: _expanded == i,
            onTap: () => setState(() => _expanded = _expanded == i ? null : i),
          ),
      ],
    );
  }
}

class _IntervalTile extends StatelessWidget {
  final BestPriceInterval interval;
  final double? cheapest;
  final double? dearest;
  final bool expanded;
  final VoidCallback onTap;

  const _IntervalTile({
    required this.interval,
    required this.cheapest,
    required this.dearest,
    required this.expanded,
    required this.onTap,
  });

  /// How full the bar is: cheapest slot of the day → shortest, dearest →
  /// full. Relative, because "is this a good price" only means anything next
  /// to the other slots of the same day.
  double get _fill {
    final p = interval.price;
    if (p == null || cheapest == null || dearest == null) return 0;
    if (dearest == cheapest) return 1;
    // Floor at a fifth so the cheapest slot still draws a visible bar.
    return 0.2 + 0.8 * ((p - cheapest!) / (dearest! - cheapest!));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final hhmm = DateFormat('HH:mm');
    // 00:00 as an end bound means midnight — "19:00 – 00:00" reads better than
    // the "19:00 – 00:00" of the next day it technically is.
    final label =
        '${hhmm.format(interval.from)} – '
        '${hhmm.format(interval.to)}';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: interval.journeys.isEmpty ? null : onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
            child: Row(
              children: [
                SizedBox(
                  width: 96,
                  child: Text(label, style: theme.textTheme.bodyMedium),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: _fill,
                        minHeight: 8,
                        backgroundColor: scheme.surfaceContainerHighest,
                        valueColor: AlwaysStoppedAnimation(
                          interval.isBest ? scheme.primary : scheme.outline,
                        ),
                      ),
                    ),
                  ),
                ),
                SizedBox(
                  width: 86,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        interval.formattedPrice ?? '—',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: interval.isBest
                              ? FontWeight.w700
                              : FontWeight.w500,
                          color: interval.isBest ? scheme.primary : null,
                        ),
                      ),
                      if (interval.isBest)
                        Text(
                          'Bestpreis',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: scheme.primary,
                          ),
                        )
                      else if (interval.isPartialPrice)
                        // Not comparable with the other slots — say so rather
                        // than let it look like a bargain.
                        Text(
                          'Teilpreis',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        )
                      else
                        Text(
                          '${interval.journeys.length} Verb.',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                ),
                Icon(
                  expanded ? Icons.expand_less : Icons.expand_more,
                  size: 18,
                  color: interval.journeys.isEmpty
                      ? scheme.surfaceContainerHighest
                      : scheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
        if (expanded)
          // The connections came with the price in the same response — no
          // second request, and they carry `kontext`, so the detail screen and
          // everything hanging off it work as if they came from the search.
          for (final j in interval.journeys)
            JourneyCard(journey: j, fromResults: true),
        const Divider(height: 1),
      ],
    );
  }
}
