import 'dart:async';

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/app_log.dart';
import '../../core/extensions.dart';
import '../../core/missed_connection.dart';
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
import '../../providers/journey_search_provider.dart';
import '../../providers/service_providers.dart';
import '../../providers/settings_provider.dart';
import '../../providers/split_ticket_provider.dart';
import '../../providers/station_map_provider.dart';
import '../../services/db_api_service.dart';
import '../../services/notification_service.dart';
import '../../theme/app_colors.dart';
import '../../widgets/ui/message_card.dart';
import '../../utils/earlier_alight.dart';
import '../../utils/leg_swap.dart';
import '../../utils/split_stops.dart';
import '../../widgets/departure_card.dart';
import '../../widgets/fahrgastrechte_card.dart';
import '../../widgets/offline_package_bar.dart';
import '../../widgets/prediction_badge.dart';
import '../../widgets/product_badge.dart';
import '../../widgets/trip_progress_inline.dart';
import '../../widgets/trwl_checkin_sheet.dart';
import '../train_lookup/widgets/train_detail_view.dart';
import 'widgets/leg_switcher.dart';
import 'widgets/transfer_coach_hint.dart';

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

  /// Opened straight from a result list, so the alternatives are literally one
  /// back-tap away. "Alternative Verbindungen" then just re-runs the search the
  /// user came from — a second back button (#25). It stays for the ways in that
  /// have NO results behind them: the Reisen tab, a ticket, a saved trip.
  final bool fromSearch;

  const ConnectionDetailScreen({
    super.key,
    required this.journey,
    this.ticketRef,
    this.fromSearch = false,
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

  /// Take [next] as the itinerary on screen — and, if this trip is saved,
  /// carry the saved entry over to it.
  ///
  /// Every leg swap used to live only in this screen's state, so the library
  /// kept the itinerary as originally saved: reminders, live companion and
  /// background tracking all went on alerting for the train the rider had just
  /// swapped away (#58).
  void _adoptJourney(Journey next, {bool refresh = false}) {
    final oldKey = SavedJourney(journey: _journey, savedAtMs: 0).key;
    setState(() {
      _journey = next;
      if (refresh) _refreshTick++;
    });
    ref.read(libraryProvider.notifier).replaceJourney(oldKey, next);
  }

  /// Swap leg [index] for [newLeg] picked from "Weitere Abfahrten".
  void _replaceLeg(int index, JourneyLeg newLeg) {
    final legs = List<JourneyLeg>.of(_journey.legs);
    if (index < 0 || index >= legs.length) return;
    final old = legs[index];
    legs[index] = newLeg;
    _adoptJourney(Journey(legs: legs)); // price/refreshToken intentionally dropped

    // Taking a later (or earlier) train on Kiel→München does not only change
    // that leg — everything behind it moves with it. The old onward legs
    // describe trains that have long gone, or that the rider now waits an hour
    // for, so they are re-planned from the new arrival (#55-Umstieg).
    final newArrival = newLeg.arrival ?? newLeg.plannedArrival;
    if (tailNeedsReplan(legs, index,
        oldArrival: old.arrival ?? old.plannedArrival,
        newArrival: newArrival)) {
      _replanTail(index, newArrival!);
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        duration: Duration(seconds: 3),
        content: Text('Fahrt ersetzt · Preis ggf. neu suchen'),
      ),
    );
  }

  /// Re-plan everything after leg [index] from [arrival] onwards.
  ///
  /// One search from that leg's destination to the journey's own destination.
  /// Failure keeps the itinerary as swapped and says so — a stale tail the
  /// rider can see beats silently pretending the swap didn't happen, but it
  /// must not pass as a checked connection either.
  Future<void> _replanTail(int index, DateTime arrival) async {
    final legs = List<JourneyLeg>.of(_journey.legs);
    final from = legs[index].destination;
    final to = journey.destination;
    if (to == null ||
        from.vendoLocationId.isEmpty ||
        to.vendoLocationId.isEmpty) {
      _snack('Fahrt ersetzt · Anschlüsse dahinter bitte prüfen');
      return;
    }
    setState(() => _replanning = true);
    _snack('Fahrt ersetzt · Anschlüsse werden neu gesucht …');
    try {
      final settings = ref.read(settingsProvider);
      final res = await ref.read(vendoServiceProvider).searchJourneys(
            fromLocationId: from.vendoLocationId,
            toLocationId: to.vendoLocationId,
            dateTime: arrival,
            reisende: settings.searchParty.toReisendeJson(),
            deutschlandTicket: settings.hasDeutschlandTicket,
          );
      final onward = firstBoardable(res.journeys, arrival);
      if (!mounted) return;
      setState(() => _replanning = false);
      if (onward == null || onward.legs.isEmpty) {
        _snack('Keine Anschlüsse ab ${from.name} gefunden — bitte prüfen');
        return;
      }
      _adoptJourney(Journey(legs: spliceTail(legs, index, onward)),
          refresh: true);
      final arr = onward.arrival ?? onward.plannedArrival;
      _snack('Anschlüsse neu gesucht'
          '${arr != null ? ' · Ankunft ${arr.hhmm}' : ''}');
    } catch (e) {
      AppLog.log('replan after leg swap failed: $e', tag: 'trip-detail');
      if (!mounted) return;
      setState(() => _replanning = false);
      _snack('Anschlüsse konnten nicht neu gesucht werden — bitte prüfen');
    }
  }

  /// True while [_replanTail] is running — the legs behind the swap are shown
  /// as provisional until it lands.
  bool _replanning = false;

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        duration: const Duration(seconds: 4),
        content: Text(text),
      ));
  }

  /// Rescue option B for the transfer into leg [i] (#26): what the switcher
  /// needs to offer getting off [prev] earlier and going another way.
  ///
  /// Null when there's no train to get off (first leg) or no known
  /// destination. The stop list is built HERE because only this screen holds
  /// the trip cache — the freshest live times of the ridden train, re-fetched
  /// around every stop, versus the search's realtime snapshot.
  EarlierAlightInput? _earlierAlightInput(
      List<JourneyLeg> legs, int i, JourneyLeg? prev) {
    if (prev == null) return null;
    final destination = journey.destination;
    if (destination == null || destination.vendoLocationId.isEmpty) return null;
    final prevIndex = legs.indexOf(prev);
    if (prevIndex < 0) return null;
    final trip = prev.tripId != null ? _tripCache[prev.tripId] : null;
    final stops = alightStopsOfLeg(prev, trip: trip);
    if (stops.length < 3) return null; // no stop between board and change
    return EarlierAlightInput(
      journey: journey,
      currentLeg: prev,
      currentLegIndex: prevIndex,
      stops: stops,
      destination: destination,
      onApply: (option) => _applyEarlierAlight(prevIndex, option),
    );
  }

  /// Take a "get off earlier" suggestion: cut the ridden train short at the
  /// new exit and graft the found route on.
  ///
  /// Same deal as [_replaceLeg] — the price/recon of the booked journey no
  /// longer describe what's on screen, so they're dropped and said so. The
  /// ticket warning is repeated here on purpose: this is the moment the rider
  /// commits to leaving a possibly train-bound fare behind.
  void _applyEarlierAlight(int currentLegIndex, EarlierAlightOption option) {
    final legs = rerouteViaEarlierAlight(
      legs: _journey.legs,
      currentLegIndex: currentLegIndex,
      option: option,
    );
    if (legs == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Route konnte nicht übernommen werden.'),
      ));
      return;
    }
    // price/refreshToken intentionally dropped
    _adoptJourney(Journey(legs: legs), refresh: true);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      duration: const Duration(seconds: 5),
      content: Text(
        'Neue Route ab ${option.stop.station.name}'
        '${option.ticketNote == AlightTicketNote.dTicketCovered ? '' : ' · ${option.ticketNote.label}'}',
      ),
    ));
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
    final missed = MissedConnectionRescue.forJourney(journey);
    return Scaffold(
      appBar: AppBar(
        // Full route is cut off on a phone here → moved into the summary block.
        title: Text(ticketRef != null ? 'Reiseplan' : 'Verbindung'),
        actions: [
          // For a booked ticket: prominent "Ticket" action top-right. The
          // BahnCard quick-jump lives on the Ticket view itself, not here —
          // one tap deeper but keeps the Reiseplan AppBar uncluttered.
          if (ticketRef != null)
            IconButton(
              icon: const Icon(Icons.qr_code_2),
              tooltip: 'Ticket anzeigen',
              onPressed: () =>
                  context.push('/ticket-view', extra: ticketRef),
            ),
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
          if (!widget.fromSearch)
            IconButton(
              icon: const Icon(Icons.alt_route),
              // Says what it does: this starts a NEW search for the same route
              // and time. "Alternative Verbindungen" read like an in-place
              // feature (#25).
              tooltip: 'Andere Fahrten für diese Strecke suchen',
              onPressed: () => _showAlternatives(context, ref),
            ),
          IconButton(
            icon: const Icon(Icons.call_split),
            tooltip: 'Split-Ticket suchen',
            onPressed: () => _openSplitTicket(context, ref),
          ),
          // "Reise überwachen" — per-trip live tracking, only offered once the
          // trip is saved locally (there's nothing to track otherwise, and the
          // tracker reads the local library). Explicit and trip-scoped, per
          // the privacy ask in #11.
          Builder(builder: (context) {
            final key = SavedJourney(journey: journey, savedAtMs: 0).key;
            final lib = ref.watch(libraryProvider);
            if (!lib.hasJourney(key)) return const SizedBox.shrink();
            final watched =
                ref.read(libraryProvider.notifier).isJourneyWatched(key);
            return IconButton(
              icon: Icon(watched
                  ? Icons.notifications_active
                  : Icons.notifications_off_outlined),
              tooltip: watched
                  ? 'Benachrichtigungen aktiv — antippen zum Ausschalten'
                  : 'Diese Reise überwachen',
              onPressed: () {
                ref
                    .read(libraryProvider.notifier)
                    .setJourneyWatched(key, !watched);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    duration: const Duration(seconds: 3),
                    content: Text(watched
                        ? 'Benachrichtigungen für diese Reise aus.'
                        : 'Benachrichtigungen an: Erinnerungen, Verspätung, '
                            'Gleiswechsel, Ausfall & Anschluss.'),
                  ),
                );
                if (!watched) NotificationService.requestPermissions();
              },
            );
          }),
          Builder(builder: (context) {
            final key =
                SavedJourney(journey: journey, savedAtMs: 0).key;
            // A trip saved to the DB account but no longer in the local
            // library still IS saved — showing an empty bookmark there made it
            // un-removable, and tapping it created a *second* DB trip (#15).
            final saved = ref.watch(libraryProvider).hasJourney(key) ||
                ref.watch(dbSavedReiseIdsProvider).containsKey(key);
            return IconButton(
              icon: Icon(saved ? Icons.bookmark : Icons.bookmark_border),
              tooltip: saved ? 'Reise entfernen' : 'Reise speichern',
              onPressed: () {
                final wasSaved = saved;
                // Explicit add/remove, not toggle: when the trip is saved in
                // the DB account but absent locally, a local toggle would ADD
                // it — the opposite of what the filled bookmark promises.
                if (wasSaved) {
                  ref.read(libraryProvider.notifier).removeJourney(key);
                } else {
                  ref.read(libraryProvider.notifier).toggleJourney(journey);
                }
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
          // Offline, the legs below are replayed from this journey's package
          // (see the fallbacks in HafasService/CoachSequenceService/
          // StationMapService). Say how old they are — cached data presented
          // without its age is exactly what makes people distrust it (#29).
          OfflineDataNotice(
            journeyKey: SavedJourney(journey: journey, savedAtMs: 0).key,
          ),
          if (journey.hasCancelledLeg)
            const _JourneyCancelBanner(partial: false)
          else if (journey.hasPartialCancellation)
            const _JourneyCancelBanner(partial: true),
          // Notes about the connection as a whole, above the legs because they
          // can be the only place saying what changed ("Der Zielhalt Berlin
          // Hbf entfällt. Ausstieg in Berlin-Spandau möglich.") — the legs
          // themselves sometimes carry nothing.
          _LegNotes(notes: _visibleNotes(journey.disruptions)),
          _serviceDays(context),
          _buyButton(context, ref),
          // Live companion cards (each self-hides when not applicable):
          // Fahrgastrechte claim on a 60+ min late arrival, and one combined
          // pre-departure card (countdown + "wann musst du los") that
          // disappears once the train has left. The on-board progress lives
          // folded into the summary block above (TripProgressInline).
          FahrgastrechteCard(journey: journey),
          DepartureCard(journey: journey),
          if (missed != null)
            _MissedConnectionCard(
              rescue: missed,
              onPressed: () =>
                  _showMissedAlternatives(context, ref, missed),
            ),
          // The legs behind a swapped one are the OLD plan until the re-search
          // lands — say so rather than let them read as checked (#55-Umstieg).
          if (_replanning)
            const MessageCard(
              tone: MessageTone.info,
              body: 'Anschlüsse werden für die neue Ankunft gesucht …',
            ),
          for (var i = 0; i < legs.length; i++) ...[
            if (i > 0) _transfer(context, ref, legs[i - 1], legs[i]),
            if (legs[i].isWalking)
              _walkLeg(context, ref, legs[i],
                  i > 0 ? legs[i - 1] : null,
                  i + 1 < legs.length ? legs[i + 1] : null)
            else ...[
              // Which section of the train you're ON to be in, so the change
              // here is a step across the platform (#27). Sits right under the
              // transfer tile — vendo models the change as a FUSSWEG leg, so
              // that tile is the walk rendered at i-1. Self-hides unless both
              // Wagenreihungen back it up.
              Builder(builder: (_) {
                final prev = _prevTransitLeg(legs, i);
                if (prev == null) return const SizedBox.shrink();
                return TransferCoachHint(
                  key: ValueKey('coach-hint-${prev.tripId}-${legs[i].tripId}'),
                  arriving: prev,
                  departing: legs[i],
                  samePlatform: journey.samePlatformTransferInto(legs[i]),
                );
              }),
              if (legs[i].cancelled ||
                  legs[i].partiallyCancelled ||
                  legs[i].endsEarly)
                _LegCancelBanner(leg: legs[i]),
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
                  samePlatformTransfer: journey.samePlatformTransferInto(legs[i]),
                  earlierAlight: _earlierAlightInput(legs, i, prev),
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
        // Already mirrored to the DB account? Then saving again would create a
        // second, identical trip — which is how the same journey ended up
        // listed several times in the Reisen tab (#15).
        if (ids.lookup(key) != null) return;
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
      // Refresh the SOURCE: ticketIndicesProvider is derived from the overview,
      // so invalidating it re-read the same in-memory data and the tab never
      // changed. It's also the wrong list — saved trips are reiseIndizes, not
      // bought orders.
      await ref.read(reisenuebersichtProvider.notifier).refresh();
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
        // The refreshed per-leg runs we already hold → live arrival platform/time
        // (a Gleiswechsel/delay the search snapshot missed, #50).
        text: etaShareText(journey, link, live: _tripCache),
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
  /// "Alternative Verbindungen": re-run a normal journey search for the same
  /// origin → destination around this connection's departure, then jump to the
  /// Suche tab where the results render. No login / no booked-trip needed — the
  /// account-bound `mob/reisen/{id}/alternativen` endpoint isn't required; a
  /// fresh Vendo search from the same stops IS the alternatives list.
  void _showAlternatives(BuildContext context, WidgetRef ref) {
    final from = journey.origin;
    final to = journey.destination;
    if (from == null || to == null || from.id.isEmpty || to.id.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Keine Alternativen — Start/Ziel unbekannt.'),
      ));
      return;
    }
    final n = ref.read(journeySearchProvider.notifier);
    n.setFrom(from);
    n.setTo(to);
    n.setDateTime(journey.plannedDeparture ?? journey.departure);
    n.setIsArrival(false);
    context.go('/search');
    n.search();
  }

  /// Reroute from the specific boarding stop that was missed, not from the
  /// journey's original origin. The same action therefore also works halfway
  /// through a journey after a missed connection.
  void _showMissedAlternatives(
    BuildContext context,
    WidgetRef ref,
    MissedConnectionRescue rescue,
  ) {
    // Declaring the train missed ends this itinerary — silence it before
    // leaving, or its reminders and live alerts keep arriving next to the
    // replacement the rider is about to pick (#58). The trip stays saved, so
    // the bell in its Reiseplan turns the alerts back on if it was a misfire.
    final key = SavedJourney(journey: journey, savedAtMs: 0).key;
    final library = ref.read(libraryProvider.notifier);
    if (ref.read(libraryProvider).hasJourney(key)) {
      library.setJourneyWatched(key, false);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        duration: Duration(seconds: 4),
        content: Text('Benachrichtigungen für diese Reise aus.'),
      ));
    }
    final n = ref.read(journeySearchProvider.notifier);
    n.setFrom(rescue.from);
    n.setTo(rescue.to);
    n.setDateTime(DateTime.now().add(const Duration(minutes: 1)));
    n.setIsArrival(false);
    context.go('/search');
    n.search();
  }

  void _openSplitTicket(BuildContext context, WidgetRef ref) {
    // Same candidate list the bulk comparison uses, so both price identically.
    // This screen additionally has the leg's full train run cached, which is
    // handed over — trimmed to the ridden section, never the whole run (#22).
    final stops = splitStopsFromJourney(
      journey,
      tripFor: (leg) => leg.tripId != null ? _tripCache[leg.tripId] : null,
    );

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

  /// When this connection doesn't run, in DB's words (#20, point 8) — e.g.
  /// "nicht 22. Aug bis 4. Sep 2026".
  ///
  /// Neutral on purpose, and it says "diese Verbindung": the day you searched
  /// is always a day it runs, so this is for planning the *next* trip or
  /// re-booking, not a warning about this one. Toned as information, not as a
  /// disruption — it isn't one.
  Widget _serviceDays(BuildContext context) {
    final note = journey.serviceDaysNote;
    if (note == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.event_repeat,
              size: 16, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              // "Verkehrstage" is DB's own label, and it stays grammatical for
              // both shapes the string takes: a bare "nicht 20. Jul bis 11.
              // Sep" and a period with exceptions ("16. Jul bis 30. Okt;
              // nicht 22. Aug bis 4. Sep").
              'Verkehrstage dieser Verbindung: $note',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }

  /// Tone for an available transfer time: red ≤2 min (Anschluss gefährdet),
  /// amber ≤5, else null (normal). Returns (textColor, warningText).
  ///
  /// [samePlatform] is DB's `weiterfahrtAmGleichenBahnsteig` (#20, point 6):
  /// the next train leaves from the platform you're standing on. 3 minutes is
  /// then genuinely enough, so the amber "knapp" hint would be noise — but a
  /// train you cannot physically reach (≤2 min) stays red either way.
  (Color?, String?) _transferTone(BuildContext context, int? mins,
      {bool samePlatform = false}) {
    if (mins == null) return (null, null);
    if (mins <= 2) {
      return (Theme.of(context).colorScheme.error,
          'Anschluss evtl. nicht erreichbar');
    }
    if (mins <= 5 && !samePlatform) return (const Color(0xFFCC8800), null);
    return (null, null);
  }

  /// The second line of a transfer tile: what the change actually involves.
  ///
  /// DB's own words where it has them (#20, point 6) — "gleicher Bahnsteig"
  /// when it says so, and the real walking time when the walk crosses between
  /// stations ("12 min Zeit, davon 7 min Fußweg"). It only sends those for
  /// inter-station walks; within one station there's nothing but the window
  /// itself, so the tile stays at the plain "mit Fußweg" it had.
  String _walkDetail(JourneyLeg leg) {
    final parts = <String>[
      if (leg.samePlatformTransfer)
        'gleicher Bahnsteig'
      else
        'mit Fußweg',
      if (leg.walkingDuration != null)
        '${leg.walkingDuration!.inMinutes} min Weg',
      if (leg.walkingDistance != null) '${leg.walkingDistance} m',
    ];
    return parts.join(' · ');
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

  /// Freshest arrival Gleis of [leg] at its destination — the live `ezGleis`
  /// from the refreshed run, not the platform the search happened to return.
  /// A Gleiswechsel announced after the search otherwise kept the old number
  /// on the transfer row and on the platform-to-platform map (#50).
  String? _livePlatformAtArrival(JourneyLeg leg) {
    final trip = leg.tripId != null ? _tripCache[leg.tripId] : null;
    final so = trip != null ? _stopFor(trip, leg.destination) : null;
    return so?.platform ?? leg.arrivalPlatform;
  }

  /// Freshest departure Gleis of [leg] at its origin — see above.
  String? _livePlatformAtDeparture(JourneyLeg leg) {
    final trip = leg.tripId != null ? _tripCache[leg.tripId] : null;
    final so = trip != null ? _stopFor(trip, leg.origin) : null;
    return so?.platform ?? leg.departurePlatform;
  }

  /// The planned Gleis this leg leaves from, when it differs from the live one
  /// — i.e. there was a Gleiswechsel and we can name what it used to be.
  String? _changedFromPlatform(JourneyLeg leg, String? live) {
    final planned = leg.plannedDeparturePlatform ?? leg.departurePlatform;
    if (live == null || planned == null || planned == live) return null;
    return planned;
  }

  /// A FUSSWEG leg between two trains. The headline number is the *time you
  /// have* to change (arrival → next departure), NOT how long the walk takes;
  /// the walk itself is shown as the secondary detail.
  Widget _walkLeg(BuildContext context, WidgetRef ref, JourneyLeg leg,
      JourneyLeg? prev, JourneyLeg? next) {
    // Available transfer time: from the train's arrival to the next departure.
    // Use the freshest (live) times so a delay shrinks the window; strike the
    // scheduled value when it no longer holds. The leg's own
    // `verfuegbareZeit` says the same thing, but only for the planned times —
    // it can't know about today's delay, so it stays out of the headline.
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
    final (color, warn) =
        _transferTone(context, shown, samePlatform: leg.samePlatformTransfer);

    final head = shown != null ? '$shown min zum Umsteigen' : 'Umstieg';
    // Which Gleis you arrive on and which one you leave from — live, and
    // saying so when it changed. Vendo models nearly every transfer as this
    // FUSSWEG leg, so without it the Gleiswechsel at a change was nowhere on
    // the Reiseplan (#50).
    final arrG = prev != null ? _livePlatformAtArrival(prev) : null;
    final depG = next != null ? _livePlatformAtDeparture(next) : null;
    final wasG = next != null ? _changedFromPlatform(next, depG) : null;
    final gleise = (arrG != null || depG != null)
        ? 'Gleis ${arrG ?? '?'} → Gleis ${depG ?? '?'}'
            '${wasG != null ? ' (statt $wasG)' : ''}'
        : null;
    final detail = [?gleise, _walkDetail(leg)].join(' · ');

    return _transferTile(
      context,
      icon: leg.samePlatformTransfer
          ? Icons.swap_horiz
          : Icons.directions_walk,
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
                // Live Gleise (#50) — see [_livePlatformAtArrival].
                prev != null ? _livePlatformAtArrival(prev) : null,
                next != null ? _livePlatformAtDeparture(next) : null,
                // Einstieg (primary) = the departing/next train; Ausstieg
                // (secondary) = the arriving/prev train — each drawn to scale.
                // SCHEDULED times throughout: the Wagenreihung is keyed by
                // service date, and a live time that has slipped past midnight
                // asks for the next day's run (#32).
                depRef: (next?.line?.fahrtNr.isNotEmpty ?? false)
                    ? (
                        category: next!.line?.productName ?? '',
                        trainNumber: next.line!.fahrtNr,
                        time: next.plannedDeparture ?? next.departure,
                      )
                    : null,
                arrRef: (prev?.line?.fahrtNr.isNotEmpty ?? false)
                    ? (
                        category: prev!.line?.productName ?? '',
                        trainNumber: prev.line!.fahrtNr,
                        time: prev.plannedArrival ?? prev.arrival,
                      )
                    : null,
                // ORIGIN refs → each train's real composition, fetched at its
                // origin departure (a stop the sequence endpoint always serves).
                depFallbackRef: (next?.line?.fahrtNr.isNotEmpty ?? false)
                    ? (
                        category: next!.line?.productName ?? '',
                        trainNumber: next.line!.fahrtNr,
                        originEva: next.origin.id,
                        departureTime: next.plannedDeparture ?? next.departure,
                      )
                    : null,
                arrFallbackRef: (prev?.line?.fahrtNr.isNotEmpty ?? false)
                    ? (
                        category: prev!.line?.productName ?? '',
                        trainNumber: prev.line!.fahrtNr,
                        originEva: prev.origin.id,
                        departureTime: prev.plannedDeparture ?? prev.departure,
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
    ref.read(dedicatedStationMapProvider.notifier).loadForStation(
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

    // Live Gleise (#50): a Gleiswechsel announced after the search must show
    // here and on the map this row opens, not the number the search returned.
    final arrGleis = _livePlatformAtArrival(prev);
    final depGleis = _livePlatformAtDeparture(next);
    final wasGleis = _changedFromPlatform(next, depGleis);
    final station = prev.destination;
    // Vendo models every transfer as a FUSSWEG leg, so this path is for the
    // other sources; the flag rides on the arriving side there.
    final samePlatform = next.samePlatformTransfer;
    final (color, warn) =
        _transferTone(context, shown, samePlatform: samePlatform);

    // "Gleis 4 → Gleis 5" reads like a hike; DB knows 4 and 5 are two sides of
    // one island platform and says so.
    final gleisText = (arrGleis != null || depGleis != null)
        ? 'Gleis ${arrGleis ?? '?'} → Gleis ${depGleis ?? '?'}'
            '${wasGleis != null ? ' (statt $wasGleis)' : ''}'
            '${samePlatform ? ' · gleicher Bahnsteig' : ''}'
        : (samePlatform ? 'gleicher Bahnsteig' : null);

    return _transferTile(
      context,
      icon: samePlatform ? Icons.swap_horiz : Icons.swap_calls,
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
                // Scheduled times: keyed by service date (#32).
                depFallbackRef: (next.line?.fahrtNr.isNotEmpty ?? false)
                    ? (
                        category: next.line?.productName ?? '',
                        trainNumber: next.line!.fahrtNr,
                        originEva: next.origin.id,
                        departureTime: next.plannedDeparture ?? next.departure,
                      )
                    : null,
                arrFallbackRef: (prev.line?.fahrtNr.isNotEmpty ?? false)
                    ? (
                        category: prev.line?.productName ?? '',
                        trainNumber: prev.line!.fahrtNr,
                        originEva: prev.origin.id,
                        departureTime: prev.plannedDeparture ?? prev.departure,
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

  /// DB says that transfer stays on one platform — the profile then has no
  /// walk to price (#20, point 6).
  final bool samePlatformTransfer;

  /// Everything the "get off earlier and go another way" rescue needs (#26).
  final EarlierAlightInput? earlierAlight;

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
    this.samePlatformTransfer = false,
    this.earlierAlight,
  });

  @override
  ConsumerState<_LegSection> createState() => _LegSectionState();
}

class _LegSectionState extends ConsumerState<_LegSection>
    with AutomaticKeepAliveClientMixin, WidgetsBindingObserver {
  Trip? _trip;
  CoachSequence? _coach;
  bool _loading = true;

  /// Why the last getTrip failed. Kept so the fallback can say *something*
  /// happened and offer a retry, instead of silently degrading (#14).
  Object? _tripError;

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
          // Scheduled, not live: the endpoint keys on the service DATE, which
          // is derived from this DateTime — a delay past midnight would ask for
          // tomorrow's run and 404 (#32).
          departureTime: leg.plannedDeparture ?? leg.departure,
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
      if (mounted) setState(() {
        _trip = trip;
        _tripError = null;
      });
      // Post-await (never during build) → safe to nudge the parent to recompute
      // transfer windows from the live arrival/departure this fetch just added.
      widget.onTripUpdated?.call();
    } catch (e) {
      // Log it: swallowing this silently is what made the rate-limit cause of
      // the fallback card invisible for so long.
      AppLog.log('getTrip failed for $id: $e', tag: 'trip-detail');
      if (mounted) setState(() => _tripError = e);
    }
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
    // Which pole of a bus stop the rider needs is often not printed anywhere,
    // and then the ride itself answers it: the line, where this ride is headed,
    // and the next stop on the run (the direction of travel — buses stop on the
    // right). See `pickPole` (#55).
    final stops = _trip?.stopovers ?? const <Stopover>[];
    final here = stops.indexWhere((s) =>
        (s.stop.id.isNotEmpty && s.stop.id == stop.stop.id) ||
        s.stop.name == stop.stop.name);
    final next = (here >= 0 && here + 1 < stops.length) ? stops[here + 1] : null;
    final nextLat = next?.stop.latitude, nextLon = next?.stop.longitude;

    // On a wing train, when this is the stop you board at, narrow the map's
    // section highlight to the portion bound for YOUR destination (e.g. just
    // "I"), not the whole train's range — and label it on the map banner.
    ({String start, String end})? sectionOverride;
    String? transferNote;
    final coach = _coach;
    final isLegBoarding =
        (stop.stop.id.isNotEmpty && stop.stop.id == leg.origin.id) ||
            (stop.stop.name.isNotEmpty && stop.stop.name == leg.origin.name);
    // Where the RIDER gets off this leg — not the train's terminus. On an
    // intermediate boarding/alighting stop (Büchen for an ICE that starts in
    // Hamburg) the stopover's own isOrigin/isTerminus are both false, so the
    // Gleis came out role-less (grey, no green/red). The leg endpoints are the
    // truth for who boards/alights here. (#50-Karte)
    final isLegAlighting =
        (stop.stop.id.isNotEmpty && stop.stop.id == leg.destination.id) ||
            (stop.stop.name.isNotEmpty &&
                stop.stop.name == leg.destination.name);
    final gleisRole = isLegBoarding
        ? GleisRole.board
        : isLegAlighting
            ? GleisRole.alight
            : GleisRole.none;
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

    ref.read(dedicatedStationMapProvider.notifier).loadForStation(
          stop.stop,
          highlightGleis: stop.platform,
          lineName: leg.line?.name.trim(),
          // Where this ride goes — the run's direction where we have it (a bus
          // headsign names the terminus, not the rider's exit), else the leg's
          // own destination.
          towardsName: (_trip?.direction.trim().isNotEmpty ?? false)
              ? _trip!.direction.trim()
              : leg.destination.name,
          nextStopAt: (nextLat != null && nextLon != null)
              ? LatLng(nextLat, nextLon)
              : null,
          role: gleisRole,
          sectionOverride: sectionOverride,
          // The Wagenreihung is for this leg's boarding stop, so only hand it to
          // the map there — drawing it on a later stop's platform would be wrong.
          // Draw the train on EVERY stop's platform (not just boarding): the
          // map fetches this train's Wagenreihung for this stop itself.
          coachRef: (leg.line?.fahrtNr != null && leg.line!.fahrtNr.isNotEmpty)
              ? (
                  category: leg.line?.productName ?? '',
                  trainNumber: leg.line!.fahrtNr,
                  // Scheduled — keyed by service date, see #32.
                  time: stop.sequenceTime,
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
                  departureTime: leg.plannedDeparture ?? leg.departure,
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
              samePlatformTransfer: widget.samePlatformTransfer,
              readyAt: widget.readyAt,
              transferStationName: widget.transferStationName,
              earlierAlight: widget.earlierAlight,
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
    // getTrip failed or hasn't landed. Before falling back to the bare card,
    // use the stops the journey search already gave us for this leg — a
    // timeline without platforms/occupancy beats a train number alone (#14).
    final leg = widget.leg;
    final line = leg.line;
    if (!_loading && _tripError != null) {
      final degraded = Trip.fromLeg(leg);
      if (degraded != null) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _TripDetailsUnavailable(onRetry: _retryTrip),
            TrainDetailView(
              trip: degraded,
              coach: _coach,
              onStopTap: _openStopMap,
              boardingId:
                  leg.origin.id.isNotEmpty ? leg.origin.id : leg.origin.name,
              alightingId: leg.destination.id.isNotEmpty
                  ? leg.destination.id
                  : leg.destination.name,
              legDestinationName:
                  leg.destination.name.isNotEmpty ? leg.destination.name : null,
            ),
          ],
        );
      }
    }
    // Nothing to build a timeline from (walk, no stops, unknown line): show the
    // leg with the SAME circled product badge as the live header, built from
    // the leg's own line data, so every product gets its "[RJX] 69"-style
    // badge, not just RE/ICE.
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
        trailing: (!_loading && _tripError != null)
            ? IconButton(
                icon: const Icon(Icons.refresh),
                tooltip: 'Details erneut laden',
                onPressed: _retryTrip,
              )
            : null,
      ),
    );
  }

  Future<void> _retryTrip() async {
    setState(() {
      _loading = true;
      _tripError = null;
    });
    await _load();
    if (mounted) setState(() => _loading = false);
  }
}

/// Shown above a timeline rebuilt from the journey search's own stop list,
/// because the live train-run fetch failed. Says what's missing (platforms,
/// occupancy) so a rider doesn't read the absence of a Gleis as "no platform
/// assigned yet", and offers a retry (#14).
class _TripDetailsUnavailable extends StatelessWidget {
  final VoidCallback onRetry;
  const _TripDetailsUnavailable({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      color: scheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        child: Row(
          children: [
            Icon(Icons.cloud_off, size: 18, color: scheme.outline),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Live-Zugdetails nicht geladen — Halte aus der Verbindung, '
                'ohne Gleise und Auslastung.',
                style: TextStyle(fontSize: 12, color: scheme.outline),
              ),
            ),
            TextButton(onPressed: onRetry, child: const Text('Erneut')),
          ],
        ),
      ),
    );
  }
}

/// Top-of-screen banner: the connection as planned can't be travelled because a
/// train fully cancels (red) or drops a stop (amber). Points the rider at the
/// per-Fahrtblock alternative-departure switcher further down.
class _MissedConnectionCard extends StatelessWidget {
  final MissedConnectionRescue rescue;
  final VoidCallback onPressed;

  const _MissedConnectionCard({
    required this.rescue,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      color: colors.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(Icons.directions_run, color: colors.onSecondaryContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    rescue.isConnection
                        ? 'Anschluss nicht geschafft?'
                        : 'Zug nicht geschafft?',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: colors.onSecondaryContainer,
                        ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Neue Verbindungen ab ${rescue.from.name} suchen.',
                    style: TextStyle(color: colors.onSecondaryContainer),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: onPressed,
              child: const Text('Verpasst'),
            ),
          ],
        ),
      ),
    );
  }
}

