import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/extensions.dart';
import '../../../models/journey.dart';
import '../../../models/station.dart';
import '../../../models/transfer_profile.dart';
import '../../../providers/service_providers.dart';
import '../../../providers/settings_provider.dart';
import '../../../services/earlier_alight_service.dart';
import '../../../services/vendo_service.dart';
import '../../../utils/earlier_alight.dart';

/// What the switcher needs to offer rescue option B — "get off earlier and go
/// another way" (#26). Bundled because it's all one question, and passing six
/// loose fields down two widgets would invite them to drift apart.
class EarlierAlightInput {
  /// The journey as booked — decides the ticket note (a Sparpreis on a booked
  /// ICE is bound, whatever pass the rider also owns).
  final Journey journey;

  /// The train being ridden into the tight transfer, and where it sits in
  /// [journey] — that's the leg to cut short.
  final JourneyLeg currentLeg;
  final int currentLegIndex;

  /// [currentLeg]'s stops with LIVE times ([alightStopsOfLeg]), built by the
  /// parent because only it holds the refreshed trip cache.
  final List<AlightStop> stops;

  /// Where the rider is actually going — the whole journey's end, not this
  /// leg's.
  final Station destination;

  /// Take this suggestion: rebuild the journey around the earlier exit.
  final void Function(EarlierAlightOption option) onApply;

  const EarlierAlightInput({
    required this.journey,
    required this.currentLeg,
    required this.currentLegIndex,
    required this.stops,
    required this.destination,
    required this.onApply,
  });
}

/// A compact bar on a train leg that lets you step through the OTHER departures
/// on the same segment — chevrons or a left/right swipe — and swap the shown
/// train in place (the old one is removed, the new one takes over).
///
/// When the transfer INTO this train is tight ([incomingGapMinutes] small), it
/// also proactively surfaces the two rescues:
///
///  * option A — the best reachable next train from the planned change
///    station, one tap to "Wechseln";
///  * option B — get off the train you're on EARLIER and go another way
///    ([earlierAlight], #26), which often beats A because the transfer is
///    never missed at all.
class LegAlternativeSwitcher extends ConsumerStatefulWidget {
  final JourneyLeg leg;
  final int index;
  final void Function(int index, JourneyLeg newLeg) onReplace;

  /// Everything needed for rescue option B. Null on the first leg (no train to
  /// get off) or when the journey's destination is unknown.
  final EarlierAlightInput? earlierAlight;

  /// Minutes available for the transfer into this train (live). Null = not a
  /// transfer (e.g. the first leg) or unknown.
  final int? incomingGapMinutes;

  /// When you'll realistically be ready to board here (the live arrival of the
  /// previous train). Trains departing before this are not reachable.
  final DateTime? readyAt;

  /// Where you change into this train — shown in the at-risk message.
  final String? transferStationName;

  /// DB says the transfer into this train stays on one platform
  /// (`weiterfahrtAmGleichenBahnsteig`, #20 point 6) — no stairs, no lift, so
  /// the profile has no walk to price.
  final bool samePlatformTransfer;

  const LegAlternativeSwitcher({
    super.key,
    required this.leg,
    required this.index,
    required this.onReplace,
    this.earlierAlight,
    this.incomingGapMinutes,
    this.readyAt,
    this.transferStationName,
    this.samePlatformTransfer = false,
  });

  @override
  ConsumerState<LegAlternativeSwitcher> createState() =>
      LegAlternativeSwitcherState();
}

