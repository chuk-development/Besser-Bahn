import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../models/journey.dart';
import '../../providers/bulk_split_provider.dart';
import '../../providers/split_ticket_provider.dart';
import '../../theme/app_colors.dart';

/// Bulk price comparison: take the connections from one search and show, for
/// each departure, the direct fare vs the cheapest split — so the rider can
/// pick the cheapest time at a glance. Each row fills in as its analysis lands.
class BulkSplitScreen extends ConsumerStatefulWidget {
  /// Connections to compare — the results currently shown for the search.
  final List<Journey> journeys;

  const BulkSplitScreen({super.key, required this.journeys});

  @override
  ConsumerState<BulkSplitScreen> createState() => _BulkSplitScreenState();
}

class _BulkSplitScreenState extends ConsumerState<BulkSplitScreen> {
  @override
  void initState() {
    super.initState();
    // Kick the comparison off once the first frame is up (can't mutate a
    // provider during build). Cap the set so the pairwise scans stay bounded.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final js = widget.journeys.take(8).toList();
      ref.read(bulkSplitProvider.notifier).compare(js);
    });
  }

  String _dur(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes % 60;
    return h > 0 ? '$h:${m.toString().padLeft(2, '0')} h' : '$m min';
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(bulkSplitProvider);
    final theme = Theme.of(context);

    // Cheapest fully-analysed departure, for the headline.
    BulkSplitRow? cheapest;
    for (final r in state.rows) {
      if (r.status != BulkRowStatus.done || r.bestPrice == null) continue;
      if (cheapest == null || r.bestPrice! < cheapest.bestPrice!) cheapest = r;
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Preisvergleich'),
        actions: [
          if (state.running)
            IconButton(
              tooltip: 'Abbrechen',
              icon: const Icon(Icons.stop_circle_outlined),
              onPressed: () => ref.read(bulkSplitProvider.notifier).cancel(),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          if (state.total > 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    state.running
                        ? 'Prüfe Split-Tickets … ${state.doneCount}/${state.total}'
                        : 'Fertig — ${state.total} Verbindungen verglichen',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 6),
                  LinearProgressIndicator(
                    value: state.total == 0
                        ? null
                        : state.doneCount / state.total,
                  ),
                ],
              ),
            ),

          // Headline: cheapest departure overall.
          if (cheapest != null)
            Card(
              margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              color: theme.colorScheme.primaryContainer,
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Row(
                  children: [
                    Icon(
                      Icons.savings,
                      color: theme.colorScheme.onPrimaryContainer,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Günstigste Abfahrt',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onPrimaryContainer
                                  .withAlpha(190),
                            ),
                          ),
                          Text(
                            '${cheapest.label}  ·  '
                            '${cheapest.bestPrice!.toStringAsFixed(2)} €'
                            '${cheapest.splitWins ? ' (Split)' : ''}',
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: theme.colorScheme.onPrimaryContainer,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),

          for (final row in state.rows) _buildRow(context, row),

          Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
            child: Text(
              'Split-Tickets haben kein Anschluss-Recht — bei Verspätung liegt '
              'das Risiko beim Fahrgast.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRow(BuildContext context, BulkSplitRow row) {
    final theme = Theme.of(context);
    final splitWins = row.splitWins;

    Widget priceBlock() {
      if (row.status == BulkRowStatus.running ||
          row.status == BulkRowStatus.pending) {
        // Direct fare is known instantly from the search; split still computing.
        return Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (row.directPrice != null)
              Text(
                '${row.directPrice!.toStringAsFixed(2)} €',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            const SizedBox(height: 4),
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ],
        );
      }
      if (row.status == BulkRowStatus.failed) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (row.directPrice != null)
              Text(
                '${row.directPrice!.toStringAsFixed(2)} €',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            Text(
              'Split n/v',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ],
        );
      }
      // done
      return Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (row.directPrice != null)
            Text(
              '${row.directPrice!.toStringAsFixed(2)} €',
              style: TextStyle(
                fontWeight: splitWins ? FontWeight.normal : FontWeight.bold,
                decoration: splitWins ? TextDecoration.lineThrough : null,
                color: splitWins ? theme.colorScheme.onSurfaceVariant : null,
              ),
            ),
          if (splitWins)
            Text(
              '${row.splitPrice!.toStringAsFixed(2)} €',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: AppColors.onTime,
              ),
            ),
        ],
      );
    }

    String verdict() {
      if (row.status != BulkRowStatus.done) return '';
      if (splitWins) {
        final save = (row.directPrice! - row.splitPrice!).toStringAsFixed(2);
        return 'Split −$save €';
      }
      return 'Direkt am günstigsten';
    }

    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _openDetail(context, row),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          row.label,
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${_dur(row.duration)} · '
                          '${row.transfers == 0 ? 'direkt' : '${row.transfers}× umst.'} · '
                          '${row.trains}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  priceBlock(),
                  if (row.status == BulkRowStatus.done)
                    Icon(
                      Icons.chevron_right,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                ],
              ),
              if (verdict().isNotEmpty) ...[
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: splitWins
                          ? AppColors.onTime.withAlpha(28)
                          : theme.colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      verdict(),
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: splitWins
                            ? AppColors.onTime
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// Tapping a row shows the SAME split detail a single analysis produces —
  /// which tickets, where they break, what the D-Ticket covers. The result is
  /// already computed, so this only hands it to the detail screen; nothing is
  /// re-priced (#24).
  void _openDetail(BuildContext context, BulkSplitRow row) {
    final messenger = ScaffoldMessenger.of(context);
    if (row.status == BulkRowStatus.pending ||
        row.status == BulkRowStatus.running) {
      messenger.showSnackBar(
        const SnackBar(
          duration: Duration(seconds: 2),
          content: Text('Diese Verbindung wird noch geprüft.'),
        ),
      );
      return;
    }
    final res = row.result;
    if (res == null) {
      // failed, or done without a result — nothing to show but the trains.
      context.push('/connection', extra: row.journey);
      return;
    }
    ref
        .read(splitTicketProvider.notifier)
        .showResult(
          res,
          routeLabel:
              '${row.journey.origin?.name ?? ''} → '
              '${row.journey.destination?.name ?? ''}',
        );
    context.push('/split-ticket', extra: row.journey);
  }
}
