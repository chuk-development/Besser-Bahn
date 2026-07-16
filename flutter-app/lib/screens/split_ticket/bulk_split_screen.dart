import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../models/journey.dart';
import '../../providers/bulk_split_provider.dart';
import '../../providers/split_ticket_provider.dart';
import '../../theme/app_colors.dart';
import '../../utils/dticket_optimizer.dart';

/// Bulk price comparison: take the connections from one search and show, for
/// each departure, the direct fare vs the cheapest split — so the rider can
/// pick the cheapest time at a glance. Each row fills in as its analysis lands.
///
/// With a Deutschlandticket the interesting question isn't the total but what
/// comes ON TOP of the ticket already paid for, so the same finished analyses
/// can be re-read and re-ordered by surcharge (#28). Same numbers, same engine,
/// different question — no second run, no second pricing path.
class BulkSplitScreen extends ConsumerStatefulWidget {
  /// Connections to compare — the results currently shown for the search.
  final List<Journey> journeys;

  /// Open straight in D-Ticket mode (ordered by surcharge). Only honoured when
  /// the run actually priced with a D-Ticket — otherwise there is no surcharge
  /// to show and the mode silently stays off.
  final bool dTicketMode;

  const BulkSplitScreen({
    super.key,
    required this.journeys,
    this.dTicketMode = false,
  });

  @override
  ConsumerState<BulkSplitScreen> createState() => _BulkSplitScreenState();
}

class _BulkSplitScreenState extends ConsumerState<BulkSplitScreen> {
  late bool _dTicket = widget.dTicketMode;

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

  /// What [row] costs on top of the D-Ticket, or null while it's unproven.
  /// Reads the flag off the run, not off the live setting — see
  /// [BulkSplitState.deutschlandTicket].
  DTicketQuote? _quoteOf(BulkSplitRow row, BulkSplitState state) =>
      row.status == BulkRowStatus.done
          ? dTicketQuoteFrom(row.result,
              deutschlandTicket: state.deutschlandTicket)
          : null;

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(bulkSplitProvider);
    final theme = Theme.of(context);

    // The mode only exists for someone who holds the ticket — without one there
    // is no "on top of" to compute (#28).
    final offerDTicket = state.deutschlandTicket;
    final dMode = _dTicket && offerDTicket;

    final rows = dMode
        ? sortByDTicketSurcharge(
            state.rows,
            quoteOf: (r) => _quoteOf(r, state),
            durationOf: (r) => r.duration,
          )
        : state.rows;

    // The headline pick: lowest surcharge in D-Ticket mode, cheapest total
    // otherwise. Only fully-analysed rows can win it.
    BulkSplitRow? best;
    DTicketQuote? bestQuote;
    for (final r in rows) {
      if (r.status != BulkRowStatus.done) continue;
      if (dMode) {
        final q = _quoteOf(r, state);
        if (q == null) continue;
        if (bestQuote == null || q.surcharge < bestQuote.surcharge) {
          best = r;
          bestQuote = q;
        }
      } else {
        if (r.bestPrice == null) continue;
        if (best == null || r.bestPrice! < best.bestPrice!) best = r;
      }
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(dMode ? 'D-Ticket-Optimierer' : 'Preisvergleich'),
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
          if (offerDTicket)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(
                    value: false,
                    label: Text('Gesamtpreis'),
                    icon: Icon(Icons.euro, size: 16),
                  ),
                  ButtonSegment(
                    value: true,
                    label: Text('Zuzahlung'),
                    icon: Icon(Icons.confirmation_number_outlined, size: 16),
                  ),
                ],
                selected: {dMode},
                showSelectedIcon: false,
                onSelectionChanged: (s) =>
                    setState(() => _dTicket = s.first),
              ),
            ),

          if (state.total > 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    state.running
                        ? '${dMode ? 'Prüfe Zuzahlung' : 'Prüfe Split-Tickets'} '
                              '… ${state.doneCount}/${state.total}'
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

          // Headline: the pick under the current question.
          if (best != null)
            Card(
              margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              color: theme.colorScheme.primaryContainer,
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Row(
                  children: [
                    Icon(
                      dMode ? Icons.confirmation_number : Icons.savings,
                      color: theme.colorScheme.onPrimaryContainer,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            dMode
                                ? 'Geringste Zuzahlung'
                                : 'Günstigste Abfahrt',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onPrimaryContainer
                                  .withAlpha(190),
                            ),
                          ),
                          Text(
                            dMode
                                ? '${best.label}  ·  '
                                      '${bestQuote!.fullyCovered ? 'D-Ticket reicht' : '+${bestQuote.surchargeFormatted}'}'
                                : '${best.label}  ·  '
                                      '${best.bestPrice!.toStringAsFixed(2)} €'
                                      '${best.splitWins ? ' (Split)' : ''}',
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

          for (final row in rows) _buildRow(context, row, state, dMode),

          Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
            child: Text(
              dMode
                  ? 'Zuzahlung = was zusätzlich zum Deutschlandticket zu '
                        'kaufen ist. Split-Tickets haben kein Anschluss-Recht — '
                        'bei Verspätung liegt das Risiko beim Fahrgast.'
                  : 'Split-Tickets haben kein Anschluss-Recht — bei Verspätung '
                        'liegt das Risiko beim Fahrgast.',
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

  Widget _buildRow(
    BuildContext context,
    BulkSplitRow row,
    BulkSplitState state,
    bool dMode,
  ) {
    final theme = Theme.of(context);
    final splitWins = row.splitWins;
    final quote = dMode ? _quoteOf(row, state) : null;

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
              dMode ? 'Zuzahlung n/v' : 'Split n/v',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ],
        );
      }
      if (dMode) {
        // Done, but the surcharge couldn't be established — say so instead of
        // printing a 0 that would sort straight to the top.
        if (quote == null) {
          return Text(
            'Zuzahlung unklar',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (quote.savesMoney && row.directPrice != null)
              Text(
                '${row.directPrice!.toStringAsFixed(2)} €',
                style: TextStyle(
                  decoration: TextDecoration.lineThrough,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            Text(
              quote.fullyCovered ? '0.00 €' : '+${quote.surchargeFormatted}',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 16,
                color: quote.fullyCovered ? AppColors.onTime : null,
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

    // (text, "this is a win") — a win gets the green treatment.
    (String, bool) verdict() {
      if (row.status != BulkRowStatus.done) return ('', false);
      if (dMode) {
        if (quote == null) return ('', false);
        if (quote.fullyCovered) return ('D-Ticket reicht', true);
        if (quote.savesMoney) {
          return ('D-Ticket spart −${quote.saving!.toStringAsFixed(2)} €', true);
        }
        // Pure long-distance: the ticket is worth nothing here. Better said out
        // loud than dressed up as a saving.
        return ('D-Ticket bringt hier nichts', false);
      }
      if (splitWins) {
        final save = (row.directPrice! - row.splitPrice!).toStringAsFixed(2);
        return ('Split −$save €', true);
      }
      return ('Direkt am günstigsten', false);
    }

    final (verdictText, verdictWin) = verdict();

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
              if (verdictText.isNotEmpty) ...[
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: verdictWin
                          ? AppColors.onTime.withAlpha(28)
                          : theme.colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      verdictText,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: verdictWin
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
