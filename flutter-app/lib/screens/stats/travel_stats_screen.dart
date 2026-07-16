import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../models/db_account.dart';
import '../../models/travel_stats.dart';
import '../../providers/account_provider.dart';
import '../../providers/travel_stats_provider.dart';

/// "Reise­statistik" — lifetime, on-device totals derived from completed saved
/// trips plus the official current-year CO₂ balance from BahnBonus.
class TravelStatsScreen extends ConsumerWidget {
  const TravelStatsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stats = ref.watch(travelStatsProvider);
    final auth = ref.watch(dbAuthProvider);
    final co2 = ref.watch(bahnbonusCo2Provider);
    final theme = Theme.of(context);
    final hasStatsContent = !stats.isEmpty || auth.isLoggedIn;

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
      body: !hasStatsContent
          ? _empty(context)
          : RefreshIndicator(
              onRefresh: () =>
                  ref.read(bahnbonusCo2Provider.notifier).refresh(),
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                children: [
                  if (stats.isEmpty)
                    _localStatsEmptyCard(context)
                  else ...[
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
                          child: _miniStat(
                            context,
                            icon: Icons.straighten,
                            label: 'Längste Fahrt',
                            value: '${_km(stats.longestTripKm)} km',
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _miniStat(
                            context,
                            icon: Icons.running_with_errors,
                            label: 'Schlimmste Verspätung',
                            value: stats.worstDelayMinutes > 0
                                ? '+${stats.worstDelayMinutes} Min'
                                : '—',
                          ),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 12),
                  _co2Card(context, auth.isLoggedIn, co2, ref),
                  if (!stats.isEmpty) ...[
                    const SizedBox(height: 16),
                    Text(
                      'Die Reise- und Pünktlichkeitswerte werden aus deinen '
                      'gespeicherten Reisen geschätzt; die Strecke ist eine '
                      'Näherung (Luftlinie × 1,2). Die CO₂-Bilanz kommt '
                      'offiziell aus BahnBonus.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
    );
  }

  Widget _hero(BuildContext context, TravelStats s) {
    final theme = Theme.of(context);
    final since = s.firstTripMs > 0
        ? DateFormat(
            'MMMM yyyy',
            'de',
          ).format(DateTime.fromMillisecondsSinceEpoch(s.firstTripMs))
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
                Icon(
                  Icons.train,
                  color: theme.colorScheme.onPrimaryContainer,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Text(
                  'Insgesamt gereist',
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: theme.colorScheme.onPrimaryContainer,
                  ),
                ),
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
                color: theme.colorScheme.onPrimaryContainer.withValues(
                  alpha: 0.8,
                ),
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
    final color = good
        ? Colors.green
        : (pct >= 60 ? Colors.orange : theme.colorScheme.error);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.schedule, color: color, size: 20),
            const SizedBox(height: 10),
            Text(
              '$pct %',
              style: theme.textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              'pünktlich (${s.onTimeCount}/${s.tripCount})',
              style: theme.textTheme.bodySmall,
            ),
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
            Text(
              '+${avg.toStringAsFixed(avg < 10 ? 1 : 0)} Min',
              style: theme.textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 2),
            Text('Ø Verspätung', style: theme.textTheme.bodySmall),
            const SizedBox(height: 4),
            Text(
              '${s.totalDelayMinutes} Min insgesamt',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _miniStat(
    BuildContext context, {
    required IconData icon,
    required String label,
    required String value,
  }) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: theme.colorScheme.primary, size: 20),
            const SizedBox(height: 10),
            Text(
              value,
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 2),
            Text(label, style: theme.textTheme.bodySmall),
          ],
        ),
      ),
    );
  }

  Widget _co2Card(
    BuildContext context,
    bool loggedIn,
    AsyncValue<DbBahnBonusCo2Balance?> co2,
    WidgetRef ref,
  ) {
    final theme = Theme.of(context);
    if (!loggedIn) {
      return Card(
        child: ListTile(
          leading: Icon(
            Icons.eco_outlined,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          title: const Text('CO₂-Ersparnis'),
          subtitle: const Text(
            'DB-Konto verbinden, um deine offizielle BahnBonus-Bilanz zu sehen.',
          ),
        ),
      );
    }
    final balance = co2.value;
    if (balance != null) return _officialCo2Card(context, balance);
    if (co2.isLoading) {
      return const Card(
        child: ListTile(
          leading: SizedBox.square(
            dimension: 24,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          title: Text('CO₂-Bilanz wird geladen'),
          subtitle: Text('Offizielle Daten aus BahnBonus'),
        ),
      );
    }
    if (co2.hasError) {
      return Card(
        child: ListTile(
          leading: Icon(Icons.eco_outlined, color: theme.colorScheme.error),
          title: const Text('CO₂-Bilanz nicht verfügbar'),
          subtitle: const Text('BahnBonus konnte gerade nicht geladen werden.'),
          trailing: IconButton(
            tooltip: 'Erneut versuchen',
            icon: const Icon(Icons.refresh),
            onPressed: () => ref.read(bahnbonusCo2Provider.notifier).refresh(),
          ),
        ),
      );
    }
    return Card(
      child: ListTile(
        leading: Icon(
          Icons.eco_outlined,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        title: const Text('CO₂-Ersparnis'),
        subtitle: const Text(
          'Für dieses Jahr liegen bei BahnBonus noch keine Daten vor.',
        ),
      ),
    );
  }

  Widget _officialCo2Card(BuildContext context, DbBahnBonusCo2Balance balance) {
    final theme = Theme.of(context);
    final green = Colors.green.shade700;
    return Card(
      color: theme.colorScheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.eco, color: green),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Offizielle CO₂-Bilanz ${balance.year}',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const Chip(
                  label: Text('BahnBonus'),
                  visualDensity: VisualDensity.compact,
                  side: BorderSide.none,
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              '${_co2Weight(balance.reductionKg)} gespart',
              style: theme.textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.bold,
                color: green,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'gegenüber derselben Strecke mit dem Pkw',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 18,
              runSpacing: 8,
              children: [
                _co2Detail(
                  context,
                  'Bahn',
                  _co2Weight(balance.trainEmissionKg),
                ),
                _co2Detail(context, 'Pkw', _co2Weight(balance.carEmissionKg)),
                _co2Detail(
                  context,
                  'Strecke',
                  '${_km(balance.travelDistanceKm)} km',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _co2Detail(BuildContext context, String label, String value) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        Text(
          value,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }

  Widget _localStatsEmptyCard(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Row(
          children: [
            Icon(
              Icons.insights,
              color: theme.colorScheme.onSurfaceVariant,
              size: 32,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Noch keine lokale Reisestatistik',
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Kilometer und Pünktlichkeit erscheinen nach deiner ersten '
                    'abgeschlossenen gespeicherten Reise.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
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

  String _co2Weight(double kg) {
    if (kg >= 10000) {
      return '${NumberFormat('#,##0.0', 'de').format(kg / 1000)} t';
    }
    if (kg >= 100) {
      return '${NumberFormat('#,##0', 'de').format(kg.round())} kg';
    }
    return '${NumberFormat('#,##0.0', 'de').format(kg)} kg';
  }

  Widget _empty(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.insights,
              size: 64,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 16),
            Text('Noch keine Statistik', style: theme.textTheme.titleMedium),
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
          'Noch gespeicherte vergangene Reisen werden neu gezählt.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Zurücksetzen'),
          ),
        ],
      ),
    );
    if (ok == true) ref.read(travelStatsProvider.notifier).reset();
  }
}
