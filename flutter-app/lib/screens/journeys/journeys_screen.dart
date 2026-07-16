import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/extensions.dart';
import '../../models/library_models.dart';
import '../../models/db_ticket.dart';
import '../../models/travel_stats.dart';
import '../../providers/account_provider.dart';
import '../../providers/library_provider.dart';
import '../../providers/offline_package_provider.dart';
import '../../providers/service_providers.dart';
import '../../providers/travel_stats_provider.dart';
import '../../widgets/app_menu_button.dart';
import '../../widgets/offline_package_bar.dart';
import '../../widgets/trip_progress_card.dart';
import '../connection_search/widgets/journey_card.dart';

/// "Reisen" — the user's saved connections, like the DB Navigator. Upcoming
/// trips on top, completed ones under "Vergangene Reisen". Trips bookmark from
/// the connection detail; they auto-purge a week after arrival.
class JourneysScreen extends ConsumerWidget {
  const JourneysScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lib = ref.watch(libraryProvider);
    // A trip bookmarked while signed in exists locally AND in the DB account,
    // and this screen renders both lists — so it appeared twice (#15). The DB
    // section wins (it can delete both sides); drop the local twin. The keys
    // fill in as the "Gemerkte Reisen" tiles resolve their journeys, so a
    // duplicate can flash on first paint and then collapse.
    final dbKeys = ref.watch(dbSavedReiseIdsProvider).keys.toSet();
    // When signed into a DB account, the user's REAL booked tickets lead the
    // list. Logged out, only the local/offline saved trips show — that fallback
    // stays exactly as before.
    final loggedIn = ref.watch(dbAuthProvider).isLoggedIn;
    final tickets = loggedIn ? ref.watch(ticketTripsProvider) : null;
    final ticketTrips = tickets?.asData?.value ?? const <DbTicketTrip>[];
    // A trip that's ALSO a bought ticket renders as that ticket — bookmarking
    // it locally used to list it twice, once per section (#23). Same rule the
    // "Gemerkte Reisen" twins already follow (#15).
    final ticketKeys = {
      for (final t in ticketTrips)
        if (t.journeyKey != null) t.journeyKey!
    };
    bool shownAsDbTrip(SavedJourney j) =>
        dbKeys.contains(j.key) || ticketKeys.contains(j.key);
    final upcoming =
        lib.upcomingJourneys.where((j) => !shownAsDbTrip(j)).toList();
    final past = lib.pastJourneys.where((j) => !shownAsDbTrip(j)).toList();
    final stats = ref.watch(travelStatsProvider);
    // A ticket for a trip that's over belongs under "Vergangene Reisen", not on
    // top as if it were today's (#23).
    final upcomingTickets = ticketTrips.where((t) => !t.isPast).toList();
    final pastTickets = ticketTrips.where((t) => t.isPast).toList();
    final savedReisen =
        loggedIn ? ref.watch(savedReisenProvider) : null;
    final hasLocal = upcoming.isNotEmpty || past.isNotEmpty;

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
      body: (!loggedIn && !hasLocal)
          ? _empty(context)
          : RefreshIndicator(
              onRefresh: () async {
                // Pull-to-refresh = force a foreground fetch (bypasses the
                // disk cache's stale-while-revalidate). The controller
                // handles fallback to the cache on failure so the user is
                // never left with an empty list.
                if (loggedIn) {
                  await ref.read(reisenuebersichtProvider.notifier).refresh();
                }
              },
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.only(top: 8, bottom: 32),
                children: [
                  // Always-visible live Reisefortschritt for the soonest active
                  // trip (self-hides unless in progress or departing soon) — the
                  // in-app stand-in for a Live Activity / home widget.
                  if (upcoming.isNotEmpty)
                    TripProgressCard(
                        journey: upcoming.first.journey, activeOnly: true),
                  if (!stats.isEmpty) _statsTeaser(context, stats),
                  // Official DB tickets (bought on the account) whose trip is
                  // still ahead. No section header — tickets render directly so
                  // the surface stays glanceable, the way DB Navigator's Reisen
                  // tab does. The ones already travelled drop to the bottom.
                  if (loggedIn && tickets != null)
                    tickets.when(
                      data: (_) => Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (final t in upcomingTickets)
                            _OfficialTicketTile(trip: t),
                        ],
                      ),
                      loading: () => const Padding(
                        padding: EdgeInsets.symmetric(vertical: 28),
                        child: Center(child: CircularProgressIndicator()),
                      ),
                      error: (e, _) => Padding(
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                        child: Text(
                            'Tickets konnten nicht geladen werden.',
                            style: TextStyle(
                                color: Theme.of(context).colorScheme.error)),
                      ),
                    ),
                  // Gemerkte Reisen — official "Meine Reisen" the user marked
                  // on DB. Rendered as JourneyCard via the per-rkUuid lookup.
                  if (loggedIn && savedReisen != null)
                    savedReisen.when(
                      data: (list) => list.isEmpty
                          ? const SizedBox.shrink()
                          : Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _sectionHeader(
                                    context, 'Gemerkte Reisen', list.length),
                                for (final s in list)
                                  _SavedReiseTile(index: s),
                              ],
                            ),
                      loading: () => const SizedBox.shrink(),
                      error: (_, _) => const SizedBox.shrink(),
                    ),
                  if (upcoming.isNotEmpty) ...[
                    _sectionHeader(
                        context, 'Anstehende Reisen', upcoming.length),
                    for (final j in upcoming) _entry(context, ref, j),
                  ],
                  // (past trips below — a DB trip that already rendered above
                  // is filtered out of `upcoming`, see the build header.)
                  if (past.isNotEmpty || pastTickets.isNotEmpty) ...[
                    _sectionHeader(context, 'Vergangene Reisen',
                        past.length + pastTickets.length),
                    ..._pastRows(context, ref, past, pastTickets),
                  ],
                ],
              ),
            ),
    );
  }

  /// "Vergangene Reisen": bought tickets and local bookmarks in ONE list, most
  /// recent first — a trip that's over is a trip that's over, whichever side it
  /// came from (#23).
  List<Widget> _pastRows(BuildContext context, WidgetRef ref,
      List<SavedJourney> past, List<DbTicketTrip> tickets) {
    final rows = <({DateTime? end, Widget child})>[
      for (final t in tickets)
        (end: t.endTime, child: _OfficialTicketTile(trip: t, past: true)),
      for (final j in past)
        (end: j.endTime, child: _entry(context, ref, j, past: true)),
    ]..sort((a, b) =>
        (b.end ?? DateTime(0)).compareTo(a.end ?? DateTime(0)));
    return [for (final r in rows) r.child];
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
        // Swiping deleted the local copy only, leaving the trip in the DB
        // account: it kept showing under "Gemerkte Reisen" with an empty
        // bookmark, and re-saving it then created duplicates. Delete both
        // sides — that half-deleted state is what started #15.
        _deleteDbReise(ref, saved.key);
        // The trip is gone, so its offline package is just orphaned bytes.
        ref.read(offlinePackagesProvider.notifier).delete(saved.key);
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
            // Only for trips still ahead: packing a trip you've already taken
            // is pure noise (and would auto-refresh nothing).
            if (!past)
              OfflinePackageBar(
                journey: saved.journey,
                journeyKey: saved.key,
              ),
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
              'auf das Lesezeichen, um sie hier zu speichern.\n'
              'Mit DB-Konto-Login (Profil) erscheinen hier deine\n'
              'echten gekauften Tickets.',
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

/// One server-side "Gemerkte Reise" (tracked but unpaid). Lazily fetches the
/// individual reise via `/mob/reisen/{rkUuid}` and renders it as a regular
/// JourneyCard. Tap → /connection (no ticket — just the Reiseplan).
/// Delete the DB-account "gemerkte Reise" that mirrors the local journey [key],
/// if we know which one that is. Best-effort: a purely local bookmark has no
/// rkUuid and nothing to delete.
Future<void> _deleteDbReise(WidgetRef ref, String key) async {
  if (!ref.read(dbAuthProvider).isLoggedIn) return;
  final rkUuid = ref.read(dbSavedReiseIdsProvider.notifier).take(key);
  if (rkUuid == null) return;
  try {
    await ref.read(dbAccountServiceProvider).deleteReise(rkUuid);
    await ref.read(reisenuebersichtProvider.notifier).refresh();
  } catch (_) {/* best-effort — the local entry is already gone */}
}

class _SavedReiseTile extends ConsumerWidget {
  final DbSavedReiseIndex index;
  const _SavedReiseTile({required this.index});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final journey = ref.watch(savedReiseJourneyProvider(index.rkUuid));
    final j = journey.asData?.value;
    if (j != null && j.legs.isNotEmpty) {
      // Swipeable like a local trip: a "Gemerkte Reise" had no delete
      // affordance at all here, so a trip orphaned in the DB account couldn't
      // be removed from this screen by any gesture (#15).
      return Dismissible(
        key: ValueKey('db-${index.rkUuid}'),
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
          final key = SavedJourney(journey: j, savedAtMs: 0).key;
          // Both sides, so this can't recreate the half-deleted state.
          ref.read(libraryProvider.notifier).removeJourney(key);
          _deleteDbReise(ref, key);
          ref.read(offlinePackagesProvider.notifier).delete(key);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                duration: Duration(seconds: 2),
                content: Text('Reise entfernt')),
          );
        },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            JourneyCard(
              journey: j,
              onTap: () => context.push('/connection', extra: j),
            ),
            // Same journey key derivation the delete path above uses, so a
            // package always belongs to exactly one trip however it was saved.
            OfflinePackageBar(
              journey: j,
              journeyKey: SavedJourney(journey: j, savedAtMs: 0).key,
            ),
          ],
        ),
      );
    }
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: ListTile(
        leading: Icon(Icons.bookmark, color: theme.colorScheme.primary),
        title: Text(index.startDatum != null
            ? DateFormat('EEE, dd.MM.yyyy · HH:mm', 'de')
                .format(index.startDatum!)
            : 'Gemerkte Reise'),
        subtitle:
            Text(journey is AsyncLoading ? 'lädt…' : 'Konnte nicht laden'),
      ),
    );
  }
}

