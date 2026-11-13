import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/berlin_time.dart';
import '../../../models/db_ticket.dart';
import '../../../providers/account_provider.dart';
import '../../../services/db_account_service.dart';

/// Komfort-Check-in on the ticket view: a slim bar between the validity block
/// and the barcode. It shows the state ("Eingecheckt · Wagen 5, Platz 76",
/// "ab 16:13") or a check-in button, and opens one row per train section.
///
/// Works for account tickets and for tickets added by order number + surname
/// (those use the order's anonymous token, see [kciStatusProvider]). Renders
/// nothing for tickets without Komfort-Check-in.
class KomfortCheckinBar extends ConsumerWidget {
  final String ticketKey;
  final DbTicket ticket;
  const KomfortCheckinBar({
    super.key,
    required this.ticketKey,
    required this.ticket,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(kciStatusProvider(ticketKey)).asData?.value;
    if (status == null || status.faehig.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final now = DateTime.now();
    final faehig = status.faehig;
    final checked = faehig.where((a) => a.eingecheckt).toList();
    final open = faehig.where((a) => a.canCheckIn(now)).toList();
    final later = faehig
        .where((a) => !a.eingecheckt && !a.canCheckIn(now))
        .toList();

    final IconData icon;
    final String title;
    final String subtitle;
    final bool highlight;
    if (open.isNotEmpty) {
      icon = Icons.how_to_reg_outlined;
      title = 'Komfort-Check-in';
      subtitle = 'Jetzt einchecken, dann entfällt die Kontrolle';
      highlight = true;
    } else if (checked.isNotEmpty) {
      final a = checked.last;
      icon = Icons.verified_outlined;
      title = a.kontrolliert ? 'Kontrolliert' : 'Eingecheckt';
      subtitle = (a.plaetze.isNotEmpty ? a.plaetze : a.reserviertePlaetze)
          .map((p) => p.label)
          .join(' · ');
      highlight = false;
    } else {
      final next = later.first.moeglichAb;
      icon = Icons.schedule;
      title = 'Komfort-Check-in';
      subtitle = next == null
          ? 'Noch nicht möglich'
          : 'Möglich ab ${DateFormat('HH:mm').format(toBerlin(next))} Uhr';
      highlight = false;
    }

    final bg = highlight
        ? theme.colorScheme.primary
        : theme.colorScheme.surfaceContainerHighest;
    final fg = highlight
        ? theme.colorScheme.onPrimary
        : theme.colorScheme.onSurface;
    return Material(
      color: bg,
      child: InkWell(
        onTap: () => _showSections(context, status),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          child: Row(
            children: [
              Icon(icon, color: fg),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: fg,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (subtitle.isNotEmpty)
                      Text(
                        subtitle,
                        style: theme.textTheme.bodySmall?.copyWith(color: fg),
                      ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: fg),
            ],
          ),
        ),
      ),
    );
  }

  void _showSections(BuildContext context, DbKciStatus status) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _KciSheet(ticketKey: ticketKey, ticket: ticket),
    );
  }
}

/// The section list. Watches the status itself so a check-in updates it.
class _KciSheet extends ConsumerWidget {
  final String ticketKey;
  final DbTicket ticket;
  const _KciSheet({required this.ticketKey, required this.ticket});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final status = ref.watch(kciStatusProvider(ticketKey));
    final now = DateTime.now();
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Komfort-Check-in', style: theme.textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(
              'Wer eingecheckt ist, wird im Zug nicht mehr kontrolliert. '
              'Check-in geht ab der Abfahrt bis kurz vor dem Ausstieg.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            ...switch (status) {
              AsyncData(:final value?) => [
                for (final a in value.faehig)
                  _SectionTile(
                    ticketKey: ticketKey,
                    ticket: ticket,
                    abschnitt: a,
                    now: now,
                  ),
              ],
              AsyncError(:final error) => [
                Text(
                  '$error',
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ],
              _ => [
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Center(child: CircularProgressIndicator()),
                ),
              ],
            },
          ],
        ),
      ),
    );
  }
}

class _SectionTile extends StatelessWidget {
  final String ticketKey;
  final DbTicket ticket;
  final DbKciAbschnitt abschnitt;
  final DateTime now;
  const _SectionTile({
    required this.ticketKey,
    required this.ticket,
    required this.abschnitt,
    required this.now,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final leg = _leg(ticket, abschnitt.nummer);
    final a = abschnitt;
    final seats = a.plaetze.isNotEmpty ? a.plaetze : a.reserviertePlaetze;
    final Widget trailing;
    if (a.eingecheckt) {
      trailing = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.check_circle, color: theme.colorScheme.primary, size: 20),
          const SizedBox(width: 6),
          Text(a.kontrolliert ? 'Kontrolliert' : 'Eingecheckt'),
        ],
      );
    } else if (a.canCheckIn(now)) {
      trailing = FilledButton(
        onPressed: () => showDialog<void>(
          context: context,
          builder: (_) => _CheckinDialog(
            ticketKey: ticketKey,
            ticket: ticket,
            abschnitt: a,
            title: leg.title,
          ),
        ),
        child: const Text('Einchecken'),
      );
    } else {
      trailing = Text(
        a.moeglichAb == null
            ? 'noch nicht'
            : 'ab ${DateFormat('HH:mm').format(toBerlin(a.moeglichAb!))}',
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      );
    }
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(leg.title, style: theme.textTheme.titleMedium),
                  if (leg.route != null)
                    Text(
                      leg.route!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  if (seats.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        seats.map((p) => p.label).join(' · '),
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            trailing,
          ],
        ),
      ),
    );
  }
}

