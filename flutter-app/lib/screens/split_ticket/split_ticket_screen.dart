import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../models/journey.dart';
import '../../models/split_ticket.dart';
import '../../providers/service_providers.dart';
import '../../providers/split_ticket_provider.dart';
import '../../providers/settings_provider.dart';
import '../../services/db_api_service.dart';
import '../../utils/split_stops.dart';
import '../../theme/app_colors.dart';

/// Split-ticket analysis viewer + entry point.
///
/// Two ways in:
///  • From a connection (the Split button on the connection detail) — `journey`
///    is set, the analysis is already running on [splitTicketProvider], and we
///    just render its progress/result.
///  • From the global "⋮ → Split-Ticket" menu — `journey` is null and we show a
///    DB-link paste field (like the original app): the user pastes a "Reise
///    teilen" link, we resolve it to a connection and kick off the analysis.
///
/// The work runs on the app-scoped provider, so it keeps going in the
/// background when this screen is popped, and a system notification fires when
/// it finishes.
class SplitTicketScreen extends ConsumerStatefulWidget {
  /// The connection this analysis was launched from, if any. When set, the
  /// result offers a way back to the actual trains of that route.
  final Journey? journey;

  const SplitTicketScreen({super.key, this.journey});

  @override
  ConsumerState<SplitTicketScreen> createState() => _SplitTicketScreenState();
}

class _SplitTicketScreenState extends ConsumerState<SplitTicketScreen> {
  final _linkController = TextEditingController();
  bool _resolving = false;
  String? _resolveError;

  Journey? get journey => widget.journey;

  @override
  void dispose() {
    _linkController.dispose();
    super.dispose();
  }

  /// Resolve the pasted DB link to a concrete connection, then launch the
  /// split analysis on the shared provider. Prices use the user's BahnCard /
  /// Deutschland-Ticket from Einstellungen, so they match the app elsewhere.
  Future<void> _resolveAndAnalyze() async {
    final link = _linkController.text.trim();
    if (link.isEmpty) {
      setState(() => _resolveError = 'Bitte einen DB-Link einfügen.');
      return;
    }
    setState(() {
      _resolving = true;
      _resolveError = null;
    });
    final settings = ref.read(settingsProvider);
    // The DB Navigator backend, not www.bahn.de/web/api — Akamai blocks that
    // one, so every pasted link failed no matter what it contained (#44).
    final vendo = ref.read(vendoServiceProvider);
    try {
      final resolved = await vendo.resolveShareLink(
        link,
        reisende: settings.searchParty.toReisendeJson(),
        deutschlandTicket: settings.hasDeutschlandTicket,
      );
      if (!mounted) return;
      final stops = resolved == null
          ? const <Map<String, dynamic>>[]
          : splitStopsFromJourney(resolved);
      if (resolved == null || stops.length < 2) {
        setState(() {
          _resolving = false;
          _resolveError = resolved == null
              ? 'Konnte keine Verbindung aus dem Link lesen. Prüfe den DB-Link '
                  '(z. B. bahn.de/buchung/start?vbid=…).'
              : 'Diese Verbindung hat zu wenige Halte für ein Split-Ticket.';
        });
        return;
      }
      setState(() => _resolving = false);
      final dep = resolved.plannedDeparture ?? resolved.departure;
      ref.read(splitTicketProvider.notifier).analyze(
            stops: stops,
            date: dep != null ? dep.toIso8601String().split('T').first : '',
            directPrice: resolved.price?.amount ?? 0,
            routeLabel: '${resolved.origin?.name ?? ''} → '
                '${resolved.destination?.name ?? ''}',
            jobKey: 'link:$link',
          );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _resolving = false;
        _resolveError = 'Fehler beim Auflösen: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(splitTicketProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Split-Ticketing'),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          // Global entry (no journey): paste a DB share link to analyse.
          if (journey == null) _buildLinkInput(context),

          // Whole-trip header: which route this analysis is for. Falls back to
          // the journey origin/destination when state hasn't carried a label
          // yet (first frame after navigation).
          if (state.routeLabel != null || journey != null)
            _buildRouteHeader(
              context,
              state.routeLabel ??
                  '${journey?.origin?.name ?? ''} → '
                      '${journey?.destination?.name ?? ''}',
            ),

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

          // Show assumptions (BahnCard / Deutschland-Ticket from settings) up
          // front, so the rider can see WHAT the running search is pricing for
          // — not only after results land.
          if (state.isLoading || state.result != null)
            _buildAssumptions(context, ref),

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
            _buildPriceComparison(context, state.result!),
            for (int i = 0; i < state.result!.tickets.length; i++)
              _buildTicketCard(context, ref, state.result!.tickets[i], i + 1),
            if (journey != null) _buildShowRoute(context),
          ],

