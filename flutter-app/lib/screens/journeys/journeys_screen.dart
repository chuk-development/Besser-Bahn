import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/extensions.dart';
import '../../models/library_models.dart';
import '../../models/travel_stats.dart';
import '../../providers/library_provider.dart';
import '../../providers/travel_stats_provider.dart';
import '../../widgets/app_menu_button.dart';
import '../connection_search/widgets/journey_card.dart';

/// "Reisen" — the user's saved connections, like the DB Navigator. Upcoming
/// trips on top, completed ones under "Vergangene Reisen". Trips bookmark from
/// the connection detail; they auto-purge a week after arrival.
class JourneysScreen extends ConsumerWidget {
  const JourneysScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lib = ref.watch(libraryProvider);
    final upcoming = lib.upcomingJourneys;
    final past = lib.pastJourneys;
    final stats = ref.watch(travelStatsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Reisen'),
        actions: [
          IconButton(
            tooltip: 'Reisestatistik',
            icon: const Icon(Icons.insights),
            onPressed: () => context.push('/stats'),
          ),
          const AppMenuButton(),
        ],
      ),
      body: upcoming.isEmpty && past.isEmpty
          ? _empty(context)
          : ListView(
              padding: const EdgeInsets.only(top: 8, bottom: 32),
              children: [
                if (!stats.isEmpty) _statsTeaser(context, stats),
                if (upcoming.isNotEmpty) ...[
                  _sectionHeader(context, 'Anstehende Reisen', upcoming.length),
                  for (final j in upcoming) _entry(context, ref, j),
                ],
                if (past.isNotEmpty) ...[
                  _sectionHeader(context, 'Vergangene Reisen', past.length),
                  for (final j in past) _entry(context, ref, j, past: true),
                ],
              ],
            ),
    );
  }

  /// Compact lifetime-stats banner that taps through to the full screen.
  Widget _statsTeaser(BuildContext context, TravelStats stats) {
    final theme = Theme.of(context);
    final km = stats.totalKm >= 100
        ? NumberFormat('#,##0', 'de').format(stats.totalKm.round())
        : NumberFormat('#,##0.0', 'de').format(stats.totalKm);
    final pct = (stats.onTimeRate * 100).round();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Card(
        color: theme.colorScheme.primaryContainer,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => context.push('/stats'),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Icon(Icons.insights,
                    color: theme.colorScheme.onPrimaryContainer),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('$km km · ${stats.tripCount} '
                          '${stats.tripCount == 1 ? 'Fahrt' : 'Fahrten'}',
                          style: theme.textTheme.titleMedium?.copyWith(
                            color: theme.colorScheme.onPrimaryContainer,
                            fontWeight: FontWeight.bold,
                          )),
                      Text('$pct % pünktlich · deine Reisestatistik',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onPrimaryContainer
                                .withValues(alpha: 0.8),
                          )),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right,
                    color: theme.colorScheme.onPrimaryContainer),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _entry(BuildContext context, WidgetRef ref, SavedJourney saved,
      {bool past = false}) {
    return Dismissible(
      key: ValueKey(saved.key),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 28),
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.errorContainer,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Icon(Icons.delete_outline,
            color: Theme.of(context).colorScheme.onErrorContainer),
      ),
      onDismissed: (_) {
        ref.read(libraryProvider.notifier).removeJourney(saved.key);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              duration: Duration(seconds: 2), content: Text('Reise entfernt')),
        );
      },
      child: Opacity(
        opacity: past ? 0.7 : 1,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _dateLabel(context, saved),
            JourneyCard(journey: saved.journey),
          ],
        ),
      ),
    );
  }

  Widget _dateLabel(BuildContext context, SavedJourney saved) {
    final dep = saved.journey.plannedDeparture ?? saved.journey.departure;
    if (dep == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 16, 0),
      child: Text(
        _relativeDate(dep),
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
      ),
    );
  }

  /// "Heute" / "Morgen" / "Gestern" else the date.
  String _relativeDate(DateTime dt) {
    final now = DateTime.now();
    final d = DateTime(dt.year, dt.month, dt.day);
    final today = DateTime(now.year, now.month, now.day);
    final diff = d.difference(today).inDays;
    if (diff == 0) return 'Heute · ${dt.hhmm}';
    if (diff == 1) return 'Morgen · ${dt.hhmm}';
    if (diff == -1) return 'Gestern · ${dt.hhmm}';
    return dt.dayMonthYear;
  }

  Widget _sectionHeader(BuildContext context, String title, int count) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        '$title ($count)',
        style: Theme.of(context)
            .textTheme
            .titleMedium
            ?.copyWith(fontWeight: FontWeight.bold),
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
            Icon(Icons.bookmark_border,
                size: 64,
                color: theme.colorScheme.onSurfaceVariant.withAlpha(80)),
            const SizedBox(height: 16),
            Text('Noch keine Reisen gespeichert',
                style: theme.textTheme.titleMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            const SizedBox(height: 8),
            Text(
              'Suche eine Verbindung und tippe in der Detailansicht\n'
              'auf das Lesezeichen, um sie hier zu speichern.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
