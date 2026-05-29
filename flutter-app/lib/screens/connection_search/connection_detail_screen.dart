import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/share_text.dart';
import '../../models/coach_sequence.dart';
import '../../models/journey.dart';
import '../../models/library_models.dart';
import '../../models/station.dart';
import '../../models/trip.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../providers/library_provider.dart';
import '../../providers/service_providers.dart';
import '../../providers/settings_provider.dart';
import '../../providers/split_ticket_provider.dart';
import '../../providers/station_map_provider.dart';
import '../../services/db_api_service.dart';
import '../../widgets/prediction_badge.dart';
import '../train_lookup/widgets/train_detail_view.dart';
import 'widgets/leg_alternatives.dart';

/// In-memory cache (app session) so a leg's train data is fetched once and
/// reused — scrolling away and back never re-downloads or rebuilds from
/// scratch; cached data shows instantly and refreshes in the background.
final Map<String, Trip> _tripCache = {};
final Map<String, CoachSequence> _coachCache = {};

/// Full multi-leg connection as ONE screen: each train's complete detail
/// (header, live map, coach sequence, stops) stacked vertically — scroll down
/// to the next train. No intermediate "pick a leg" screen.
class ConnectionDetailScreen extends ConsumerWidget {
  final Journey journey;

  const ConnectionDetailScreen({super.key, required this.journey});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final legs = journey.legs;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          '${journey.origin?.name ?? ''} → ${journey.destination?.name ?? ''}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.ios_share),
            tooltip: 'Reise teilen',
            onPressed: () => _shareJourney(context, ref),
          ),
          IconButton(
            icon: const Icon(Icons.open_in_new),
            tooltip: 'Auf bahn.de öffnen / buchen',
            onPressed: () => _openOnBahn(context, ref),
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
                ref.read(libraryProvider.notifier).toggleJourney(journey);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    duration: const Duration(seconds: 2),
                    content:
                        Text(saved ? 'Reise entfernt' : 'Reise gespeichert'),
                  ),
                );
              },
            );
          }),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          _summary(context),
          for (var i = 0; i < legs.length; i++) ...[
            if (i > 0) _transfer(context, ref, legs[i - 1], legs[i]),
            if (legs[i].isWalking)
              _walkLeg(context, ref, legs[i],
                  i > 0 ? legs[i - 1] : null,
                  i + 1 < legs.length ? legs[i + 1] : null)
            else
              _LegSection(leg: legs[i]),
          ],
        ],
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
      stops
        ..removeWhere((s) => !keep.contains(s));
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
        );
    context.push('/split-ticket', extra: journey);
  }

  Widget _summary(BuildContext context) {
    final theme = Theme.of(context);
    final t = journey.transfers;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(journey.durationString,
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.bold)),
              const SizedBox(width: 12),
              Text(t == 0 ? 'Direkt' : '$t Umstieg${t > 1 ? 'e' : ''}',
                  style: theme.textTheme.bodyMedium),
              const Spacer(),
              if (journey.price != null)
                Text(journey.price!.formatted,
                    style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: theme.colorScheme.primary)),
            ],
          ),
          const SizedBox(height: 8),
          PredictionBadge(journey: journey, axis: Axis.horizontal),
        ],
      ),
    );
  }

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

  /// A FUSSWEG leg between two trains. The headline number is the *time you
  /// have* to change (arrival → next departure), NOT how long the walk takes;
  /// the walk itself is shown as the secondary detail.
  Widget _walkLeg(BuildContext context, WidgetRef ref, JourneyLeg leg,
      JourneyLeg? prev, JourneyLeg? next) {
    // Available transfer time: from the train's arrival to the next departure.
    // DB gives NO walk duration — only (sometimes) a distance — so we never
    // present minutes as how long the walk takes.
    final arr = prev?.arrival ?? leg.departure;
    final dep = next?.departure ?? leg.arrival;
    final avail = (arr != null && dep != null)
        ? dep.difference(arr).inMinutes
        : null;
    final (color, warn) = _transferTone(context, avail);

    final head = avail != null ? '$avail min zum Umsteigen' : 'Umstieg';
    final detail = leg.walkingDistance != null
        ? 'mit Fußweg · ${leg.walkingDistance} m'
        : 'mit Fußweg';

    return _transferTile(
      context,
      icon: Icons.directions_walk,
      head: head,
      headColor: color,
      detail: detail,
      warn: warn,
      onTap: leg.origin.name.isEmpty
          ? null
          : () => _openTransferMap(context, ref, leg.origin,
              prev?.arrivalPlatform, next?.departurePlatform),
    );
  }

  /// Open the platform-to-platform map straight away (no intermediate screen):
  /// Einstieg Gleis green, Ausstieg Gleis red, both with their section bands.
  void _openTransferMap(BuildContext context, WidgetRef ref, Station station,
      String? arrGleis, String? depGleis) {
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
          transferNote: note,
        );
    context.push('/station-map');
  }

  Widget _transfer(
      BuildContext context, WidgetRef ref, JourneyLeg prev, JourneyLeg next) {
    if (prev.isWalking || next.isWalking) return const SizedBox(height: 8);
    // Time you actually have to change trains (arrival → next departure).
    final gap = (next.departure != null && prev.arrival != null)
        ? next.departure!.difference(prev.arrival!).inMinutes
        : null;

    final arrGleis = prev.arrivalPlatform;
    final depGleis = next.departurePlatform;
    final station = prev.destination;
    final (color, warn) = _transferTone(context, gap);

    final gleisText = (arrGleis != null || depGleis != null)
        ? 'Gleis ${arrGleis ?? '?'} → Gleis ${depGleis ?? '?'}'
        : null;

    return _transferTile(
      context,
      icon: Icons.swap_calls,
      head: gap != null
          ? '$gap min zum Umsteigen in ${station.name}'
          : 'Umstieg in ${station.name}',
      headColor: color,
      detail: gleisText,
      warn: warn,
      onTap: station.name.isEmpty
          ? null
          : () => _openTransferMap(context, ref, station, arrGleis, depGleis),
    );
  }

  /// Shared tappable transfer/walk row.
  Widget _transferTile(
    BuildContext context, {
    required IconData icon,
    required String head,
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
                    Text(
                      head,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: headColor,
                      ),
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
  const _LegSection({required this.leg});

  @override
  ConsumerState<_LegSection> createState() => _LegSectionState();
}

class _LegSectionState extends ConsumerState<_LegSection>
    with AutomaticKeepAliveClientMixin {
  Trip? _trip;
  CoachSequence? _coach;
  bool _loading = true;

  // Keep the leg alive when scrolled off-screen → no dispose, no re-fetch,
  // no UI rebuild when scrolling back to it.
  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
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
    try {
      var trip = await ref.read(hafasServiceProvider).getTrip(id);
      // The `fahrt` API drops the line label ("RE7"); the journey leg still has
      // it, so carry it in → header shows "RE 7 (11281)", not the bare number.
      final label = leg.line?.name.trim() ?? '';
      if (label.isNotEmpty) {
        trip = trip.copyWith(line: trip.line.withName(label));
      }
      _tripCache[id] = trip;
      if (mounted) setState(() => _trip = trip);
      try {
        final cs = await ref
            .read(coachSequenceServiceProvider)
            .getCoachSequenceForDeparture(
              lineName: leg.line?.displayName ?? '',
              stationEva: leg.origin.id,
              departureTime: leg.departure,
            );
        if (cs != null) {
          _coachCache[id] = cs;
          if (mounted) setState(() => _coach = cs);
        }
      } catch (_) {/* optional */}
    } catch (_) {/* keep cached/fallback */} finally {
      if (mounted && !silent) setState(() => _loading = false);
    }
  }

  void _openStopMap(Stopover stop) {
    if (stop.stop.name.isEmpty) return;
    ref.read(stationMapProvider.notifier).loadForStation(
          stop.stop,
          highlightGleis: stop.platform,
          role: stop.isTerminus
              ? GleisRole.alight
              : stop.isOrigin
                  ? GleisRole.board
                  : GleisRole.none,
        );
    context.push('/station-map');
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // required by AutomaticKeepAliveClientMixin
    final trip = _trip;
    if (trip != null) {
      final leg = widget.leg;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TrainDetailView(
            trip: trip,
            coach: _coach,
            onStopTap: _openStopMap,
            boardingId:
                leg.origin.id.isNotEmpty ? leg.origin.id : leg.origin.name,
            alightingId: leg.destination.id.isNotEmpty
                ? leg.destination.id
                : leg.destination.name,
          ),
          if (!leg.isWalking && leg.line != null)
            LegAlternatives(leg: leg),
        ],
      );
    }
    // Loading / fallback: still show the leg summary so the user sees the train.
    final leg = widget.leg;
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: ListTile(
        leading: _loading
            ? const SizedBox(
                width: 20, height: 20,
                child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.train),
        title: Text(leg.line?.displayName ?? 'Zug'),
        subtitle: Text(
            '${leg.origin.name} → ${leg.destination.name}'
            '${leg.direction != null ? '  ·  Richtung ${leg.direction}' : ''}'),
      ),
    );
  }
}
