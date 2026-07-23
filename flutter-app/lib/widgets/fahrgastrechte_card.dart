import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/passenger_rights.dart';
import '../models/journey.dart';

/// Banner shown when a (usually completed) journey arrived 60+ min late and the
/// rider is therefore entitled to a Fahrgastrechte refund. Detects the claim,
/// shows the amount, and opens the assistant that prefills the claim, lets the
/// rider enter the fare + ticket type, and links to DB's form.
class FahrgastrechteCard extends StatelessWidget {
  final Journey journey;
  const FahrgastrechteCard({super.key, required this.journey});

  @override
  Widget build(BuildContext context) {
    final rights = PassengerRights.evaluate(journey);
    if (!rights.isEligible) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final refund = rights.refundEuros(journey.price?.amount);

    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      color: theme.colorScheme.tertiaryContainer,
      child: InkWell(
        onTap: () => showFahrgastrechteAssistant(context, journey),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.gavel,
                      color: theme.colorScheme.onTertiaryContainer, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text('Anspruch auf Entschädigung',
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: theme.colorScheme.onTertiaryContainer,
                          fontWeight: FontWeight.bold,
                        )),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                '${rights.delayMinutes} Min Verspätung am Ziel → '
                '${rights.percent} % des Fahrpreises zurück'
                '${refund != null ? ' (≈ ${refund.toStringAsFixed(2)} €)' : ''}.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onTertiaryContainer,
                ),
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.icon(
                  icon: const Icon(Icons.gavel, size: 18),
                  label: const Text('Fahrgastrechte-Assistent'),
                  onPressed: () =>
                      showFahrgastrechteAssistant(context, journey),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Opens the assistant sheet for [journey].
Future<void> showFahrgastrechteAssistant(
    BuildContext context, Journey journey) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _FahrgastrechteAssistantSheet(journey: journey),
  );
}

/// The local Fahrgastrechte assistant: it prefills the claim from the trip,
/// lets the rider set the fare + ticket type (and correct the delay, since a
/// completed trip's stored data often has no live delay), estimates the payout
/// — percentage or statutory pauschale, honouring the €4 minimum — lists the
/// special cases to check, and hands off to DB's form. Everything is computed
/// on the device; nothing is sent anywhere.
class _FahrgastrechteAssistantSheet extends StatefulWidget {
  final Journey journey;
  const _FahrgastrechteAssistantSheet({required this.journey});

  @override
  State<_FahrgastrechteAssistantSheet> createState() =>
      _FahrgastrechteAssistantSheetState();
}