/// Train label and route of section [n], read from the ticket's own
/// Verbindung (KCI only gives the index).
({String title, String? route}) _leg(DbTicket t, int n) {
  final raw = t.verbindungJson;
  final v = raw?['verbindung'];
  final vb = v is Map<String, dynamic> ? v : raw;
  final list = vb?['verbindungsAbschnitte'];
  if (list is! List || n < 0 || n >= list.length) {
    return (title: 'Abschnitt ${n + 1}', route: null);
  }
  final a = list[n];
  if (a is! Map<String, dynamic>) {
    return (title: 'Abschnitt ${n + 1}', route: null);
  }
  final name = (a['mitteltext'] ?? a['langtext'] ?? 'Abschnitt ${n + 1}')
      .toString();
  final from = (a['abgangsOrt'] as Map<String, dynamic>?)?['name'];
  final to = (a['ankunftsOrt'] as Map<String, dynamic>?)?['name'];
  final dep = parseDbTimestamp((a['abgangsDatum'] ?? '').toString());
  final time = dep == null
      ? ''
      : '${DateFormat('HH:mm').format(toBerlin(dep))} ';
  return (
    title: name,
    route: from == null && to == null
        ? null
        : '$time${from ?? ''} → ${to ?? ''}',
  );
}

/// Seat (+ BahnCard when the fare uses one) and the actual check-in call.
class _CheckinDialog extends ConsumerStatefulWidget {
  final String ticketKey;
  final DbTicket ticket;
  final DbKciAbschnitt abschnitt;
  final String title;
  const _CheckinDialog({
    required this.ticketKey,
    required this.ticket,
    required this.abschnitt,
    required this.title,
  });

  @override
  ConsumerState<_CheckinDialog> createState() => _CheckinDialogState();
}

class _CheckinDialogState extends ConsumerState<_CheckinDialog> {
  late final TextEditingController _wagen;
  late final TextEditingController _platz;
  late final TextEditingController _bahncard;
  bool _busy = false;
  String? _error;

  bool get _needsBahnCard => widget.ticket.ermaessigungen.isNotEmpty;

  @override
  void initState() {
    super.initState();
    final reserved = widget.abschnitt.reserviertePlaetze.firstOrNull;
    _wagen = TextEditingController(text: reserved?.wagennummer ?? '');
    _platz = TextEditingController(text: reserved?.platznummer ?? '');
    // The traveller's BahnCard: prefill from the signed-in account's valid
    // card. An added ticket may belong to someone else — then it stays
    // editable.
    final cards = ref.read(bahncardsProvider).asData?.value ?? const [];
    final card = cards.where((c) => c.isValidNow).firstOrNull;
    _bahncard = TextEditingController(text: card?.nummer ?? '');
  }

  @override
  void dispose() {
    _wagen.dispose();
    _platz.dispose();
    _bahncard.dispose();
    super.dispose();
  }

  bool get _valid =>
      _wagen.text.trim().isNotEmpty &&
      _platz.text.trim().isNotEmpty &&
      (!_needsBahnCard || _bahncard.text.trim().isNotEmpty);

  Future<void> _submit() async {
    if (!_valid || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await kciCheckin(
        ref,
        widget.ticketKey,
        abschnitt: widget.abschnitt.nummer,
        plaetze: [
          DbKciPlatz(
            wagennummer: _wagen.text.trim(),
            platznummer: _platz.text.trim(),
          ),
        ],
        bahnCards: _needsBahnCard
            ? [_bahncard.text.replaceAll(RegExp(r'\s'), '')]
            : const [],
      );
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Eingecheckt')));
    } on DbKciException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = 'Check-in fehlgeschlagen: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final digits = [FilteringTextInputFormatter.digitsOnly];
    return AlertDialog(
      title: Text('Einchecken · ${widget.title}'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.abschnitt.reserviertePlaetze.isNotEmpty
                  ? 'Dein reservierter Platz ist eingetragen.'
                  : 'Auf welchem Platz sitzt du? Die Nummern stehen am Sitz.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _wagen,
                    enabled: !_busy,
                    keyboardType: TextInputType.number,
                    inputFormatters: digits,
                    decoration: const InputDecoration(
                      labelText: 'Wagen',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _platz,
                    enabled: !_busy,
                    keyboardType: TextInputType.number,
                    inputFormatters: digits,
                    decoration: const InputDecoration(
                      labelText: 'Platz',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
              ],
            ),
            if (_needsBahnCard) ...[
              const SizedBox(height: 12),
              TextField(
                controller: _bahncard,
                enabled: !_busy,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText:
                      'BahnCard-Nummer (${widget.ticket.ermaessigungen.join(', ')})',
                  border: const OutlineInputBorder(),
                ),
                onChanged: (_) => setState(() {}),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Abbrechen'),
        ),
        FilledButton(
          onPressed: _valid && !_busy ? _submit : null,
          child: _busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Einchecken'),
        ),
      ],
    );
  }
}
