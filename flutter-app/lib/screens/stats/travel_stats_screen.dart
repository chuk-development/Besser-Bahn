import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../models/travel_stats.dart';
import '../../providers/travel_stats_provider.dart';

/// "Reise­statistik" — lifetime, on-device totals derived from completed saved
/// trips. Kilometres, punctuality and delay balance; CO₂ is a placeholder until
/// real DB login can fetch the official Bahn-Bonus figure.
class TravelStatsScreen extends ConsumerWidget {
  const TravelStatsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stats = ref.watch(travelStatsProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Reisestatistik'),
        actions: [
          if (!stats.isEmpty)
            IconButton(
              tooltip: 'Zurücksetzen',
              icon: const Icon(Icons.restart_alt),
              onPressed: () => _confirmReset(context, ref),
            ),
        ],
      ),
      body: stats.isEmpty
          ? _empty(context)
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
              children: [
                _hero(context, stats),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(child: _punctualityCard(context, stats)),
                    const SizedBox(width: 12),
                    Expanded(child: _avgDelayCard(context, stats)),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: _miniStat(context,
                          icon: Icons.straighten,
                          label: 'Längste Fahrt',
                          value: '${_km(stats.longestTripKm)} km'),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _miniStat(context,
                          icon: Icons.running_with_errors,
                          label: 'Schlimmste Verspätung',
                          value: stats.worstDelayMinutes > 0
                              ? '+${stats.worstDelayMinutes} Min'
                              : '—'),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                _co2Placeholder(context),
                const SizedBox(height: 16),
                Text(
                  'Geschätzt aus deinen gespeicherten Reisen — die Strecke ist '
                  'eine Näherung (Luftlinie × 1,2), nicht die Tarif-Entfernung. '
                  'Alles bleibt lokal auf deinem Gerät.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
    );
  }

  Widget _hero(BuildContext context, TravelStats s) {
    final theme = Theme.of(context);
    final since = s.firstTripMs > 0
        ? DateFormat('MMMM yyyy', 'de')
            .format(DateTime.fromMillisecondsSinceEpoch(s.firstTripMs))
        : null;
    return Card(
      color: theme.colorScheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.train,
                    color: theme.colorScheme.onPrimaryContainer, size: 20),
                const SizedBox(width: 8),
                Text('Insgesamt gereist',
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: theme.colorScheme.onPrimaryContainer,
                    )),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '${_km(s.totalKm)} km',
              style: theme.textTheme.displaySmall?.copyWith(
                color: theme.colorScheme.onPrimaryContainer,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'auf ${s.tripCount} ${s.tripCount == 1 ? 'Fahrt' : 'Fahrten'}'
              '${since != null ? ' · seit $since' : ''}',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onPrimaryContainer.withValues(alpha: 0.8),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _punctualityCard(BuildContext context, TravelStats s) {
    final theme = Theme.of(context);
    final pct = (s.onTimeRate * 100).round();
    final good = s.onTimeRate >= 0.8;
    final color = good ? Colors.green : (pct >= 60 ? Colors.orange : theme.colorScheme.error);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.schedule, color: color, size: 20),
            const SizedBox(height: 10),
            Text('$pct %',
                style: theme.textTheme.headlineMedium
                    ?.copyWith(fontWeight: FontWeight.bold, color: color)),
            const SizedBox(height: 2),
            Text('pünktlich (${s.onTimeCount}/${s.tripCount})',
                style: theme.textTheme.bodySmall),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: s.onTimeRate,
                minHeight: 6,
                backgroundColor: theme.colorScheme.surfaceContainerHighest,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _avgDelayCard(BuildContext context, TravelStats s) {
    final theme = Theme.of(context);
    final avg = s.avgDelayMinutes;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.timelapse, color: theme.colorScheme.primary, size: 20),
            const SizedBox(height: 10),
            Text('+${avg.toStringAsFixed(avg < 10 ? 1 : 0)} Min',
                style: theme.textTheme.headlineMedium
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 2),
            Text('Ø Verspätung', style: theme.textTheme.bodySmall),
            const SizedBox(height: 4),
            Text('${s.totalDelayMinutes} Min insgesamt',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                )),
          ],
        ),
      ),
    );
  }

  Widget _miniStat(BuildContext context,
      {required IconData icon, required String label, required String value}) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: theme.colorScheme.primary, size: 20),
            const SizedBox(height: 10),
            Text(value,
                style: theme.textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 2),
            Text(label, style: theme.textTheme.bodySmall),
          ],
        ),
      ),
    );
  }

  Widget _co2Placeholder(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: ListTile(
        leading: Icon(Icons.eco_outlined,
            color: theme.colorScheme.onSurfaceVariant),
        title: const Text('CO₂-Ersparnis'),
        subtitle: const Text(
            'Kommt mit DB-Login — die offizielle Bilanz aus der Bahn-Bonus-App.'),
        trailing: Chip(
          label: const Text('bald'),
          visualDensity: VisualDensity.compact,
          backgroundColor: theme.colorScheme.surfaceContainerHighest,
          side: BorderSide.none,
        ),
      ),
    );
  }

  Widget _empty(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.insights,
                size: 64, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 16),
            Text('Noch keine Statistik',
                style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              'Sobald eine deiner gespeicherten Reisen abgeschlossen ist, '
              'zählen wir hier Kilometer und Pünktlichkeit zusammen — lokal.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _km(double km) {
    if (km >= 100) return NumberFormat('#,##0', 'de').format(km.round());
    return NumberFormat('#,##0.0', 'de').format(km);
  }

  Future<void> _confirmReset(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Statistik zurücksetzen?'),
        content: const Text(
            'Alle gezählten Kilometer und Verspätungen werden gelöscht. '
            'Noch gespeicherte vergangene Reisen werden neu gezählt.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Abbrechen')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Zurücksetzen')),
        ],
      ),
    );
    if (ok == true) ref.read(travelStatsProvider.notifier).reset();
  }
}