          // Empty state: only for the connection flow. The global (link) entry
          // shows the paste field above instead of pointing back to search.
          if (journey != null &&
              !state.isLoading &&
              state.result == null &&
              state.error == null)
            _buildEmptyState(context),
        ],
      ),
    );
  }

  /// DB-link paste field for the global entry: paste a "Reise teilen" link,
  /// resolve it to a connection, and run the split analysis. Mirrors the
  /// original app's link-based split-ticketing.
  Widget _buildLinkInput(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.link, size: 18, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text('DB-Link analysieren', style: theme.textTheme.titleSmall),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Füge einen geteilten DB-Link ein (bahn.de/buchung/start?vbid=…), '
              'um günstigere Split-Tickets für diese Verbindung zu finden.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _linkController,
              maxLines: 2,
              minLines: 1,
              keyboardType: TextInputType.url,
              decoration: InputDecoration(
                isDense: true,
                labelText: 'DB-Link einfügen',
                hintText: 'https://www.bahn.de/buchung/start?vbid=…',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.content_paste),
                  tooltip: 'Aus Zwischenablage einfügen',
                  onPressed: () async {
                    final data = await Clipboard.getData(Clipboard.kTextPlain);
                    final text = data?.text?.trim();
                    if (text != null && text.isNotEmpty) {
                      _linkController.text = text;
                      setState(() => _resolveError = null);
                    }
                  },
                ),
              ),
            ),
            if (_resolveError != null) ...[
              const SizedBox(height: 8),
              Text(_resolveError!,
                  style: TextStyle(color: theme.colorScheme.error)),
            ],
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _resolving ? null : _resolveAndAnalyze,
                icon: _resolving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(Icons.call_split),
                label: Text(_resolving ? 'Lese Link…' : 'Analysieren'),
              ),
            ),
          ],
        ),
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

  /// Bold "Origin → Destination" card at the very top of the screen, so the
  /// rider knows the whole route this analysis covers (e.g. Reisdorf →
  /// Kaltenkirchen) the moment the screen opens — before the first price
  /// request comes back.
  Widget _buildRouteHeader(BuildContext context, String label) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      color: theme.colorScheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Icon(Icons.alt_route,
                size: 20, color: theme.colorScheme.onPrimaryContainer),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Split-Ticket für',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onPrimaryContainer
                          .withAlpha(180),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    label,
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
                  // The fare couldn't be tied to this connection's trains, so
                  // it may be a Sparpreis for a different one. Flagged rather
                  // than dropped: the price is still the best information we
                  // have, it just isn't a promise (#13).
                  if (ticket.priceMayBeTrainBound)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Row(
                        children: [
                          Icon(Icons.info_outline,
                              size: 13,
                              color: Theme.of(context).colorScheme.outline),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              'Preis ggf. zuggebunden — beim Buchen prüfen',
                              style: TextStyle(
                                  fontSize: 11,
                                  color:
                                      Theme.of(context).colorScheme.outline),
                            ),
                          ),
                        ],
                      ),
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