class _FahrgastrechteAssistantSheetState
    extends State<_FahrgastrechteAssistantSheet> {
  late final TextEditingController _fareCtrl;
  late final TextEditingController _delayCtrl;
  FareKind _kind = FareKind.einzelfahrt;
  bool _firstClass = false;

  @override
  void initState() {
    super.initState();
    final price = widget.journey.price?.amount;
    _fareCtrl = TextEditingController(
        text: price != null ? price.toStringAsFixed(2) : '');
    _delayCtrl = TextEditingController(
        text: PassengerRights.delayMinutesOf(widget.journey).toString());
  }

  @override
  void dispose() {
    _fareCtrl.dispose();
    _delayCtrl.dispose();
    super.dispose();
  }

  int get _delay => int.tryParse(_delayCtrl.text.trim()) ?? 0;
  double? get _fare {
    final raw = _fareCtrl.text.trim().replaceAll(',', '.');
    if (raw.isEmpty) return null;
    return double.tryParse(raw);
  }

  bool get _fareRelevant =>
      _kind == FareKind.einzelfahrt || _kind == FareKind.hinUndRueck;
  bool get _classRelevant => _kind == FareKind.zeitkarte;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rights = PassengerRights.fromDelay(_delay);
    final estimate = rights.estimate(_kind,
        fareEuros: _fare, firstClass: _firstClass);

    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(Icons.gavel, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text('Fahrgastrechte-Assistent',
                    style: theme.textTheme.titleLarge),
              ],
            ),
            const SizedBox(height: 4),
            Text('${widget.journey.origin?.name ?? ''} → '
                '${widget.journey.destination?.name ?? ''}',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            const SizedBox(height: 16),

            // Delay — prefilled from the trip, correctable by hand.
            TextField(
              controller: _delayCtrl,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: 'Verspätung am Ziel (Minuten)',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),

            // Ticket type.
            DropdownButtonFormField<FareKind>(
              initialValue: _kind,
              decoration: const InputDecoration(
                labelText: 'Ticketart',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              items: [
                for (final k in FareKind.values)
                  DropdownMenuItem(value: k, child: Text(k.label)),
              ],
              onChanged: (k) => setState(() => _kind = k ?? _kind),
            ),
            const SizedBox(height: 12),

            if (_fareRelevant)
              TextField(
                controller: _fareCtrl,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  labelText: 'Fahrpreis (€)',
                  helperText: 'Bei Hin- und Rückfahrt zählt die halbe Summe.',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            if (_classRelevant)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('1. Klasse'),
                value: _firstClass,
                onChanged: (v) => setState(() => _firstClass = v),
              ),

            const SizedBox(height: 12),
            _result(theme, rights, estimate),
            const SizedBox(height: 16),

            // Special cases.
            Text('Bitte prüfen', style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            for (final c in PassengerRights.caveats)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('•  '),
                    Expanded(
                        child: Text(c, style: theme.textTheme.bodySmall)),
                  ],
                ),
              ),
            const SizedBox(height: 12),
            Text(PassengerRights.disclaimer,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            const SizedBox(height: 16),

            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.copy, size: 18),
                    label: const Text('Daten kopieren'),
                    onPressed: rights.isEligible
                        ? () {
                            Clipboard.setData(ClipboardData(
                                text: rights.prefillText(widget.journey)));
                            ScaffoldMessenger.of(context)
                                .showSnackBar(const SnackBar(
                              duration: Duration(seconds: 2),
                              content: Text('Antragsdaten kopiert'),
                            ));
                          }
                        : null,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton.icon(
                    icon: const Icon(Icons.open_in_new, size: 18),
                    label: const Text('Zum Antrag'),
                    onPressed: () => launchUrl(
                      Uri.parse(PassengerRights.formUrl),
                      mode: LaunchMode.externalApplication,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _result(
      ThemeData theme, PassengerRights rights, RefundEstimate estimate) {
    final (String text, IconData icon) = switch (rights.isEligible) {
      false => (
          'Unter 60 Minuten — in der Regel kein Entschädigungsanspruch.',
          Icons.info_outline,
        ),
      true when estimate.isPauschale => (
          'Pauschale laut Gesetz: ≈ ${estimate.amount!.toStringAsFixed(2)} € '
              '(kann sich ändern; der genaue Betrag wird im Antrag berechnet).',
          Icons.euro,
        ),
      true when estimate.belowMinimum => (
          '${rights.percent} % wären ≈ ${estimate.amount!.toStringAsFixed(2)} € '
              '— unter 4 € zahlt die DB nicht aus.',
          Icons.info_outline,
        ),
      true when estimate.isPayable => (
          '${rights.percent} % Entschädigung: '
              '≈ ${estimate.amount!.toStringAsFixed(2)} €.',
          Icons.euro,
        ),
      true => (
          '${rights.percent} % des Fahrpreises. Fahrpreis eingeben für den '
              'Betrag.',
          Icons.euro,
        ),
    };
    final payable = estimate.isPayable;
    final bg = payable
        ? theme.colorScheme.tertiaryContainer
        : theme.colorScheme.surfaceContainerHighest;
    final fg = payable
        ? theme.colorScheme.onTertiaryContainer
        : theme.colorScheme.onSurface;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: fg),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: fg, fontWeight: FontWeight.w500)),
          ),
        ],
      ),
    );
  }
}