class _JourneyCancelBanner extends StatelessWidget {
  final bool partial;
  const _JourneyCancelBanner({required this.partial});

  @override
  Widget build(BuildContext context) {
    final title = partial
        ? 'Teilausfall auf dieser Verbindung'
        : 'Diese Verbindung fällt aus';
    final body = partial
        ? 'Auf einem Abschnitt entfällt ein Halt. Prüfe die markierten '
            'Halte und weiche bei Bedarf auf eine andere Abfahrt aus.'
        : 'Mindestens ein Zug dieser Verbindung fährt nicht. Wische über den '
            'betroffenen Fahrtblock oder tippe „Weitere Abfahrten“, um auf '
            'eine andere Abfahrt zu wechseln.';
    // One shared shape for every "the app is telling you something" block, so
    // a cancellation reads louder than a note by its tone, not by inventing its
    // own panel (#38).
    return MessageCard(
      tone: partial ? MessageTone.caution : MessageTone.alert,
      icon: partial ? Icons.warning_amber_rounded : Icons.cancel,
      title: title,
      body: body,
    );
  }
}

/// Per-Fahrtblock banner repeated directly above the affected leg, so the
/// cancellation is visible right where the train is rendered (and the
/// alternative-departure switcher sits).
class _LegCancelBanner extends StatelessWidget {
  final JourneyLeg leg;
  const _LegCancelBanner({required this.leg});

