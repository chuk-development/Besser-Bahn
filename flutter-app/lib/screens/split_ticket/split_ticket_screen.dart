import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../models/journey.dart';
import '../../models/split_ticket.dart';
import '../../providers/split_ticket_provider.dart';
import '../../providers/settings_provider.dart';
import '../../services/db_api_service.dart';
import '../../widgets/traewelling_avatar_button.dart';
import '../../theme/app_colors.dart';

/// Split-ticket analysis — purely a viewer of [splitTicketProvider]. The
/// analysis is always launched from a connection (the Split button on the
/// connection detail), which already carries the recon context for correct
/// prices; there is no link to paste. The work runs on the app-scoped provider,
/// so it keeps going in the background when this screen is popped, and a system
/// notification fires when it finishes.
class SplitTicketScreen extends ConsumerWidget {
  /// The connection this analysis was launched from, if any. When set, the
  /// result offers a way back to the actual trains of that route.
  final Journey? journey;

  const SplitTicketScreen({super.key, this.journey});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(splitTicketProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Split-Ticketing'),
        actions: const [TraewellingAvatarButton()],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          // Disclaimer
          Card(
            margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            color: theme.colorScheme.errorContainer.withAlpha(40),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.info_outline,
                      size: 20, color: theme.colorScheme.error),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Split-Tickets haben kein Anschluss-Recht. '
                      'Das Risiko bei Verspätungen liegt beim Fahrgast.',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.error),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Cancel control while running.
          if (state.isLoading)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () =>
                      ref.read(splitTicketProvider.notifier).cancel(),
                  icon: const Icon(Icons.cancel),
                  label: const Text('Abbrechen'),
                ),
              ),
            ),

          // Progress
          if (state.isLoading && state.progress != null)
            _buildProgress(context, state.progress!),

          // Analysis error
          if (state.error != null)
            Card(
              margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              color: theme.colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(state.error!,
                    style:
                        TextStyle(color: theme.colorScheme.onErrorContainer)),
              ),
            ),

          // Results
          if (state.result != null) ...[
            _buildAssumptions(context, ref),
            _buildPriceComparison(context, state.result!),
            for (int i = 0; i < state.result!.tickets.length; i++)
              _buildTicketCard(context, ref, state.result!.tickets[i], i + 1),
            if (journey != null) _buildShowRoute(context),
          ],

          // Empty state: nothing running, no result yet.
          if (!state.isLoading && state.result == null && state.error == null)
            _buildEmptyState(context),
        ],
      ),
    );
  }

  /// Shown when no analysis has run yet — points the user at the real entry
  /// point (Verbindung → Split-Ticket), since there is no link to paste.
  Widget _buildEmptyState(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 48, 24, 0),
      child: Column(
        children: [
          Icon(Icons.call_split,
              size: 56, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(height: 16),
          Text('Noch keine Analyse',
              style: theme.textTheme.titleMedium,
              textAlign: TextAlign.center),
          const SizedBox(height: 8),
          Text(
            'Suche eine Verbindung und tippe in der Detailansicht auf '
            '„Split-Ticket suchen“. Die Analyse läuft dann im Hintergrund und '
            'meldet sich, sobald sie fertig ist.',
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 20),
          FilledButton.tonalIcon(
            onPressed: () => context.go('/'),
            icon: const Icon(Icons.search),
            label: const Text('Zur Verbindungssuche'),
          ),
        ],
      ),
    );
  }

  Widget _buildProgress(BuildContext context, SplitTicketProgress progress) {
    final theme = Theme.of(context);
    final pct = (progress.progress * 100).toStringAsFixed(0);
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Prüfe ${progress.processedCombinations} / '
                    '${progress.totalCombinations} Kombinationen ($pct%)',
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            LinearProgressIndicator(value: progress.progress),
            if (progress.currentSegment.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(progress.currentSegment,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ],
          ],
        ),
      ),
    );
  }

  /// Show the search assumptions so the price is unambiguous: which BahnCard
  /// and whether a Deutschland-Ticket was applied (both from Einstellungen).
  Widget _buildAssumptions(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final s = ref.watch(settingsProvider);
    final hasBC = s.bahnCard != BahnCardType.none;
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.tune,
                    size: 16, color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(width: 6),
                Text('Preise gelten für', style: theme.textTheme.titleSmall),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                Chip(
                  avatar: Icon(
                      hasBC ? Icons.credit_card : Icons.credit_card_off,
                      size: 16),
                  label: Text(hasBC ? s.bahnCard.label : 'ohne BahnCard'),
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                ),
                Chip(
                  avatar: Icon(
                      s.hasDeutschlandTicket
                          ? Icons.check_circle
                          : Icons.cancel,
                      size: 16,
                      color: s.hasDeutschlandTicket ? AppColors.onTime : null),
                  label: Text(s.hasDeutschlandTicket
                      ? 'mit Deutschland-Ticket'
                      : 'ohne Deutschland-Ticket'),
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'In den Einstellungen änderbar.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  /// Back to the actual trains: open the connection this split came from, with
  /// every leg/train shown in order so the rider can pick them.
  Widget _buildShowRoute(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: SizedBox(
        width: double.infinity,
        child: OutlinedButton.icon(
          onPressed: () => context.push('/connection', extra: journey),
          icon: const Icon(Icons.alt_route),
          label: const Text('Züge dieser Verbindung anzeigen'),
        ),
      ),
    );
  }

  Widget _buildPriceComparison(
      BuildContext context, TicketAnalysisResult result) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Direktpreis:'),
                Text('${result.directPrice.toStringAsFixed(2)} €',
                    style: const TextStyle(fontSize: 16)),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Split-Preis:',
                    style: TextStyle(fontWeight: FontWeight.w600)),
                Text(
                  '${result.splitPrice.toStringAsFixed(2)} €',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: result.hasSavings ? AppColors.onTime : null,
                  ),
                ),
              ],
            ),
            if (result.hasSavings) ...[
              const Divider(height: 16),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: AppColors.onTime.withAlpha(20),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('Ersparnis',
                        style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: AppColors.onTime)),
                    Text(
                      '${result.savings.toStringAsFixed(2)} € '
                      '(${result.savingsPercent.toStringAsFixed(0)}%)',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: AppColors.onTime,
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 8),
            Text(
              '${result.combinationsChecked} Kombinationen in '
              '${result.elapsed.inSeconds}s geprüft',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTicketCard(
      BuildContext context, WidgetRef ref, SplitTicket ticket, int index) {
    final theme = Theme.of(context);
    final settings = ref.read(settingsProvider);

    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer,
                shape: BoxShape.circle,
              ),
              child: Center(
                child: Text('$index',
                    style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: theme.colorScheme.onPrimaryContainer)),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.train, size: 16),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          '${ticket.from} → ${ticket.to}',
                          style: const TextStyle(fontWeight: FontWeight.w500),
                        ),
                      ),
                    ],
                  ),
                  if (ticket.coveredByDeutschlandTicket)
                    Row(
                      children: [
                        Icon(Icons.check_circle,
                            size: 14, color: AppColors.onTime),
                        const SizedBox(width: 4),
                        Text('Mit Deutschland-Ticket abgedeckt',
                            style: TextStyle(
                                fontSize: 12, color: AppColors.onTime)),
                      ],
                    ),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  ticket.priceFormatted,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: ticket.coveredByDeutschlandTicket
                        ? AppColors.onTime
                        : null,
                  ),
                ),
                if (!ticket.coveredByDeutschlandTicket && ticket.price > 0)
                  TextButton(
                    onPressed: () {
                      final url = DbApiService.generateBookingLink(
                        ticket,
                        bahnCard: settings.bahnCard,
                        deutschlandTicket: settings.hasDeutschlandTicket,
                      );
                      launchUrl(Uri.parse(url),
                          mode: LaunchMode.externalApplication);
                    },
                    style: TextButton.styleFrom(
                        padding: EdgeInsets.zero,
                        minimumSize: const Size(0, 30)),
                    child:
                        const Text('Buchen', style: TextStyle(fontSize: 12)),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

}