/// A booked official ticket in the Reisen list. The trip plan is already
/// resolved by [ticketTripsProvider]; once it parsed, this renders the same
/// [JourneyCard] used in search — so a bought ticket looks exactly like a found
/// connection, just routed to the ticket detail on tap. Falls back to a compact
/// placeholder tile when the Verbindung can't be parsed.
///
/// [past] dims it and prefixes the travel date, matching a past local trip —
/// a ticket for last week's trip used to sit on top looking current (#23).
class _OfficialTicketTile extends ConsumerWidget {
  final DbTicketTrip trip;
  final bool past;
  const _OfficialTicketTile({required this.trip, this.past = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final index = trip.index;
    final kwId =
        index.kundenwunschIds.isNotEmpty ? index.kundenwunschIds.first : '';
    if (kwId.isEmpty) return const SizedBox.shrink();
    void onTap() => context.push('/ticket', extra: {
          'auftragsnummer': index.auftragsnummer,
          'kundenwunschId': kwId,
        });

    final t = trip.ticket;
    final theme = Theme.of(context);
    final Widget tile;
    if (trip.journey != null) {
      tile = JourneyCard(journey: trip.journey!, onTap: onTap);
    } else {
      // Placeholder while loading / when verbindung can't be parsed.
      tile = Card(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: ListTile(
          leading: Icon(Icons.confirmation_number_outlined,
              color: theme.colorScheme.primary),
          title: Text(
            t != null && (t.vonName != null || t.nachName != null)
                ? '${t.vonName ?? '—'} → ${t.nachName ?? '—'}'
                : 'Auftrag ${index.auftragsnummer}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            [
              if ((t?.gueltigAb ?? index.aenderungsDatum) != null)
                DateFormat('dd.MM.yyyy')
                    .format(t?.gueltigAb ?? index.aenderungsDatum!),
              if (t != null) t.firstClass ? '1. Kl.' : '2. Kl.',
              if (t?.angebotsname != null) t!.angebotsname!,
            ].where((s) => s.isNotEmpty).join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: onTap,
        ),
      );
    }
    if (!past) {
      // A booked upcoming trip is the strongest case for an offline package —
      // and the only one where the ticket part can actually report a ticket.
      final j = trip.journey;
      final key = trip.journeyKey;
      if (j == null || key == null) return tile;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          tile,
          OfflinePackageBar(journey: j, journeyKey: key),
        ],
      );
    }
    final dep = trip.journey?.plannedDeparture ??
        trip.journey?.departure ??
        t?.gueltigAb;
    return Opacity(
      opacity: 0.7,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (dep != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 16, 0),
              child: Text(
                DateFormat('dd.MM.yyyy').format(dep),
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          tile,
        ],
      ),
    );
  }
}
