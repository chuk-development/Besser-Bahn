import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/extensions.dart';
import '../../core/share_text.dart';
import '../../models/coach_sequence.dart';
import '../../models/journey.dart';
import '../../models/library_models.dart';
import '../../models/station.dart';
import '../../models/trip.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../providers/library_provider.dart';
import '../../providers/account_provider.dart';
import '../../providers/service_providers.dart';
import '../profile/widgets/bahncard_view.dart' show openFirstBahnCardControl;
import '../../providers/settings_provider.dart';
import '../../providers/split_ticket_provider.dart';
import '../../providers/station_map_provider.dart';
import '../../services/db_api_service.dart';
import '../../widgets/departure_card.dart';
import '../../widgets/fahrgastrechte_card.dart';
import '../../widgets/prediction_badge.dart';
import '../../widgets/product_badge.dart';
import '../../widgets/trip_progress_inline.dart';
import '../../widgets/trwl_checkin_sheet.dart';
import '../train_lookup/widgets/train_detail_view.dart';
import 'widgets/leg_switcher.dart';

/// In-memory cache (app session) so a leg's train data is fetched once and
/// reused — scrolling away and back never re-downloads or rebuilds from
/// scratch; cached data shows instantly and refreshes in the background.
final Map<String, Trip> _tripCache = {};
final Map<String, CoachSequence> _coachCache = {};

/// Full multi-leg connection as ONE screen: each train's complete detail
/// (header, live map, coach sequence, stops) stacked vertically — scroll down
/// to the next train. No intermediate "pick a leg" screen.
/// Identifies the booked ticket whose Reiseplan this screen is showing.
typedef TicketRef = ({String auftragsnummer, String kundenwunschId});

class ConnectionDetailScreen extends ConsumerStatefulWidget {
  final Journey journey;

  /// When this Reiseplan belongs to a *bought* ticket (opened from the Reisen
  /// tab), this ref points at the order so the AppBar can offer a "Ticket"
  /// action that opens the official Handyticket. Null for plain search-result
  /// connections.
  final TicketRef? ticketRef;

  const ConnectionDetailScreen({
    super.key,
    required this.journey,
    this.ticketRef,
  });

  @override
  ConsumerState<ConnectionDetailScreen> createState() =>
      _ConnectionDetailScreenState();
}

