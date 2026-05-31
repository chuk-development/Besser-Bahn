import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../models/db_ticket.dart';
import '../../providers/account_provider.dart';

/// A single booked ticket: the scannable barcode plus the ticket facts (route,
/// validity, class, traveller). The barcode is the same Aztec code DB renders
/// in its own app, extracted from the embedded ticket.
class TicketDetailScreen extends ConsumerWidget {
  final String auftragsnummer;
  final String kundenwunschId;

  const TicketDetailScreen({
    super.key,
    required this.auftragsnummer,
    required this.kundenwunschId,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final key = '$auftragsnummer/$kundenwunschId';
    final ticket = ref.watch(ticketProvider(key));

    return Scaffold(
      appBar: AppBar(title: const Text('Ticket')),
      body: ticket.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.error_outline,
                    size: 48, color: Theme.of(context).colorScheme.error),
                const SizedBox(height: 12),
                Text('Ticket konnte nicht geladen werden.\n$e',
                    textAlign: TextAlign.center),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: () => ref.invalidate(ticketProvider(key)),
                  child: const Text('Erneut versuchen'),
                ),
              ],
            ),
          ),
        ),
        data: (t) => _body(context, t),
      ),
    );
  }

  Widget _body(BuildContext context, DbTicket t) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: [
        // Barcode card
        Card(
          margin: EdgeInsets.zero,
          color: Colors.white,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                if (t.barcode != null)
                  Image.memory(
                    t.barcode!,
                    width: 220,
                    height: 220,
                    fit: BoxFit.contain,
                    gaplessPlayback: true,
                  )
                else
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 32),
                    child: Text('Kein Barcode in diesem Ticket.',
                        style: TextStyle(color: Colors.black54)),
                  ),
                const SizedBox(height: 8),
                Text(
                  'Auftrag ${t.auftragsnummer}',
                  style: const TextStyle(
                      color: Colors.black87,
                      fontFeatures: [FontFeature.tabularFigures()]),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        // Route
        if (t.vonName != null || t.nachName != null)
          _routeCard(context, t),
        const SizedBox(height: 12),
        // Facts
        Card(
          margin: EdgeInsets.zero,
          child: Column(
            children: [
              if (t.angebotsname != null)
                _row(theme, Icons.local_offer_outlined, 'Tarif',
                    t.angebotsname!),
              _row(theme, Icons.event_seat_outlined, 'Klasse',
                  t.firstClass ? '1. Klasse' : '2. Klasse'),
              _row(theme, Icons.group_outlined, 'Reisende', t.reisendeText),
              if (t.gueltigAb != null)
                _row(theme, Icons.schedule, 'Gültig ab',
                    _dt(t.gueltigAb!)),
              if (t.gueltigBis != null)
                _row(theme, Icons.event_busy_outlined, 'Gültig bis',
                    _dt(t.gueltigBis!)),
              if (t.cityInfotext != null)
                _row(theme, Icons.location_city_outlined, 'City-Ticket',
                    t.cityInfotext!),
              if (t.buchungsdatum != null)
                _row(theme, Icons.receipt_long_outlined, 'Gebucht am',
                    _dt(t.buchungsdatum!)),
              _row(theme, Icons.verified_outlined, 'Status',
                  _statusText(t.status)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _routeCard(BuildContext context, DbTicket t) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(t.vonName ?? '—', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text(t.nachName ?? '—', style: theme.textTheme.titleMedium),
                ],
              ),
            ),
            Icon(
              t.isReturn ? Icons.swap_vert : Icons.arrow_downward,
              color: theme.colorScheme.primary,
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(ThemeData theme, IconData icon, String label, String value) =>
      ListTile(
        leading: Icon(icon, color: theme.colorScheme.primary),
        title: Text(label, style: theme.textTheme.bodySmall),
        subtitle: Text(value, style: theme.textTheme.bodyLarge),
      );

  String _statusText(String s) => switch (s.toUpperCase()) {
        'GUELTIG' => 'Gültig',
        'STORNIERT' => 'Storniert',
        'ABGELAUFEN' => 'Abgelaufen',
        _ => s,
      };

  String _dt(DateTime d) => DateFormat('dd.MM.yyyy, HH:mm').format(d);
}