  /// " um 00:04", or nothing when the time is unknown.
  static String? _hhmm(DateTime? t) => t == null
      ? null
      : ' um ${t.hour.toString().padLeft(2, '0')}:'
          '${t.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final partial = !leg.cancelled;
    final color = partial ? AppColors.warning : AppColors.dbRed;
    final line = leg.line?.lineNumberWithFahrt ?? 'Zug';
    final dropped = leg.stopovers
        .where((s) => s.cancelled)
        .map((s) => s.stop.name)
        .where((n) => n.isNotEmpty)
        .toList();
    // Where the train really ends beats listing which stops it drops — that's
    // the bit the rider has to act on.
    final endsAt = leg.replacementDestination?.name;
    final label = endsAt != null
        ? '$line endet vorzeitig in $endsAt'
            '${_hhmm(leg.replacementArrival) ?? ''}'
            '${leg.replacementArrivalPlatform != null
                ? ', Gleis ${leg.replacementArrivalPlatform}'
                : ''}'
        : partial
            ? (dropped.isEmpty
                ? '$line: Halt entfällt'
                : '$line: Halt entfällt – ${dropped.join(', ')}')
            : '$line fällt aus';
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.55)),
      ),
      child: Row(
        children: [
          Icon(partial ? Icons.warning_amber_rounded : Icons.cancel,
              color: color, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(label,
                style: TextStyle(
                    color: color,
                    fontSize: 13.5,
                    fontWeight: FontWeight.bold)),
          ),
        ],
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