class _ConnectionDetailScreenState
    extends ConsumerState<ConnectionDetailScreen> {
  // The working itinerary. Starts as the passed journey; swapping a leg via
  // "Weitere Abfahrten" rebuilds it (and drops the price/recon, which no longer
  // match the custom combination).
  late Journey _journey = widget.journey;
  Journey get journey => _journey;

  /// Bumped on pull-to-refresh — part of each leg section's key, so bumping it
  /// rebuilds them fresh and re-triggers their trip fetch.
  int _refreshTick = 0;

  /// Pull-to-refresh: drop cached trips for this journey and rebuild the leg
  /// sections so every leg re-fetches its live data.
  Future<void> _refreshAll() async {
    for (final leg in journey.legs) {
      final id = leg.tripId;
      if (id != null) {
        _tripCache.remove(id);
        _coachCache.remove(id);
      }
    }
    if (mounted) setState(() => _refreshTick++);
    // Keep the spinner up briefly while the rebuilt sections kick off fetches.
    await Future.delayed(const Duration(milliseconds: 600));
  }

  /// Swap leg [index] for [newLeg] picked from "Weitere Abfahrten".
  void _replaceLeg(int index, JourneyLeg newLeg) {
    final legs = List<JourneyLeg>.of(_journey.legs);
    if (index < 0 || index >= legs.length) return;
    legs[index] = newLeg;
    setState(() {
      _journey = Journey(legs: legs); // price/refreshToken intentionally dropped
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        duration: Duration(seconds: 3),
        content: Text('Fahrt ersetzt · Preis ggf. neu suchen'),
      ),
    );
  }

  /// First non-walking leg after [i], or null — the train this leg connects to.
  JourneyLeg? _nextTransitLeg(List<JourneyLeg> legs, int i) {
    for (var j = i + 1; j < legs.length; j++) {
      if (!legs[j].isWalking) return legs[j];
    }
    return null;
  }

  /// Last non-walking leg before [i], or null — the train you arrive on before
  /// changing into leg [i]. Used to judge whether the transfer into [i] is at
  /// risk and from when you can realistically board.
  JourneyLeg? _prevTransitLeg(List<JourneyLeg> legs, int i) {
    for (var j = i - 1; j >= 0; j--) {
      if (!legs[j].isWalking) return legs[j];
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final legs = journey.legs;
    final ticketRef = widget.ticketRef;
    return Scaffold(
      appBar: AppBar(
        // Full route is cut off on a phone here → moved into the summary block.
        title: Text(ticketRef != null ? 'Reiseplan' : 'Verbindung'),
        actions: [
          // For a booked ticket: prominent "Ticket" action top-right, opening
          // the official Handyticket WebView. Search-result connections don't
          // carry a ticket and skip this. The BahnCard quick-jump sits next
          // to it so a conductor can be shown both without leaving Reiseplan.
          if (ticketRef != null) ...[
            IconButton(
              icon: const Icon(Icons.credit_card),
              tooltip: 'BahnCard · Kontrolle',
              onPressed: () => openFirstBahnCardControl(context, ref),
            ),
            IconButton(
              icon: const Icon(Icons.qr_code_2),
              tooltip: 'Ticket anzeigen',
              onPressed: () =>
                  context.push('/ticket-view', extra: ticketRef),
            ),
          ],
          // Teilen + Öffnen folded into one button → a small menu asks which.
          PopupMenuButton<int>(
            icon: const Icon(Icons.ios_share),
            tooltip: 'Teilen / Öffnen',
            onSelected: (v) {
              if (v == 0) {
                _shareJourney(context, ref);
              } else if (v == 2) {
                _shareEta(context, ref);
              } else {
                _openOnBahn(context, ref);
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 0,
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.ios_share),
                  title: Text('Reise teilen'),
                ),
              ),
              PopupMenuItem(
                value: 2,
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.pin_drop_outlined),
                  title: Text('Ankunft für Abholer teilen'),
                ),
              ),
              PopupMenuItem(
                value: 1,
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.open_in_new),
                  title: Text('Auf bahn.de öffnen'),
                ),
              ),
            ],
          ),
          IconButton(
            icon: const Icon(Icons.call_split),
            tooltip: 'Split-Ticket suchen',
            onPressed: () => _openSplitTicket(context, ref),
          ),
          Builder(builder: (context) {
            final key =
                SavedJourney(journey: journey, savedAtMs: 0).key;
            final saved = ref.watch(libraryProvider).hasJourney(key);
            return IconButton(
              icon: Icon(saved ? Icons.bookmark : Icons.bookmark_border),
              tooltip: saved ? 'Reise entfernen' : 'Reise speichern',
              onPressed: () {
                final wasSaved = saved;
                ref.read(libraryProvider.notifier).toggleJourney(journey);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    duration: const Duration(seconds: 2),
                    content:
                        Text(wasSaved ? 'Reise entfernt' : 'Reise gespeichert'),
                  ),
                );
                // Saving + 'Automatisch einchecken' on → also push the trip's
                // train legs to Träwelling. No-op when off / not connected.
                if (!wasSaved) {
                  autoCheckinSavedJourney(context, ref, journey);
                }
                // When signed into a DB account, mirror the bookmark to the
                // official "Meine Reisen" so it also lives in the DB account
                // (and gets DB's delay tracking). Best-effort, never blocks UI.
                _syncDbReise(ref, key, saved: !wasSaved);
              },
            );
          }),
        ],
      ),
      body: RefreshIndicator(
        // Pull down → drop every cached trip for this journey and rebuild the
        // leg sections fresh (new keys), so all live data re-fetches.
        onRefresh: _refreshAll,
        child: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        // Always scrollable so the pull-to-refresh gesture works even when the
        // content is short.
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          _summary(context),
          _buyButton(context, ref),
          // Live companion cards (each self-hides when not applicable):
          // Fahrgastrechte claim on a 60+ min late arrival, and one combined
          // pre-departure card (countdown + "wann musst du los") that
          // disappears once the train has left. The on-board progress lives
          // folded into the summary block above (TripProgressInline).
          FahrgastrechteCard(journey: journey),
          DepartureCard(journey: journey),
          for (var i = 0; i < legs.length; i++) ...[
            if (i > 0) _transfer(context, ref, legs[i - 1], legs[i]),
            if (legs[i].isWalking)
              _walkLeg(context, ref, legs[i],
                  i > 0 ? legs[i - 1] : null,
                  i + 1 < legs.length ? legs[i + 1] : null)
            else ...[
              _LegNotes(notes: _visibleNotes(legs[i].disruptions)),
              Builder(builder: (_) {
                final prev = _prevTransitLeg(legs, i);
                final readyAt = prev != null ? _liveArrivalOf(prev) : null;
                final gap = prev != null
                    ? _gapMinutes(readyAt, _liveDepartureOf(legs[i]))
                    : null;
                return _LegSection(
                  key: ValueKey('leg-$i-${legs[i].tripId}-$_refreshTick'),
                  leg: legs[i],
                  index: i,
                  nextTransitLeg: _nextTransitLeg(legs, i),
                  incomingGapMinutes: gap,
                  readyAt: readyAt,
                  transferStationName: prev?.destination.name,
                  // A fresh trip fetch carries live delays → recompute the
                  // transfer windows above so a shrunk gap shows immediately.
                  onTripUpdated: () {
                    if (mounted) setState(() {});
                  },
                  onReplaceLeg: _replaceLeg,
                );
              }),
            ],
          ],
        ],
        ),
      ),
    );
  }

  /// Mirror a bookmark toggle to the signed-in DB account's "Meine Reisen".
  /// No-op when logged out, or when the journey lacks a recon context /
  /// location ids (then it stays a purely local bookmark).
  Future<void> _syncDbReise(WidgetRef ref, String key,
      {required bool saved}) async {
    if (!ref.read(dbAuthProvider).isLoggedIn) return;
    final service = ref.read(dbAccountServiceProvider);
    final ids = ref.read(dbSavedReiseIdsProvider.notifier);
    try {
      if (saved) {
        final kontext = journey.refreshToken;
        final from = journey.origin?.locationId;
        final to = journey.destination?.locationId;
        final dep = journey.plannedDeparture ?? journey.departure;
        if (kontext == null || !kontext.contains('¶') ||
            from == null || to == null || dep == null) {
          return; // not enough to create a DB trip — local bookmark only
        }
        final rkUuid = await service.saveReise(
          kontext: kontext,
          fromLocationId: from,
          toLocationId: to,
          departure: dep,
        );
        if (rkUuid != null) ids.put(key, rkUuid);
      } else {
        final rkUuid = ids.take(key);
        if (rkUuid != null) await service.deleteReise(rkUuid);
      }
      // Refresh the official list so the Reisen tab reflects the change.
      ref.invalidate(ticketIndicesProvider);
    } catch (_) {/* best-effort — the local bookmark already succeeded */}
  }

  /// Prominent "Kaufen" call to action. Opens the EXACT connection on bahn.de
  /// (the `vbid` deep link lands on the booking/checkout page), where the user
  /// completes the purchase on the official Deutsche-Bahn flow. After buying,
  /// the Profil tab picks the ticket up automatically on app resume.
  ///
  /// Hidden when this Reiseplan IS a bought ticket ([widget.ticketRef] set) —
  /// the user already has a ticket, the AppBar's "Ticket" icon top-right is
  /// what they actually want.
  Widget _buyButton(BuildContext context, WidgetRef ref) {
    if (widget.ticketRef != null) return const SizedBox.shrink();
    final price = journey.price?.amount;
    final label = price != null
        ? 'Kaufen ab ${price.toStringAsFixed(2).replaceAll('.', ',')} €'
        : 'Auf bahn.de kaufen';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: SizedBox(
        width: double.infinity,
        child: FilledButton.icon(
          icon: const Icon(Icons.shopping_cart_outlined),
          label: Text(label),
          style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 14)),
          onPressed: () => _openOnBahn(context, ref),
        ),
      ),
    );
  }

  /// Open this connection on bahn.de. Prefers the official `vbid` deep link
  /// (opens the EXACT connection), and only falls back to a pre-filled search
  /// link if the journey carries no recon context.
  Future<void> _openOnBahn(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    String? url;
    try {
      url = await ref.read(vendoServiceProvider).shareJourney(journey);
    } catch (_) {/* fall back below */}
    url ??= _searchLink(ref);
    if (url == null) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Verbindung nicht verfügbar.')),
      );
      return;
    }
    launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }

  /// Share like the official DB app: rich text (route, date, each train with
  /// platforms) ending in the `vbid` deep link to the EXACT connection. Falls
  /// back to a pre-filled search link if no recon context is available.
  Future<void> _shareJourney(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    String? link;
    try {
      link = await ref.read(vendoServiceProvider).shareJourney(journey);
    } catch (_) {/* fall back below */}
    link ??= _searchLink(ref);
    if (link == null) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Reise lässt sich nicht teilen.')),
      );
      return;
    }
    final o = journey.origin?.name ?? '';
    final d = journey.destination?.name ?? '';
    await SharePlus.instance.share(
      ShareParams(
        text: journeyShareText(journey, link),
        subject: o.isNotEmpty && d.isNotEmpty ? '$o → $d' : 'Bahn-Reise',
      ),
    );
  }

  /// Share a short arrival ETA for whoever's picking you up: destination, live
  /// arrival time + platform + delay, and the live `vbid` link to follow the
  /// train. Falls back to the search link if no recon context exists.
  Future<void> _shareEta(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    String? link;
    try {
      link = await ref.read(vendoServiceProvider).shareJourney(journey);
    } catch (_) {/* fall back below */}
    link ??= _searchLink(ref);
    if (link == null) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Ankunft lässt sich nicht teilen.')),
      );
      return;
    }
    await SharePlus.instance.share(
      ShareParams(
        text: etaShareText(journey, link),
        subject: 'Meine Ankunft — ${journey.destination?.name ?? 'Ziel'}',
      ),
    );
  }

  /// Pre-filled bahn.de fahrplan-suche link (origin/destination, date, BahnCard /
  /// Deutschland-Ticket) — used for "open/book" and as the share fallback.
  String? _searchLink(WidgetRef ref) {
    final o = journey.origin, d = journey.destination;
    final dep = journey.plannedDeparture ?? journey.departure;
    if (o == null || d == null || dep == null) return null;
    final s = ref.read(settingsProvider);
    return DbApiService.generateJourneyLink(
      fromName: o.name,
      toName: d.name,
      fromId: o.id,
      toId: d.id,
      departureIso: dep.toIso8601String(),
      bahnCard: s.bahnCard,
      deutschlandTicket: s.hasDeutschlandTicket,
    );
  }

  /// Build the ordered station list (split points) from the journey's legs and
  /// kick off a split-ticket analysis, then jump to the Split tab — so the user
  /// goes from "found a connection" to "is it cheaper split?" in one tap, no
  /// copy-pasting a bahn.de link.
  void _openSplitTicket(BuildContext context, WidgetRef ref) {
    final stops = <Map<String, dynamic>>[];
    // `boundary` = a leg endpoint (start, terminus or transfer) — always kept
    // when we cap the candidate list, since those are the real rebook points.
    void add(String id, String name, DateTime? dep, bool boundary) {
      if (id.isEmpty) return;
      if (stops.isNotEmpty && stops.last['id'] == id) {
        if (dep != null) stops.last['departure_iso'] = dep.toIso8601String();
        if (boundary) stops.last['_boundary'] = true;
        return;
      }
      stops.add({
        'name': name,
        'id': id,
        'departure_iso': dep?.toIso8601String() ?? '',
        '_boundary': boundary,
      });
    }

    // Cover the WHOLE route: use each leg's full stop list (richest source
    // first — the already-fetched trip in the cache, else the leg's stopovers,
    // else just its endpoints) so the split can break at intermediate stations,
    // not only at transfers.
    for (final leg in journey.legs) {
      if (leg.isWalking) continue;
      final cached = leg.tripId != null ? _tripCache[leg.tripId] : null;
      if (cached != null && cached.stopovers.isNotEmpty) {
        final n = cached.stopovers.length;
        for (var i = 0; i < n; i++) {
          final so = cached.stopovers[i];
          add(so.stop.id, so.stop.name,
              so.departure ?? so.plannedDeparture, i == 0 || i == n - 1);
        }
      } else if (leg.stopovers.isNotEmpty) {
        final n = leg.stopovers.length;
        for (var i = 0; i < n; i++) {
          final so = leg.stopovers[i];
          add(so.stop.id, so.stop.name, so.departure, i == 0 || i == n - 1);
        }
      } else {
        add(leg.origin.id, leg.origin.name,
            leg.plannedDeparture ?? leg.departure, true);
        add(leg.destination.id, leg.destination.name, leg.arrival, true);
      }
    }

    // Cap the candidates so the pairwise price scan stays quick: keep every
    // boundary (rebook) stop and evenly sample the intermediate ones. The
    // number of price queries grows with the square of the stop count.
    const cap = 12;
    if (stops.length > cap) {
      final boundaries = stops.where((s) => s['_boundary'] == true).toList();
      final inner = stops.where((s) => s['_boundary'] != true).toList();
      final slots = (cap - boundaries.length).clamp(0, inner.length);
      final keep = <Map<String, dynamic>>{...boundaries};
      if (slots > 0) {
        final step = inner.length / slots;
        for (var k = 0; k < slots; k++) {
          keep.add(inner[(k * step).floor()]);
        }
      }
      stops.removeWhere((s) => !keep.contains(s));
    }

    if (stops.length < 2) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Zu wenige Haltestellen für ein Split-Ticket.')),
      );
      return;
    }

    final dep = journey.plannedDeparture ?? journey.departure;
    final date = dep != null ? dep.toIso8601String().split('T').first : '';

    ref.read(splitTicketProvider.notifier).analyze(
          stops: stops,
          date: date,
          directPrice: journey.price?.amount ?? 0,
          routeLabel:
              '${journey.origin?.name ?? ''} → ${journey.destination?.name ?? ''}',
          // Stable per-connection key so re-opening the same connection resumes
          // the running analysis instead of restarting it.
          jobKey: '${journey.origin?.id}-${journey.destination?.id}-'
              '${(journey.plannedDeparture ?? journey.departure)?.toIso8601String()}',
        );
    context.push('/split-ticket', extra: journey);
  }

  Widget _summary(BuildContext context) {
    final theme = Theme.of(context);
    final t = journey.transfers;
    final dep = journey.plannedDeparture;
    final arr = journey.plannedArrival;
    final depDelay = journey.legs.firstOrNull?.departureDelay ?? 0;
    final arrDelay = journey.legs.lastOrNull?.arrivalDelay ?? 0;
    // One top block summarising the whole connection: ab→an times + price,
    // total duration · number of transfers, and the connection-wide
    // Anschluss/Pünktlichkeit. The per-train scores live inside each leg below.
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Full route here (moved out of the AppBar, where it was clipped on
            // a phone) — free to wrap onto a second line.
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    '${journey.origin?.name ?? ''} → '
                    '${journey.destination?.name ?? ''}',
                    style: theme.textTheme.titleLarge
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // Big "ab 20:00 → an 23:45" headline, top-left, with the price right.
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                if (dep != null) ...[
                  _summaryTime(context, 'ab', dep, depDelay),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: Icon(Icons.arrow_forward,
                        size: 18, color: theme.colorScheme.onSurfaceVariant),
                  ),
                ],
                if (arr != null) _summaryTime(context, 'an', arr, arrDelay),
                const Spacer(),
                if (journey.price != null)
                  Text(journey.price!.formatted,
                      style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: theme.colorScheme.primary)),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Icon(Icons.schedule,
                    size: 15, color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(width: 4),
                Text(journey.durationString,
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(width: 12),
                Icon(Icons.swap_calls,
                    size: 15, color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(width: 4),
                Text(t == 0 ? 'Direkt' : '$t Umstieg${t > 1 ? 'e' : ''}',
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              ],
            ),
            const SizedBox(height: 10),
            const Divider(height: 1),
            const SizedBox(height: 10),
            PredictionBadge(journey: journey, axis: Axis.horizontal),
            // Live "Reisefortschritt" folded into this main block (instead of a
            // separate card) — only while on board, else it collapses.
            TripProgressInline(journey: journey),
          ],
        ),
      ),
    );
  }

  /// "ab/an HH:MM" with a red "+N" when the leg endpoint is delayed.
  Widget _summaryTime(
      BuildContext context, String label, DateTime time, int delaySec) {
    final theme = Theme.of(context);
    final mins = delaySec ~/ 60;
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text('$label ',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        Text(time.hhmm,
            style: theme.textTheme.titleLarge
                ?.copyWith(fontWeight: FontWeight.bold)),
        // Delay as a clear pill (white on red/amber) next to *this* time — so a
        // late arrival shows behind the arrival time, not a tiny grey "+15".
        if (mins > 0)
          Padding(
            padding: const EdgeInsets.only(left: 5),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: mins <= 5 ? Colors.orange.shade700 : Colors.red.shade700,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text('+$mins',
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.bold)),
            ),
          ),
      ],
    );
  }

  /// Warning banner above a leg listing its disruption notes (HIM messages,
  /// realtime notes) — e.g. "Aufzug in Elmshorn außer Betrieb".
  /// Notes worth keeping in the (collapsed) leg-notes menu. Drops the wing-train
  /// split note — the loud red banner under the boarding stop says it better, so
  /// keeping the text too would just be the clutter we're trying to remove.
  List<String> _visibleNotes(List<String> notes) => notes
      .where((n) => !n.toLowerCase().contains('zugteil'))
      .toList();

  /// Tone for an available transfer time: red ≤2 min (Anschluss gefährdet),
  /// amber ≤5, else null (normal). Returns (textColor, warningText).
  (Color?, String?) _transferTone(BuildContext context, int? mins) {
    if (mins == null) return (null, null);
    if (mins <= 2) {
      return (Theme.of(context).colorScheme.error,
          'Anschluss evtl. nicht erreichbar');
    }
    if (mins <= 5) return (const Color(0xFFCC8800), null);
    return (null, null);
  }

  /// Minutes from [a] to [b], or null if either time is missing.
  int? _gapMinutes(DateTime? a, DateTime? b) =>
      (a != null && b != null) ? b.difference(a).inMinutes : null;

  /// Stopover in [trip] for [station] — match by id, fall back to name.
  Stopover? _stopFor(Trip trip, Station station) {
    if (station.id.isNotEmpty) {
      for (final so in trip.stopovers) {
        if (so.stop.id == station.id) return so;
      }
    }
    for (final so in trip.stopovers) {
      if (station.name.isNotEmpty && so.stop.name == station.name) return so;
    }
    return null;
  }

  /// Freshest arrival of [leg] at its destination: the live time from the
  /// background-refreshed trip when we have it, else the leg's search-time
  /// value. This is what lets a delay shrink a transfer window after the fact.
  DateTime? _liveArrivalOf(JourneyLeg leg) {
    final trip = leg.tripId != null ? _tripCache[leg.tripId] : null;
    final so = trip != null ? _stopFor(trip, leg.destination) : null;
    return so?.arrival ?? leg.arrival;
  }

  /// Freshest departure of [leg] from its origin.
  DateTime? _liveDepartureOf(JourneyLeg leg) {
    final trip = leg.tripId != null ? _tripCache[leg.tripId] : null;
    final so = trip != null ? _stopFor(trip, leg.origin) : null;
    return so?.departure ?? leg.departure;
  }

  /// A FUSSWEG leg between two trains. The headline number is the *time you
  /// have* to change (arrival → next departure), NOT how long the walk takes;
  /// the walk itself is shown as the secondary detail.
  Widget _walkLeg(BuildContext context, WidgetRef ref, JourneyLeg leg,
      JourneyLeg? prev, JourneyLeg? next) {
    // Available transfer time: from the train's arrival to the next departure.
    // DB gives NO walk duration — only (sometimes) a distance — so we never
    // present minutes as how long the walk takes. Use the freshest (live)
    // times so a delay shrinks the window; strike the scheduled value when it
    // no longer holds.
    final liveArr = prev != null ? _liveArrivalOf(prev) : leg.departure;
    final liveDep = next != null ? _liveDepartureOf(next) : leg.arrival;
    final planArr = prev != null
        ? (prev.plannedArrival ?? prev.arrival)
        : (leg.plannedDeparture ?? leg.departure);
    final planDep = next != null
        ? (next.plannedDeparture ?? next.departure)
        : (leg.plannedArrival ?? leg.arrival);

    final liveGap = _gapMinutes(liveArr, liveDep);
    final planGap = _gapMinutes(planArr, planDep);
    final shown = liveGap ?? planGap;
    final changed = liveGap != null && planGap != null && liveGap != planGap;
    final (color, warn) = _transferTone(context, shown);

    final head = shown != null ? '$shown min zum Umsteigen' : 'Umstieg';
    final detail = leg.walkingDistance != null
        ? 'mit Fußweg · ${leg.walkingDistance} m'
        : 'mit Fußweg';

    return _transferTile(
      context,
      icon: Icons.directions_walk,
      head: head,
      strikeBefore: changed ? '$planGap min' : null,
      headColor: color,
      detail: detail,
      warn: warn,
      onTap: leg.origin.name.isEmpty
          ? null
          : () => _openTransferMap(
                context,
                ref,
                leg.origin,
                prev?.arrivalPlatform,
                next?.departurePlatform,
                // Einstieg (primary) = the departing/next train; Ausstieg
                // (secondary) = the arriving/prev train — each drawn to scale.
                depRef: (next?.line?.fahrtNr.isNotEmpty ?? false)
                    ? (
                        category: next!.line?.productName ?? '',
                        trainNumber: next.line!.fahrtNr,
                        time: _liveDepartureOf(next) ?? next.departure,
                      )
                    : null,
                arrRef: (prev?.line?.fahrtNr.isNotEmpty ?? false)
                    ? (
                        category: prev!.line?.productName ?? '',
                        trainNumber: prev.line!.fahrtNr,
                        time: _liveArrivalOf(prev) ?? prev.arrival,
                      )
                    : null,
                // ORIGIN refs → each train's real composition, fetched at its
                // origin departure (a stop the sequence endpoint always serves).
                depFallbackRef: (next?.line?.fahrtNr.isNotEmpty ?? false)
                    ? (
                        category: next!.line?.productName ?? '',
                        trainNumber: next.line!.fahrtNr,
                        originEva: next.origin.id,
                        departureTime: next.departure,
                      )
                    : null,
                arrFallbackRef: (prev?.line?.fahrtNr.isNotEmpty ?? false)
                    ? (
                        category: prev!.line?.productName ?? '',
                        trainNumber: prev.line!.fahrtNr,
                        originEva: prev.origin.id,
                        departureTime: prev.departure,
                      )
                    : null,
                product: next?.line?.product, // Einstieg (primary)
                secondaryProduct: prev?.line?.product, // Ausstieg (secondary)
                primaryTypes: {
                  ...primaryPoiTypesForProduct(prev?.line?.product),
                  ...primaryPoiTypesForProduct(next?.line?.product),
                },
              ),
    );
  }

  /// Open the platform-to-platform map straight away (no intermediate screen):
  /// Einstieg Gleis green, Ausstieg Gleis red, both with their section bands.
  void _openTransferMap(BuildContext context, WidgetRef ref, Station station,
      String? arrGleis, String? depGleis,
      {({String category, String trainNumber, DateTime? time})? depRef,
      ({String category, String trainNumber, DateTime? time})? arrRef,
      ({String category, String trainNumber, String originEva, DateTime? departureTime})?
          depFallbackRef,
      ({String category, String trainNumber, String originEva, DateTime? departureTime})?
          arrFallbackRef,
      String? product,
      String? secondaryProduct,
      Set<String>? primaryTypes}) {
    final note = (arrGleis != null && depGleis != null)
        ? 'Ausstieg Gleis $arrGleis · Einstieg Gleis $depGleis'
        : depGleis != null
            ? 'Einstieg Gleis $depGleis'
            : arrGleis != null
                ? 'Ausstieg Gleis $arrGleis'
                : 'Umstieg in ${station.name}';
    ref.read(stationMapProvider.notifier).loadForStation(
          station,
          highlightGleis: depGleis, // Einstieg — primary, green
          role: GleisRole.board,
          secondaryGleis: arrGleis, // Ausstieg — secondary, red
          secondaryRole: GleisRole.alight,
          coachRef: depRef, // departing train
          secondaryCoachRef: arrRef, // arriving train
          // ORIGIN refs → real per-car compositions for the Einstieg (primary)
          // and Ausstieg (secondary) trains, fetched at each train's origin so
          // they draw to scale even where this stop's Wagenreihung 404s.
          fallbackRef: depFallbackRef, // departing train (Einstieg)
          secondaryFallbackRef: arrFallbackRef, // arriving train (Ausstieg)
          // Products → a realistically-sized generic body where a train has no
          // per-stop Wagenreihung (best-effort, vs a too-long bare line).
          product: product,
          secondaryProduct: secondaryProduct,
          transferNote: note,
          primaryTypes: primaryTypes,
        );
    context.push('/station-map');
  }

  Widget _transfer(
      BuildContext context, WidgetRef ref, JourneyLeg prev, JourneyLeg next) {
    if (prev.isWalking || next.isWalking) return const SizedBox(height: 8);
    // Time you actually have to change trains (arrival → next departure), from
    // the freshest live data. When a delay has eaten into the scheduled gap we
    // strike the old number and show what's really left.
    final liveGap = _gapMinutes(_liveArrivalOf(prev), _liveDepartureOf(next));
    final planGap = _gapMinutes(prev.plannedArrival ?? prev.arrival,
        next.plannedDeparture ?? next.departure);
    final shown = liveGap ?? planGap;
    final changed = liveGap != null && planGap != null && liveGap != planGap;

    final arrGleis = prev.arrivalPlatform;
    final depGleis = next.departurePlatform;
    final station = prev.destination;
    final (color, warn) = _transferTone(context, shown);

    final gleisText = (arrGleis != null || depGleis != null)
        ? 'Gleis ${arrGleis ?? '?'} → Gleis ${depGleis ?? '?'}'
        : null;

    return _transferTile(
      context,
      icon: Icons.swap_calls,
      head: shown != null
          ? '$shown min zum Umsteigen in ${station.name}'
          : 'Umstieg in ${station.name}',
      strikeBefore: changed ? '$planGap min' : null,
      headColor: color,
      detail: gleisText,
      warn: warn,
      onTap: station.name.isEmpty
          ? null
          : () => _openTransferMap(
                context,
                ref,
                station,
                arrGleis,
                depGleis,
                // ORIGIN refs → real per-car compositions for both trains,
                // fetched at each train's origin so the Ausstieg train draws to
                // scale even where this transfer stop's Wagenreihung 404s.
                depFallbackRef: (next.line?.fahrtNr.isNotEmpty ?? false)
                    ? (
                        category: next.line?.productName ?? '',
                        trainNumber: next.line!.fahrtNr,
                        originEva: next.origin.id,
                        departureTime: next.departure,
                      )
                    : null,
                arrFallbackRef: (prev.line?.fahrtNr.isNotEmpty ?? false)
                    ? (
                        category: prev.line?.productName ?? '',
                        trainNumber: prev.line!.fahrtNr,
                        originEva: prev.origin.id,
                        departureTime: prev.departure,
                      )
                    : null,
                product: next.line?.product, // Einstieg (primary)
                secondaryProduct: prev.line?.product, // Ausstieg (secondary)
                primaryTypes: {
                  ...primaryPoiTypesForProduct(prev.line?.product),
                  ...primaryPoiTypesForProduct(next.line?.product),
                },
              ),
    );
  }

  /// Shared tappable transfer/walk row.
  Widget _transferTile(
    BuildContext context, {
    required IconData icon,
    required String head,
    String? strikeBefore,
    Color? headColor,
    String? detail,
    String? warn,
    VoidCallback? onTap,
  }) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
          child: Row(
            children: [
              Icon(icon,
                  size: 18, color: headColor ?? theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        if (strikeBefore != null) ...[
                          Text(
                            strikeBefore,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              decoration: TextDecoration.lineThrough,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(width: 6),
                        ],
                        Flexible(
                          child: Text(
                            head,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                              color: headColor,
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (detail != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(detail,
                            style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant)),
                      ),
                    if (warn != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Row(
                          children: [
                            Icon(Icons.warning_amber_rounded,
                                size: 14, color: theme.colorScheme.error),
                            const SizedBox(width: 4),
                            Flexible(
                              child: Text(warn,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                      color: theme.colorScheme.error,
                                      fontWeight: FontWeight.w600)),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              if (onTap != null) ...[
                const SizedBox(width: 8),
                Icon(Icons.map_outlined,
                    size: 18, color: theme.colorScheme.primary),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// One leg = one train, shown with its full detail (fetched on demand).
class _LegSection extends ConsumerStatefulWidget {
  final JourneyLeg leg;

  /// This leg's position in the journey — passed back to [onReplaceLeg] when
  /// the user swaps in a different departure.
  final int index;

  /// Fired after a fresh trip lands (carries live delays) so the parent can
  /// recompute the transfer windows shown above/below this leg.
  final VoidCallback? onTripUpdated;

  /// Swap this leg for the [newLeg] picked from "Weitere Abfahrten". Null on
  /// the last/only leg combos where replacing makes no sense → button hides
  /// the replace action.
  final void Function(int index, JourneyLeg newLeg)? onReplaceLeg;

  /// The next transit leg after this one (skipping walks), if any — used to
  /// score this leg's Anschluss (probability of catching the following train).
  final JourneyLeg? nextTransitLeg;

  /// Live minutes available for the transfer INTO this train (null = first leg
  /// / unknown), when you'll realistically be ready, and the change station —
  /// drive the at-risk "next reachable train" offer in the leg switcher.
  final int? incomingGapMinutes;
  final DateTime? readyAt;
  final String? transferStationName;

  const _LegSection({
    super.key,
    required this.leg,
    required this.index,
    this.onTripUpdated,
    this.onReplaceLeg,
    this.nextTransitLeg,
    this.incomingGapMinutes,
    this.readyAt,
    this.transferStationName,
  });

  @override
  ConsumerState<_LegSection> createState() => _LegSectionState();
}

class _LegSectionState extends ConsumerState<_LegSection>
    with AutomaticKeepAliveClientMixin, WidgetsBindingObserver {
  Trip? _trip;
  CoachSequence? _coach;
  bool _loading = true;

  /// Lets the whole-block swipe hand its fling to the switcher's step logic,
  /// so grabbing the Fahrtblock anywhere cycles departures the same way the
  /// little switcher bar does.
  final _switcherKey = GlobalKey<LegAlternativeSwitcherState>();

  /// One-shot timer that re-fetches this leg's live data shortly before the
  /// train's next stop, then re-arms itself. Stop-aligned beats constant polling:
  /// the data only changes around stops, so that's when we refresh.
  Timer? _refreshTimer;

  // Keep the leg alive when scrolled off-screen → no dispose, no re-fetch,
  // no UI rebuild when scrolling back to it.
  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Coming back to the foreground → refresh now and re-arm.
      final id = widget.leg.tripId;
      if (id != null && mounted) _fetchFresh(id, silent: true);
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _refreshTimer?.cancel(); // never fetch while backgrounded
    }
  }

  /// Schedule the next silent re-fetch ~60 s before the train's next stop event,
  /// clamped to [30 s, 10 min]. Re-armed after every fetch (success or failure,
  /// using the freshest trip we hold). No future stop ⇒ the run is over ⇒ stop.
  void _scheduleNextRefresh(Trip trip) {
    _refreshTimer?.cancel();
    final id = widget.leg.tripId;
    if (id == null) return;
    final now = DateTime.now();
    DateTime? nextEvent;
    for (final so in trip.stopovers) {
      final t = so.departure ??
          so.plannedDeparture ??
          so.arrival ??
          so.plannedArrival;
      if (t != null && t.isAfter(now)) {
        nextEvent = t;
        break;
      }
    }
    if (nextEvent == null) return;
    var delay = nextEvent.difference(now) - const Duration(seconds: 60);
    if (delay < const Duration(seconds: 30)) delay = const Duration(seconds: 30);
    if (delay > const Duration(minutes: 10)) delay = const Duration(minutes: 10);
    _refreshTimer = Timer(delay, () {
      if (mounted) _fetchFresh(id, silent: true);
    });
  }

  @override
  void didUpdateWidget(_LegSection old) {
    super.didUpdateWidget(old);
    // The leg was swapped for a different departure → reload its train detail.
    if (widget.leg.tripId != old.leg.tripId) {
      setState(() {
        _trip = null;
        _coach = null;
        _loading = true;
      });
      _load();
    }
  }

  Future<void> _load() async {
    final id = widget.leg.tripId;
    if (id == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    // Serve cached data instantly, then refresh silently in the background.
    final cached = _tripCache[id];
    if (cached != null) {
      _trip = cached;
      _coach = _coachCache[id];
      _loading = false;
    }
    await _fetchFresh(id, silent: cached != null);
  }

  Future<void> _fetchFresh(String id, {required bool silent}) async {
    final leg = widget.leg;
    // Fire trip and coach sequence in parallel — they were sequential, ~doubling
    // the wait before the live location renders. Each side handles its own
    // failure so one slow call doesn't block the other.
    final tripFuture = ref.read(hafasServiceProvider).getTrip(id);
    final coachFuture = ref
        .read(coachSequenceServiceProvider)
        .getCoachSequenceForDeparture(
          category: leg.line?.productName ?? '',
          trainNumber: leg.line?.fahrtNr ?? '',
          stationEva: leg.origin.id,
          departureTime: leg.departure,
        )
        .catchError((_) => null);
    try {
      var trip = await tripFuture;
      // The `fahrt` API drops the line label ("RE7"); the journey leg still has
      // it, so carry it in → header shows "RE 7 (11281)", not the bare number.
      final label = leg.line?.name.trim() ?? '';
      if (label.isNotEmpty) {
        trip = trip.copyWith(line: trip.line.withName(label));
      }
      _tripCache[id] = trip;
      if (mounted) setState(() => _trip = trip);
      // Post-await (never during build) → safe to nudge the parent to recompute
      // transfer windows from the live arrival/departure this fetch just added.
      widget.onTripUpdated?.call();
    } catch (_) {/* keep cached/fallback */}
    try {
      final cs = await coachFuture;
      if (cs != null) {
        _coachCache[id] = cs;
        if (mounted) setState(() => _coach = cs);
      }
    } catch (_) {/* optional */}
    if (mounted && !silent) setState(() => _loading = false);
    // Re-arm the stop-aligned refresh from the freshest trip we hold.
    if (mounted && _trip != null) _scheduleNextRefresh(_trip!);
  }


  void _openStopMap(Stopover stop) {
    if (stop.stop.name.isEmpty) return;
    final leg = widget.leg;

    // On a wing train, when this is the stop you board at, narrow the map's
    // section highlight to the portion bound for YOUR destination (e.g. just
    // "I"), not the whole train's range — and label it on the map banner.
    ({String start, String end})? sectionOverride;
    String? transferNote;
    final coach = _coach;
    final isLegBoarding =
        (stop.stop.id.isNotEmpty && stop.stop.id == leg.origin.id) ||
            (stop.stop.name.isNotEmpty && stop.stop.name == leg.origin.name);
    if (coach != null && coach.splits && isLegBoarding) {
      final portion = coach.portionTo(leg.destination.name);
      final range = portion?.sectorRange;
      if (range != null) {
        sectionOverride = range;
        final sec = range.start == range.end
            ? 'Abschnitt ${range.start}'
            : 'Abschnitt ${range.start}–${range.end}';
        transferNote = 'Zugteil Richtung ${leg.destination.name} · $sec';
      }
    }

    ref.read(stationMapProvider.notifier).loadForStation(
          stop.stop,
          highlightGleis: stop.platform,
          role: stop.isTerminus
              ? GleisRole.alight
              : stop.isOrigin
                  ? GleisRole.board
                  : GleisRole.none,
          sectionOverride: sectionOverride,
          // The Wagenreihung is for this leg's boarding stop, so only hand it to
          // the map there — drawing it on a later stop's platform would be wrong.
          // Draw the train on EVERY stop's platform (not just boarding): the
          // map fetches this train's Wagenreihung for this stop itself.
          coachRef: (leg.line?.fahrtNr != null && leg.line!.fahrtNr.isNotEmpty)
              ? (
                  category: leg.line?.productName ?? '',
                  trainNumber: leg.line!.fahrtNr,
                  time: stop.departure ?? stop.arrival,
                )
              : null,
          // The leg's composition (fetched at its origin) — the fallback so we
          // can still draw the train at a stop the per-station Wagenreihung
          // endpoint doesn't serve (a regional train's terminus/Ausstieg 404s).
          fallbackCoachSequence: coach,
          // Also hand the leg's ORIGIN ref so the map can fetch the composition
          // itself even when [coach] wasn't preloaded — the origin departure is
          // a stop the vehicle-sequence endpoint always serves.
          fallbackRef: (leg.line?.fahrtNr != null && leg.line!.fahrtNr.isNotEmpty)
              ? (
                  category: leg.line?.productName ?? '',
                  trainNumber: leg.line!.fahrtNr,
                  originEva: leg.origin.id,
                  departureTime: leg.departure,
                )
              : null,
          product: leg.line?.product,
          trainLabel: leg.line?.name,
          transferNote: transferNote,
          primaryTypes: primaryPoiTypesForProduct(leg.line?.product),
        );
    context.push('/station-map');
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // required by AutomaticKeepAliveClientMixin
    final trip = _trip;
    if (trip != null) {
      final leg = widget.leg;
      // Swipe/step control to cycle this segment's other departures and swap
      // the train in place. Only when a swap target exists (onReplaceLeg) and
      // it's a real train leg.
      final switcher = (widget.onReplaceLeg != null &&
              !leg.isWalking &&
              leg.line != null)
          ? LegAlternativeSwitcher(
              key: _switcherKey,
              leg: leg,
              index: widget.index,
              onReplace: widget.onReplaceLeg!,
              incomingGapMinutes: widget.incomingGapMinutes,
              readyAt: widget.readyAt,
              transferStationName: widget.transferStationName,
            )
          : null;
      final detail = TrainDetailView(
        trip: trip,
        coach: _coach,
        onStopTap: _openStopMap,
        boardingId:
            leg.origin.id.isNotEmpty ? leg.origin.id : leg.origin.name,
        alightingId: leg.destination.id.isNotEmpty
            ? leg.destination.id
            : leg.destination.name,
        // No header buttons: the alternative-departure arrows live in the
        // switcher bar below (no doubled "Weitere Abfahrten" button), and
        // Träwelling check-in is automatic on save for every train leg.
        predictionStrip: (!leg.isWalking && leg.line != null)
            ? LegPredictionBadge(leg: leg, nextLeg: widget.nextTransitLeg)
            : null,
        legDestinationName:
            leg.destination.name.isNotEmpty ? leg.destination.name : null,
      );
      if (switcher == null) return detail;
      // The ENTIRE Fahrtblock is the swipe surface: grab anywhere on the block
      // and fling sideways to cycle this segment's other departures (left →
      // later, right → earlier). The handler reuses the switcher's own step
      // logic. onHorizontalDragEnd yields to vertical list scroll (other axis),
      // so paging the connection still works untouched.
      return GestureDetector(
        onHorizontalDragEnd: (d) => _switcherKey.currentState
            ?.handleHorizontalFling(d.primaryVelocity ?? 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [switcher, detail],
        ),
      );
    }
    // Loading / fallback: getTrip can fail for non-DB-operated trains (ÖBB
    // Railjet, Flixtrain, a Fernbus) — still show the leg with the SAME circled
    // product badge as the live header, built from the leg's own line data, so
    // every product gets its "[RJX] 69"-style badge, not just RE/ICE.
    final leg = widget.leg;
    final line = leg.line;
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: ListTile(
        leading: _loading
            ? const SizedBox(
                width: 20, height: 20,
                child: CircularProgressIndicator(strokeWidth: 2))
            : (line != null
                ? ProductBadge(label: line.productBadge)
                : const Icon(Icons.train)),
        title: Text(line != null ? line.lineNumberWithFahrt : 'Zug'),
        subtitle: Text(
            '${leg.origin.name} → ${leg.destination.name}'
            '${leg.direction != null ? '  ·  Richtung ${leg.direction}' : ''}'),
      ),
    );
  }
}

/// Collapsed leg notices (lift out of service, "fährt mit anderem Fahrzeug", …).
/// These are low-value most of the time, so they sit behind a single tap — out
/// of the way until the rider actually wants them. The wing-train split note is
/// filtered out upstream (the red banner covers it). Renders nothing when empty.
class _LegNotes extends StatefulWidget {
  final List<String> notes;
  const _LegNotes({required this.notes});

  @override
  State<_LegNotes> createState() => _LegNotesState();
}

class _LegNotesState extends State<_LegNotes> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final notes = widget.notes;
    if (notes.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _open = !_open),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  Icon(Icons.info_outline, size: 15, color: muted),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _open
                          ? 'Hinweise ausblenden'
                          : '${notes.length} ${notes.length == 1 ? 'Hinweis' : 'Hinweise'}',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: muted, fontWeight: FontWeight.w600),
                    ),
                  ),
                  Icon(_open ? Icons.expand_less : Icons.expand_more,
                      size: 18, color: muted),
                ],
              ),
            ),
          ),
          if (_open)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final n in notes)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('•', style: TextStyle(color: muted)),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(n,
                                style: theme.textTheme.bodySmall
                                    ?.copyWith(color: muted)),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
