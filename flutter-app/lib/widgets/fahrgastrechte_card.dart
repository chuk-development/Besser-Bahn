import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/passenger_rights.dart';
import '../models/journey.dart';

/// Banner shown when a (usually completed) journey arrived 60+ min late and the
/// rider is therefore entitled to a Fahrgastrechte refund. Detects the claim,
/// shows the amount, copies the prefilled facts, and opens the DB form.
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
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.copy, size: 18),
                    label: const Text('Daten kopieren'),
                    onPressed: () {
                      Clipboard.setData(
                          ClipboardData(text: rights.prefillText(journey)));
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                        duration: Duration(seconds: 2),
                        content: Text('Antragsdaten kopiert'),
                      ));
                    },
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton.icon(
                    icon: const Icon(Icons.open_in_new, size: 18),
                    label: const Text('Antrag'),
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
}