class LegAlternativeSwitcherState
    extends ConsumerState<LegAlternativeSwitcher> {
  final List<Journey> _alts = [];
  String? _laterRef;
  bool _loading = false;
  bool _loaded = false;
  String? _error;

  /// The transfer as THIS rider experiences it: a 10-minute change is not the
  /// same with a pram as with a backpack (#11, point 7). Scaling the gap (not
  /// the thresholds) keeps every consumer comparing the same number.
  int? get _gap {
    final planned = widget.incomingGapMinutes;
    if (planned == null) return null;
    return ref.read(settingsProvider).transferProfile.effectiveGap(planned,
        samePlatform: widget.samePlatformTransfer);
  }

  bool get _atRisk => _gap != null && _gap! <= 2;
  bool get _tight => _gap != null && _gap! <= 5;

  /// Rescue option B (#26). Separate state from [_alts] because it costs a
  /// fan-out of searches, not one.
  EarlierAlightResult? _alight;
  bool _alightLoading = false;
  bool _alightTried = false;

  @override
  void initState() {
    super.initState();
    // Tight transfer → load eagerly so the "next reachable train" offer is
    // there the moment you look. Otherwise wait until the user reaches for it.
    if (_tight) _ensureLoaded();
    // Option B costs up to five searches against a backend that answers a
    // burst with minutes of 429s, so it does NOT ride along with every tight
    // transfer: only a genuinely at-risk one (the case the issue is about)
    // spends them unasked. A merely tight one gets a button.
    if (_atRisk) _ensureAlightLoaded();
  }

  @override
  void didUpdateWidget(LegAlternativeSwitcher oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A live delay just turned a comfortable transfer into a tight one → load
    // the alternatives now so the offer can appear.
    if (_tight && !_loaded && !_loading) _ensureLoaded();
    // Same for option B, once the transfer is actually at risk.
    if (_atRisk && !_alightTried && !_alightLoading) _ensureAlightLoaded();
    // The shown train just changed (a swipe/step swapped the leg) → warm the
    // NEW neighbours so the next swipe in either direction is instant too.
    if (_loaded && oldWidget.leg.tripId != widget.leg.tripId) {
      _prefetchNeighbors();
    }
  }

  DateTime? get _currentDep =>
      widget.leg.departure ?? widget.leg.plannedDeparture;

  Future<void> _ensureLoaded() async {
    if (_loaded || _loading) return;
    final leg = widget.leg;
    final from = leg.origin.vendoLocationId;
    final to = leg.destination.vendoLocationId;
    final an = leg.plannedArrival ?? leg.arrival;
    if (from.isEmpty || to.isEmpty || an == null) {
      setState(() {
        _loaded = true;
        _error = 'Nicht verfügbar.';
      });
      return;
    }
    setState(() => _loading = true);
    try {
      final res = await ref.read(vendoServiceProvider).fetchWeitereAbfahrten(
            abgangsLocationId: from,
            zielLocationId: to,
            ankunft: an,
            produktGattungen:
                VendoService.produktGattungenFor(leg.line?.product),
          );
      if (!mounted) return;
      setState(() {
        _merge(res.journeys);
        _laterRef = res.laterRef;
        _loaded = true;
      });
      _prefetchNeighbors();
    } catch (_) {
      if (mounted) setState(() => _error = 'Konnte nicht laden.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Kick off rescue option B: from every earlier stop of the train we're on,
  /// search a fresh way to the real destination and keep only what beats
  /// missing the connection. The service does the pacing/caching; the pure
  /// utils do the judging.
  Future<void> _ensureAlightLoaded() async {
    final input = widget.earlierAlight;
    final readyAt = widget.readyAt;
    if (input == null || readyAt == null) return;
    if (_alightTried || _alightLoading) return;
    setState(() => _alightLoading = true);
    final settings = ref.read(settingsProvider);
    try {
      final res = await ref.read(earlierAlightServiceProvider).findOptions(
            currentLeg: input.currentLeg,
            onwardLeg: widget.leg,
            original: input.journey,
            destination: input.destination,
            stops: input.stops,
            readyAt: readyAt,
            profile: settings.transferProfile,
            hasDeutschlandTicket: settings.searchParty.deutschlandTicket,
            reisende: settings.searchParty.toReisendeJson(),
            firstClass: settings.searchParty.firstClass,
            apiDelayMs: settings.apiDelayMs,
          );
      if (!mounted) return;
      setState(() => _alight = res);
    } catch (_) {
      // Nothing to show is the honest outcome — never a fake suggestion.
    } finally {
      if (mounted) {
        setState(() {
          _alightLoading = false;
          _alightTried = true;
        });
      }
    }
  }

  Future<void> _loadMore() async {
    if (_laterRef == null || _loading) return;
    final leg = widget.leg;
    final an = leg.plannedArrival ?? leg.arrival;
    if (an == null) return;
    setState(() => _loading = true);
    try {
      final res = await ref.read(vendoServiceProvider).fetchWeitereAbfahrten(
            abgangsLocationId: leg.origin.vendoLocationId,
            zielLocationId: leg.destination.vendoLocationId,
            ankunft: an,
            produktGattungen:
                VendoService.produktGattungenFor(leg.line?.product),
            context: _laterRef,
          );
      if (!mounted) return;
      setState(() {
        _merge(res.journeys);
        _laterRef = res.laterRef;
      });
      _prefetchNeighbors();
    } catch (_) {
      /* keep what we have */
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Warm the per-train data for the immediately adjacent departures — the one
  /// you'd reach swiping right (earlier, "davor") and left (later, "danach") —
  /// so the swipe shows the neighbour's train instantly instead of fetching on
  /// arrival. Best-effort, fire-and-forget; the Wagenreihung lands in the shared
  /// session cache the platform train + route map read.
  void _prefetchNeighbors() {
    if (_alts.isEmpty) return;
    final curId = widget.leg.tripId;
    var idx = _alts.indexWhere((j) => j.legs.firstOrNull?.tripId == curId);
    if (idx < 0) {
      final curDep = _currentDep;
      if (curDep != null) {
        idx = _alts
            .indexWhere((a) => !((_depOf(a) ?? curDep).isBefore(curDep)));
      }
      if (idx < 0) idx = 0;
    }
    for (final n in [idx - 1, idx + 1]) {
      if (n < 0 || n >= _alts.length) continue;
      final l = _alts[n].legs.firstOrNull;
      final line = l?.line;
      if (l == null || line == null || line.fahrtNr.isEmpty) continue;
      // Fire-and-forget: caches by train+stop+time, so the swiped-to detail
      // draws its platform train immediately.
      ref.read(coachSequenceServiceProvider).getCoachSequenceForDeparture(
            category: line.productName,
            trainNumber: line.fahrtNr,
            stationEva: l.origin.id,
            departureTime: l.departure ?? l.plannedDeparture,
          );
    }
  }

  void _merge(List<Journey> incoming) {
    final seen = _alts
        .map((j) => j.legs.firstOrNull?.tripId)
        .whereType<String>()
        .toSet();
    for (final j in incoming) {
      final l = j.legs.firstOrNull;
      if (l == null) continue;
      final id = l.tripId;
      if (id != null && !seen.add(id)) continue;
      _alts.add(j);
    }
    _alts.sort((a, b) {
      final da = a.legs.firstOrNull?.departure ??
          a.legs.firstOrNull?.plannedDeparture;
      final db = b.legs.firstOrNull?.departure ??
          b.legs.firstOrNull?.plannedDeparture;
      if (da == null || db == null) return 0;
      return da.compareTo(db);
    });
  }

  /// Departure of an alternative (live, else planned).
  DateTime? _depOf(Journey j) =>
      j.legs.firstOrNull?.departure ?? j.legs.firstOrNull?.plannedDeparture;

  /// How much later you'd arrive if this connection breaks and you fall back to
  /// [_bestReachable], in minutes. Null when it can't be worked out.
  ///
  /// The consequence of missing the train, which the risk banner had the data
  /// for but never stated: "Anschluss gefährdet" tells you there's a problem,
  /// not whether it costs 12 minutes or two hours — and that's the whole
  /// difference between risking it and getting off earlier (#11, option C).
  int? get _fallbackCostMinutes {
    final planned = widget.leg.plannedArrival ?? widget.leg.arrival;
    final alt = _bestReachable;
    if (planned == null || alt == null) return null;
    final l = alt.legs.lastOrNull;
    final altArr = l?.arrival ?? l?.plannedArrival;
    if (altArr == null) return null;
    final diff = altArr.difference(planned).inMinutes;
    return diff > 0 ? diff : null;
  }

  /// The earliest alternative you can still catch (departs at/after [readyAt])
  /// that isn't the train already shown — the "next reachable" suggestion.
  Journey? get _bestReachable {
    final ready = widget.readyAt;
    final curId = widget.leg.tripId;
    for (final j in _alts) {
      final l = j.legs.firstOrNull;
      if (l == null || l.tripId == curId) continue;
      final dep = _depOf(j);
      if (dep == null) continue;
      if (ready == null || !dep.isBefore(ready)) return j;
    }
    return null;
  }

  void _select(Journey alt) {
    final l = alt.legs.firstOrNull;
    if (l != null) widget.onReplace(widget.index, l);
  }

  /// Step to the previous (−1) / next (+1) departure relative to the one shown.
  Future<void> _step(int dir) async {
    if (!_loaded) {
      await _ensureLoaded();
      return; // bar now populated; user steps again
    }
    if (_alts.isEmpty) return;
    final curId = widget.leg.tripId;
    final curDep = _currentDep;
    final idx = _alts.indexWhere((j) => j.legs.firstOrNull?.tripId == curId);

    if (idx >= 0) {
      final next = idx + dir;
      if (next < 0) return;
      if (next >= _alts.length) {
        await _loadMore();
        if (idx + 1 < _alts.length) _select(_alts[idx + 1]);
        return;
      }
      _select(_alts[next]);
      return;
    }

    // The shown train isn't in the list — pick by time relative to it.
    if (curDep == null) {
      _select(dir > 0 ? _alts.first : _alts.last);
      return;
    }
    if (dir > 0) {
      final j = _alts.firstWhere(
          (a) => (_depOf(a) ?? curDep).isAfter(curDep),
          orElse: () => _alts.last);
      _select(j);
    } else {
      final earlier =
          _alts.where((a) => (_depOf(a) ?? curDep).isBefore(curDep)).toList();
      if (earlier.isNotEmpty) _select(earlier.last);
    }
  }

  /// Map a horizontal fling velocity to a departure step. Public so the whole
  /// leg block (not just this bar) can hand its swipe over to the same logic.
  /// Vertical list scroll still wins (different axis), so this only fires on a
  /// deliberate sideways swipe.
  void handleHorizontalFling(double velocity) {
    if (velocity < -120) {
      _step(1); // swipe left → next (later) train
    } else if (velocity > 120) {
      _step(-1); // swipe right → previous (earlier) train
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final best = _loaded ? _bestReachable : null;
    final showRiskOffer = _tight && best != null;
    // Deliberately NOT gated on option A having found something: when no next
    // train exists from the planned change station at all, getting off earlier
    // is the ONLY rescue left — the last moment to hide it (#26). The gap
    // alone says the transfer is tight, so this needs no network to decide.
    final showAlight =
        _tight && widget.earlierAlight != null && widget.readyAt != null;
    final warn = showRiskOffer || showAlight;

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      decoration: BoxDecoration(
        color: warn
            ? (_atRisk
                ? theme.colorScheme.errorContainer
                : const Color(0xFFFFF3E0))
            : theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
        border: warn
            ? Border.all(
                color: _atRisk
                    ? theme.colorScheme.error
                    : const Color(0xFFCC8800),
                width: 1.5)
            : null,
      ),
      clipBehavior: Clip.antiAlias,
      // No own swipe handler here: the whole leg block ([_LegSection]) wraps
      // this bar in a single horizontal-drag gesture that hands the fling to
      // [handleHorizontalFling]. Keeping a second handler here would just be a
      // competing detector on the same area. The chevrons still step manually.
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (showRiskOffer) _riskOffer(theme, best),
            if (showAlight)
              Padding(
                padding: EdgeInsets.fromLTRB(4, showRiskOffer ? 0 : 4, 4, 6),
                child: _earlierAlight(theme, _riskFg(theme),
                    standalone: !showRiskOffer),
              ),
            _stepper(theme),
          ],
        ),
      ),
    );
  }

  /// "45 Min" / "1:20 Std" — an hour-plus delay reads as a wall of minutes
  /// otherwise, and that's exactly the case the rider must not misjudge.
  static String _hm(int minutes) {
    if (minutes < 60) return '$minutes Min';
    final h = minutes ~/ 60;
    final m = minutes % 60;
    return m == 0 ? '$h Std' : '$h:${m.toString().padLeft(2, '0')} Std';
  }

  /// Readable-on-the-banner foreground, shared by both rescue offers so they
  /// can't drift apart.
  Color _riskFg(ThemeData theme) => _atRisk
      ? theme.colorScheme.onErrorContainer
      : const Color(0xFF7A4E00);

  Widget _riskOffer(ThemeData theme, Journey best) {
    final l = best.legs.firstOrNull;
    final dep = l?.departure ?? l?.plannedDeparture;
    final arr = l?.arrival ?? l?.plannedArrival;
    final name = l?.line?.titleWithNumber ?? l?.line?.displayName ?? 'Zug';
    final fg = _riskFg(theme);
    final station = widget.transferStationName;
    // The PLANNED gap, not the profile-scaled one: that's the number on the
    // platform display, and contradicting it would just look wrong. The
    // profile decides whether to warn, not what the clock says.
    final gap = widget.incomingGapMinutes;
    final profile = ref.read(settingsProvider).transferProfile;
    // Say so when the profile — not the clock — is what raised this, otherwise
    // "Knapper Anschluss · 12 min" reads as a bug.
    final byProfile = profile != TransferProfile.normal &&
        gap != null &&
        gap > 5 &&
        _tight;
    final headline = _atRisk
        ? 'Anschluss${station != null ? ' in $station' : ''} evtl. nicht erreichbar'
            '${gap != null ? ' · nur $gap min' : ''}'
        : 'Knapper Anschluss${gap != null ? ' · $gap min' : ''}'
            '${byProfile ? ' für „${profile.label}"' : ''}';

    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 2, 4, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.warning_amber_rounded, size: 18, color: fg),
              const SizedBox(width: 6),
              Expanded(
                child: Text(headline,
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(fontWeight: FontWeight.w700, color: fg)),
              ),
            ],
          ),
          const SizedBox(height: 6),
          // What it actually costs you if the connection breaks. Without this
          // the warning can't be acted on: 12 minutes is worth risking, 90 is
          // worth getting off earlier for.
          if (_fallbackCostMinutes case final cost?) ...[
            Text(
              'Wenn der Anschluss platzt: ${_hm(cost)} später am Ziel'
              '${arr != null ? ' (an ${arr.hhmm})' : ''}.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: fg, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
          ],
          Row(
            children: [
              Expanded(
                child: Text(
                  'Nächster erreichbarer Zug: $name'
                  '${dep != null ? ' · ab ${dep.hhmm}' : ''}'
                  '${arr != null ? ' → an ${arr.hhmm}' : ''}',
                  style: theme.textTheme.bodySmall?.copyWith(color: fg),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: () => _select(best),
                icon: const Icon(Icons.swap_horiz, size: 18),
                label: const Text('Wechseln'),
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  backgroundColor:
                      _atRisk ? theme.colorScheme.error : const Color(0xFFCC8800),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Rescue option B (#26): the second way out, right under option A so the
  /// two can be compared at a glance — ride on and lose the fallback cost, or
  /// get off early and lose less.
  ///
  /// [standalone] means option A found nothing, so this block carries the
  /// warning headline itself instead of hanging under one.
  Widget _earlierAlight(ThemeData theme, Color fg, {bool standalone = false}) {
    if (widget.earlierAlight == null || widget.readyAt == null) {
      return const SizedBox.shrink();
    }
    if (standalone) {
      final station = widget.transferStationName;
      final gap = widget.incomingGapMinutes;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.warning_amber_rounded, size: 18, color: fg),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Anschluss${station != null ? ' in $station' : ''} '
                  'gefährdet${gap != null ? ' · nur $gap min' : ''}',
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(fontWeight: FontWeight.w700, color: fg),
                ),
              ),
            ],
          ),
          _earlierAlight(theme, fg),
        ],
      );
    }

    if (_alightLoading) {
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Row(
          children: [
            SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: 2, color: fg),
            ),
            const SizedBox(width: 8),
            Text('Suche frühere Ausstiege…',
                style: theme.textTheme.bodySmall?.copyWith(color: fg)),
          ],
        ),
      );
    }

    // Not searched yet (a merely tight transfer doesn't spend the requests
    // unasked) → let the rider ask for it.
    if (!_alightTried) {
      return Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: _ensureAlightLoaded,
          icon: const Icon(Icons.logout, size: 16),
          label: const Text('Früher aussteigen prüfen'),
          style: TextButton.styleFrom(
            foregroundColor: fg,
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: 8),
          ),
        ),
      );
    }

    final options = _alight?.options ?? const <EarlierAlightOption>[];
    // Say it plainly instead of leaving a gap the rider reads as "still
    // loading": we looked, and riding on really is the best there is.
    if (options.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Text(
          'Früher aussteigen bringt hier nichts — keine Route ist schneller '
          'als der nächste Zug.',
          style: theme.textTheme.bodySmall?.copyWith(color: fg),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Divider(height: 1, color: fg.withValues(alpha: 0.25)),
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(Icons.alt_route, size: 16, color: fg),
              const SizedBox(width: 6),
              Text('Oder früher aussteigen',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(fontWeight: FontWeight.w700, color: fg)),
            ],
          ),
          const SizedBox(height: 6),
          // Two at most: this is a decision to take in the next few minutes on
          // a moving train, not a result list to browse.
          for (final o in options.take(2)) _alightOption(theme, fg, o),
        ],
      ),
    );
  }

  Widget _alightOption(ThemeData theme, Color fg, EarlierAlightOption o) {
    final first = o.onward.legs.where((l) => !l.isWalking).firstOrNull;
    final name = first?.line?.titleWithNumber ??
        first?.line?.displayName ??
        'Weiterfahrt';
    final changes = o.onward.transfers;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Aussteigen in ${o.stop.station.name} · an ${o.alightArrival.hhmm}',
            style: theme.textTheme.bodySmall
                ?.copyWith(fontWeight: FontWeight.w700, color: fg),
          ),
          const SizedBox(height: 2),
          Text(
            'Weiter mit $name · ${_hm(o.waitMinutes)} Umstieg · '
            '${changes <= 0 ? 'direkt' : '$changes× umsteigen'}',
            style: theme.textTheme.bodySmall?.copyWith(color: fg),
          ),
          const SizedBox(height: 2),
          // The number the whole feature exists for: what it saves against
          // riding on and missing the connection.
          Text(
            'Am Ziel ${o.arrival.hhmm} — ${_hm(o.gainMinutes)} früher als der '
            'nächste Zug',
            style: theme.textTheme.bodySmall
                ?.copyWith(fontWeight: FontWeight.w700, color: fg),
          ),
          const SizedBox(height: 6),
          // Never optional (#26): a Sparpreis is bound to the booked trains, so
          // a suggestion to leave one early without saying so sends riders
          // into a Fahrpreisnacherhebung.
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                  o.ticketNote == AlightTicketNote.dTicketCovered
                      ? Icons.check_circle_outline
                      : Icons.confirmation_number_outlined,
                  size: 14,
                  color: fg),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '${o.ticketNote.label} — ${o.ticketNote.detail}',
                  style: theme.textTheme.labelSmall?.copyWith(color: fg),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              onPressed: () => widget.earlierAlight?.onApply(o),
              icon: const Icon(Icons.alt_route, size: 16),
              label: const Text('Route übernehmen'),
              style: FilledButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                backgroundColor: theme.colorScheme.primary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _stepper(ThemeData theme) {
    final muted = theme.colorScheme.onSurfaceVariant;
    final dep = _currentDep;
    String position = '';
    if (_loaded && _alts.isNotEmpty) {
      final idx =
          _alts.indexWhere((j) => j.legs.firstOrNull?.tripId == widget.leg.tripId);
      if (idx >= 0) position = '  ·  ${idx + 1}/${_alts.length}';
    }
    return Row(
      children: [
        _navBtn(theme, Icons.chevron_left, 'Frühere Abfahrt', () => _step(-1)),
        Expanded(
          child: Center(
            child: _loading && !_loaded
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : Text(
                    _error ??
                        'Diese Abfahrt${dep != null ? ' · ab ${dep.hhmm}' : ''}'
                            '$position   ·   Block wischen für andere',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: muted, fontWeight: FontWeight.w500),
                  ),
          ),
        ),
        _navBtn(theme, Icons.chevron_right, 'Spätere Abfahrt', () => _step(1)),
      ],
    );
  }

  Widget _navBtn(
      ThemeData theme, IconData icon, String tip, VoidCallback onTap) {
    return IconButton(
      icon: Icon(icon, size: 22),
      tooltip: tip,
      visualDensity: VisualDensity.compact,
      color: theme.colorScheme.primary,
      onPressed: _loading ? null : onTap,
    );
  }
}
