import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/extensions.dart';
import '../../../models/journey.dart';
import '../../../providers/service_providers.dart';
import '../../../services/vendo_service.dart';

/// A compact bar on a train leg that lets you step through the OTHER departures
/// on the same segment — chevrons or a left/right swipe — and swap the shown
/// train in place (the old one is removed, the new one takes over).
///
/// When the transfer INTO this train is tight ([incomingGapMinutes] small), it
/// also proactively surfaces the best reachable next train with a one-tap
/// "Wechseln", so a likely-missed connection immediately offers the fix instead
/// of leaving you to dig for it.
class LegAlternativeSwitcher extends ConsumerStatefulWidget {
  final JourneyLeg leg;
  final int index;
  final void Function(int index, JourneyLeg newLeg) onReplace;

  /// Minutes available for the transfer into this train (live). Null = not a
  /// transfer (e.g. the first leg) or unknown.
  final int? incomingGapMinutes;

  /// When you'll realistically be ready to board here (the live arrival of the
  /// previous train). Trains departing before this are not reachable.
  final DateTime? readyAt;

  /// Where you change into this train — shown in the at-risk message.
  final String? transferStationName;

  const LegAlternativeSwitcher({
    super.key,
    required this.leg,
    required this.index,
    required this.onReplace,
    this.incomingGapMinutes,
    this.readyAt,
    this.transferStationName,
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

  bool get _atRisk =>
      widget.incomingGapMinutes != null && widget.incomingGapMinutes! <= 2;
  bool get _tight =>
      widget.incomingGapMinutes != null && widget.incomingGapMinutes! <= 5;

  @override
  void initState() {
    super.initState();
    // Tight transfer → load eagerly so the "next reachable train" offer is
    // there the moment you look. Otherwise wait until the user reaches for it.
    if (_tight) _ensureLoaded();
  }

  @override
  void didUpdateWidget(LegAlternativeSwitcher oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A live delay just turned a comfortable transfer into a tight one → load
    // the alternatives now so the offer can appear.
    if (_tight && !_loaded && !_loading) _ensureLoaded();
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

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      decoration: BoxDecoration(
        color: showRiskOffer
            ? (_atRisk
                ? theme.colorScheme.errorContainer
                : const Color(0xFFFFF3E0))
            : theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
        border: showRiskOffer
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

  Widget _riskOffer(ThemeData theme, Journey best) {
    final l = best.legs.firstOrNull;
    final dep = l?.departure ?? l?.plannedDeparture;
    final arr = l?.arrival ?? l?.plannedArrival;
    final name = l?.line?.titleWithNumber ?? l?.line?.displayName ?? 'Zug';
    final fg = _atRisk ? theme.colorScheme.onErrorContainer : const Color(0xFF7A4E00);
    final station = widget.transferStationName;
    final gap = widget.incomingGapMinutes;
    final headline = _atRisk
        ? 'Anschluss${station != null ? ' in $station' : ''} evtl. nicht erreichbar'
            '${gap != null ? ' · nur $gap min' : ''}'
        : 'Knapper Anschluss${gap != null ? ' · $gap min' : ''}';

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
