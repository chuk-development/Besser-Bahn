import 'package:flutter/material.dart';
import '../../../models/journey.dart' show OccupancyLevel;
import '../../../models/trip.dart';
import '../../../core/extensions.dart';
import '../../../widgets/occupancy_indicator.dart';
import '../../../widgets/platform_badge.dart' show TrackIcon;

/// Stop list for a train. When [boardingId]/[alightingId] are given (i.e. the
/// timeline is shown for one leg of a journey, not a standalone train lookup),
/// the stops *before* boarding and *after* alighting are collapsed behind a
/// tappable header — you searched Berlin→Kiel, so the train's run through
/// Czechia before Berlin is hidden until you ask for it.
class StopTimeline extends StatefulWidget {
  final List<Stopover> stopovers;

  /// Tapping a stop opens its station map (with the boarding Gleis highlighted).
  final void Function(Stopover stop)? onStopTap;

  /// EVA / name of the stop you board at and get off at, for this leg.
  /// Null → standalone train view: show every stop, nothing collapsed.
  final String? boardingId;
  final String? alightingId;

  /// Leg-wide amenities (bike, quiet zone, …) shown in the gap between the
  /// boarding and alighting stop — info that belongs to the whole ride, not a
  /// single stop. Empty → nothing rendered.
  final List<({IconData icon, String label})> legAmenities;

  /// Optional widget rendered at the top of the timeline card (above the "Halte"
  /// title) — used to fold the train header into the same block.
  final Widget? header;

  /// Optional widget rendered right under the train header, INSIDE this card
  /// (e.g. the collapsible Wagenreihung) — so it's part of the train element,
  /// not a separate section.
  final Widget? trainExtra;

  /// Optional widget rendered directly under the boarding stop (aligned beneath
  /// the station name) — used for the wing-train split banner, surfaced exactly
  /// where you board, not buried in the Wagenreihung.
  final Widget? boardingBanner;

  /// When true, return content without the surrounding Card/margin so it can be
  /// embedded in a shared card.
  final bool embedded;

  /// When true *and* this is a leg (boarding/alighting resolved), the [header]
  /// content renders inline on the route spine between the board and alight
  /// stops (DB-Navigator style) instead of above a "Halte" title. No effect on
  /// the standalone train view (no endpoints → not a leg).
  final bool inlineHeader;

  const StopTimeline({
    super.key,
    required this.stopovers,
    this.onStopTap,
    this.boardingId,
    this.alightingId,
    this.legAmenities = const [],
    this.header,
    this.trainExtra,
    this.boardingBanner,
    this.embedded = false,
    this.inlineHeader = false,
  });

  @override
  State<StopTimeline> createState() => _StopTimelineState();
}

/// Left time/duration gutter width — tight so the stop content gets the room
/// instead of dead space under the times.
const double _kSpineWidth = 40.0;

class _StopTimelineState extends State<StopTimeline> {
  bool _expandedBefore = false;
  bool _expandedAfter = false;
  bool _expandedMiddle = false;

  /// Index of [id] in the stop list (by EVA, then by name), or -1.
  int _indexOf(String? id) {
    if (id == null || id.isEmpty) return -1;
    final stops = widget.stopovers;
    for (var i = 0; i < stops.length; i++) {
      if (stops[i].stop.id == id) return i;
    }
    for (var i = 0; i < stops.length; i++) {
      if (stops[i].stop.name == id) return i;
    }
    return -1;
  }

  @override
  Widget build(BuildContext context) {
    final stops = widget.stopovers;
    if (stops.isEmpty) return const SizedBox.shrink();

    // Resolve the ridden segment [board, alight]. Fall back to whole trip.
    final rawBoard = _indexOf(widget.boardingId);
    final rawAlight = _indexOf(widget.alightingId);
    // This is a journey leg (vs. a standalone train lookup) only when at least
    // one endpoint was actually resolved — then we also collapse the stops
    // *between* the endpoints, since 99% just board and alight.
    final isLeg = rawBoard >= 0 || rawAlight >= 0;
    var board = rawBoard;
    var alight = rawAlight;
    if (board < 0) board = 0;
    if (alight < 0 || alight < board) alight = stops.length - 1;

    final beforeCount = board;
    final afterCount = stops.length - 1 - alight;
    final middleCount = alight - board - 1;

    // DB-Navigator-style leg view: fold the train header inline onto the route
    // spine between the board and alight stops (no top header / "Halte" title).
    // Requires a real leg with a header and a board→alight span.
    final useInline =
        widget.inlineHeader && isLeg && widget.header != null && alight > board;

    final rows = <Widget>[];

    // --- stops before boarding (collapsed by default) ---------------------
    if (beforeCount > 0) {
      rows.add(_collapseHeader(
        context,
        expanded: _expandedBefore,
        count: beforeCount,
        label: _expandedBefore
            ? 'Halte vorher ausblenden'
            : '$beforeCount ${beforeCount == 1 ? 'Halt' : 'Halte'} vorher · ab ${stops.first.stop.name}',
        onTap: () => setState(() => _expandedBefore = !_expandedBefore),
      ));
      if (_expandedBefore) {
        for (var i = 0; i < board; i++) {
          rows.add(_stopRow(i, board, alight, hasTop: i != 0, hasBottom: true));
        }
      }
    }

    if (useInline) {
      // board endpoint (big Gleis) → train card on the spine → (expanded
      // intermediate stops) → alight endpoint (big Gleis).
      rows.add(_stopRow(board, board, alight,
          hasTop: beforeCount > 0 && _expandedBefore,
          hasBottom: true,
          // Connector into the train-card block: full the moment the ride has
          // started, so the block below picks the fill up seamlessly (no gap).
          belowFillOverride: _blockFill(board, alight) > 0 ? 1.0 : 0.0));
      // Train card + Wagenreihung in ONE spine block, so the leg duration in the
      // gutter sits vertically centred across the whole thing (between the board
      // departure above and the alight arrival below), and the route line runs
      // continuously down their left side.
      rows.add(_inlineTrainBlock(
        context,
        middleCount: middleCount,
        duration: _legDuration(stops, board, alight),
        expandable: middleCount > 0,
        extra: widget.trainExtra,
        fill: _blockFill(board, alight),
      ));
      if (_expandedMiddle && middleCount > 0) {
        for (var i = board + 1; i < alight; i++) {
          rows.add(_stopRow(i, board, alight, hasTop: true, hasBottom: true));
        }
      }
      rows.add(_stopRow(alight, board, alight,
          hasTop: true, hasBottom: afterCount > 0));
    } else {
      // --- the ridden segment (header-on-top layout) ----------------------
      // Endpoints (board, alight) are always shown. On a journey leg the stops
      // between them collapse behind a "N Zwischenhalte" header; on a standalone
      // train lookup every stop stays visible.
      final collapseMiddle = isLeg && middleCount > 0;
      if (collapseMiddle) {
        // board endpoint — connector full once the ride has started, so the
        // middle block below continues the fill with no gap.
        rows.add(_stopRow(board, board, alight,
            hasTop: beforeCount > 0 && _expandedBefore,
            hasBottom: true,
            belowFillOverride: _blockFill(board, alight) > 0 ? 1.0 : 0.0));
        // collapsible middle — continuous spine line + duration
        rows.add(_middleHeader(
          context,
          expanded: _expandedMiddle,
          count: middleCount,
          duration: _legDuration(stops, board, alight),
          fill: _blockFill(board, alight),
          onTap: () => setState(() => _expandedMiddle = !_expandedMiddle),
        ));
        if (_expandedMiddle) {
          for (var i = board + 1; i < alight; i++) {
            rows.add(_stopRow(i, board, alight, hasTop: true, hasBottom: true));
          }
        }
        // alight endpoint
        rows.add(_stopRow(alight, board, alight,
            hasTop: true, hasBottom: afterCount > 0));
      } else {
        for (var i = board; i <= alight; i++) {
          rows.add(_stopRow(
            i,
            board,
            alight,
            hasTop: i != board || (beforeCount > 0 && _expandedBefore),
            hasBottom: i != alight || (afterCount > 0),
          ));
        }
      }
    }

    // --- stops after alighting (collapsed by default) ---------------------
    if (afterCount > 0) {
      if (_expandedAfter) {
        for (var i = alight + 1; i < stops.length; i++) {
          rows.add(_stopRow(i, board, alight,
              hasTop: true, hasBottom: i != stops.length - 1));
        }
      }
      rows.add(_collapseHeader(
        context,
        expanded: _expandedAfter,
        count: afterCount,
        label: _expandedAfter
            ? 'Halte danach ausblenden'
            : '$afterCount ${afterCount == 1 ? 'Halt' : 'Halte'} danach · bis ${stops.last.stop.name}',
        onTap: () => setState(() => _expandedAfter = !_expandedAfter),
      ));
    }

    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!useInline) ...[
          if (widget.header != null) ...[
            widget.header!,
            const Divider(height: 1),
          ],
          // Wagenreihung etc. as part of the train element (standalone view).
          if (widget.trainExtra != null) widget.trainExtra!,
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Text(
              'Halte',
              style: Theme.of(context)
                  .textTheme
                  .titleSmall
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
          ),
        ],
        ...rows,
      ],
    );

    if (widget.embedded) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: body,
      );
    }
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: body,
      ),
    );
  }

  // Real-or-planned times at a stop (departure-biased / arrival-biased).
  DateTime? _depAt(int i) {
    final s = widget.stopovers[i];
    return s.departure ?? s.plannedDeparture ?? s.arrival ?? s.plannedArrival;
  }

  DateTime? _arrAt(int i) {
    final s = widget.stopovers[i];
    return s.arrival ?? s.plannedArrival ?? s.departure ?? s.plannedDeparture;
  }

  /// True once the live train has reached stop [i] (by its real/planned time).
  bool _reachedStop(int i) {
    final t = _arrAt(i);
    return t != null && !DateTime.now().isBefore(t);
  }

  /// Elapsed-time fill (0…1) of the segment LEAVING stop [i] → fully filled once
  /// the train is past stop i+1, partial while in it, empty before. Time-based,
  /// so a row's fill and the surrounding elements line up into one rail.
  double _segFill(int i) {
    if (i < 0 || i + 1 >= widget.stopovers.length) return 0; // no segment after
    final a = _depAt(i), b = _arrAt(i + 1);
    if (a == null || b == null) return 0;
    final total = b.difference(a).inSeconds;
    if (total <= 0) return DateTime.now().isBefore(b) ? 0 : 1;
    return (DateTime.now().difference(a).inSeconds / total).clamp(0.0, 1.0);
  }

  /// Progress fill (0…1) for the leg's middle block. Collapsed, the block is
  /// ONE fixed-height element standing for the whole board→alight ride, so it
  /// fills by the ride's elapsed-TIME fraction — 2 min before a 1h39 arrival is
  /// a ~2% sliver, exactly what the rider expects. Expanded, it's only the
  /// board→first-intermediate connector, so it fills by that one segment.
  double _blockFill(int board, int alight) =>
      _expandedMiddle ? _segFill(board) : _rideTimeFraction(board, alight);

  /// Elapsed-time fraction of the board→alight ride (real times, planned
  /// fallback), independent of how many stops lie between.
  double _rideTimeFraction(int board, int alight) {
    final stops = widget.stopovers;
    final d = stops[board].departure ?? stops[board].plannedDeparture;
    final a = stops[alight].arrival ?? stops[alight].plannedArrival;
    if (d == null || a == null) return 0;
    final total = a.difference(d).inSeconds;
    if (total <= 0) return 0;
    return (DateTime.now().difference(d).inSeconds / total).clamp(0.0, 1.0);
  }

  /// A vertical timeline rail filled solid (brand colour) for [fill] of its
  /// height from the top, the rest a muted track — the shared progress look.
  Widget _progressSpine(BuildContext context, double fill) {
    final theme = Theme.of(context);
    final done = theme.colorScheme.primary;
    final faint = theme.colorScheme.outlineVariant;
    final ff = (fill.clamp(0.0, 1.0) * 1000).round();
    return SizedBox(
      width: 20,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (ff > 0) Expanded(flex: ff, child: Container(width: 4, color: done)),
          if (ff < 1000)
            Expanded(flex: 1000 - ff, child: Container(width: 2, color: faint)),
        ],
      ),
    );
  }

  /// One real stop row, wired into the timeline.
  ///
  /// [belowFillOverride] forces the fill of the line LEAVING this stop — used
  /// for an endpoint that connects into the train-card block: that short
  /// connector must be FULL as soon as the block has any progress, so the rail
  /// reads as one continuous bar instead of "partial, gap, then the block".
  Widget _stopRow(int i, int board, int alight,
      {required bool hasTop,
      required bool hasBottom,
      double? belowFillOverride}) {
    final s = widget.stopovers[i];
    final inSegment = i >= board && i <= alight;
    final isEndpoint = i == board || i == alight;
    final isLeg = widget.boardingId != null || widget.alightingId != null;
    final isBoard = isLeg && i == board;
    return InkWell(
      onTap: widget.onStopTap == null ? null : () => widget.onStopTap!(s),
      child: _StopRow(
        stopover: s,
        hasTop: hasTop,
        hasBottom: hasBottom,
        // Time-based, so every stacked element (this row, the train-card block,
        // the next row) shares ONE basis and the fill flows continuously
        // through all of them instead of stopping at each boundary.
        dotReached: _reachedStop(i),
        belowFill: belowFillOverride ?? _segFill(i),
        emphasize: isEndpoint,
        // The alight endpoint shows YOUR arrival as its one time, not the
        // train's onward departure; board/intermediate are departure-first.
        arrivalPrimary: isEndpoint && i == alight,
        // Stops outside the ridden segment are visually muted.
        muted: !inSegment,
        // The boarding stop's per-stop occupancy duplicates the ride-wide one in
        // the train header just below it → drop it here.
        hideOccupancy: isBoard,
        // Wing-train split banner sits under the boarding stop, beneath the name.
        footer: isBoard ? widget.boardingBanner : null,
      ),
    );
  }

  /// Tappable "N Halte vorher / danach" pill that expands the hidden stops.
  Widget _collapseHeader(BuildContext context,
      {required bool expanded,
      required int count,
      required String label,
      required VoidCallback onTap}) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 6, 16, 6),
        child: Row(
          children: [
            // Mirror the Zwischenhalte row exactly: spine (52) + gap (12) +
            // line column (20) + gap (12) → the content (icon + label) lines up
            // with the "N Zwischenhalte" text, not just the stop names.
            const SizedBox(width: _kSpineWidth),
            const SizedBox(width: 12),
            const SizedBox(width: 20),
            const SizedBox(width: 12),
            Icon(expanded ? Icons.unfold_less : Icons.more_horiz,
                size: 18, color: theme.colorScheme.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Icon(expanded ? Icons.expand_less : Icons.expand_more,
                size: 18, color: theme.colorScheme.primary),
          ],
        ),
      ),
    );
  }

  /// Collapsed middle of a leg: the spine line runs straight through (no break)
  /// with the leg duration on the left, and the expander icon + label sit in
  /// the content column — mirrors the DB Navigator look.
  Widget _middleHeader(BuildContext context,
      {required bool expanded,
      required int count,
      required String? duration,
      required double fill,
      required VoidCallback onTap}) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;
    final amenities = widget.legAmenities;
    return InkWell(
      onTap: onTap,
      child: IntrinsicHeight(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 16, 0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // spine: leg duration, centred between the two stop times
              SizedBox(
                width: _kSpineWidth,
                child: duration == null
                    ? const SizedBox.shrink()
                    : Align(
                        // Vertically centred in the gap between the two stop
                        // times, right-aligned so it sits in the same column.
                        alignment: Alignment.centerRight,
                        child: Text(
                          duration,
                          textAlign: TextAlign.right,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
              ),
              const SizedBox(width: 12),
              // Progress timeline line — fills as far as the train has come.
              _progressSpine(context, fill),
              const SizedBox(width: 12),
              // content: expander row + (optional) leg-wide amenities below
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(expanded ? Icons.unfold_less : Icons.more_horiz,
                              size: 18, color: primary),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '$count ${count == 1 ? 'Zwischenhalt' : 'Zwischenhalte'}'
                              '${expanded ? ' ausblenden' : ' anzeigen'}',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: primary,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          Icon(expanded ? Icons.expand_less : Icons.expand_more,
                              size: 18, color: primary),
                        ],
                      ),
                      if (amenities.isNotEmpty) ...[
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 12,
                          runSpacing: 6,
                          children: [
                            for (final a in amenities)
                              Tooltip(
                                message: a.label,
                                child: Icon(a.icon,
                                    size: 17,
                                    color:
                                        theme.colorScheme.onSurfaceVariant),
                              ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Leg duration "Xh Ymin" / "Ymin" from board departure to alight arrival.
  String? _legDuration(List<Stopover> stops, int board, int alight) {
    final depT = stops[board].departure ?? stops[board].plannedDeparture;
    final arrT = stops[alight].arrival ?? stops[alight].plannedArrival;
    if (depT == null || arrT == null) return null;
    final d = arrT.difference(depT);
    if (d.isNegative) return null;
    final h = d.inHours;
    final m = d.inMinutes % 60;
    return h > 0 ? '${h}h ${m}min' : '${m}min';
  }

  /// The train card rendered inline on the route spine (DB-Navigator style),
  /// sitting between the board and alight endpoints with a continuous line. Holds
  /// the train header (line, direction, per-train prediction, occupancy, action)
  /// and — when the leg has intermediate stops — the "N Zwischenhalte" expander
  /// (reusing [_expandedMiddle]) plus the leg-wide amenities.
  Widget _inlineTrainBlock(BuildContext context,
      {required int middleCount,
      required String? duration,
      required bool expandable,
      required double fill,
      Widget? extra}) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;
    final amenities = widget.legAmenities;
    final expanded = _expandedMiddle;

    // The tappable train part (header + Zwischenhalte expander + amenities).
    // Left-padded by 12 so its content lines up at the same column (x≈92) as
    // the stop names and the Wagenreihung's own inner padding below.
    final trainPart = InkWell(
      onTap: expandable
          ? () => setState(() => _expandedMiddle = !_expandedMiddle)
          : null,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 0, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.header != null) widget.header!,
            if (expandable) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  Icon(expanded ? Icons.unfold_less : Icons.more_horiz,
                      size: 18, color: primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '$middleCount ${middleCount == 1 ? 'Zwischenhalt' : 'Zwischenhalte'}'
                      '${expanded ? ' ausblenden' : ' anzeigen'}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Icon(expanded ? Icons.expand_less : Icons.expand_more,
                      size: 18, color: primary),
                ],
              ),
            ],
            if (amenities.isNotEmpty) ...[
              const SizedBox(height: 10),
              Wrap(
                spacing: 12,
                runSpacing: 6,
                children: [
                  for (final a in amenities)
                    Tooltip(
                      message: a.label,
                      child: Icon(a.icon,
                          size: 17,
                          color: theme.colorScheme.onSurfaceVariant),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );

    return IntrinsicHeight(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 0, 16, 0),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // spine gutter: leg duration, vertically centred across the WHOLE
            // block (train header + Wagenreihung) — i.e. midway between the
            // board departure above and the alight arrival below, regardless of
            // what's stacked between them.
            SizedBox(
              width: _kSpineWidth,
              child: duration == null
                  ? const SizedBox.shrink()
                  : Align(
                      alignment: Alignment.centerRight,
                      child: Text(
                        duration,
                        textAlign: TextAlign.right,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
            ),
            const SizedBox(width: 12),
            // Progress timeline line down the whole block's left side — fills
            // solid as far as the live train has come through the ride.
            _progressSpine(context, fill),
            // No extra gap here: trainPart's left:12 and the Wagenreihung's own
            // inner 12 both land the content at the same column as the stops.
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  trainPart,
                  ?extra,
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StopRow extends StatelessWidget {
  final Stopover stopover;
  final bool hasTop;
  final bool hasBottom;
  final bool emphasize;
  final bool muted;

  /// Suppress this stop's per-stop occupancy line (used on the boarding stop,
  /// where the ride-wide occupancy in the train header just below would dupe it).
  final bool hideOccupancy;

  /// Extra content rendered at the bottom of this stop's text column, aligned
  /// under the station name (the wing-train split banner on the boarding stop).
  final Widget? footer;

  /// This stop is your alight endpoint: its single spine time is YOUR arrival,
  /// not the train's onward departure. Board/intermediate stops are
  /// departure-first. Endpoints never show the secondary "an/ab" dwell detail —
  /// that belongs to (expanded) intermediate stops only.
  final bool arrivalPrimary;

  /// The live train has reached/passed this stop → its dot and the line above
  /// it are drawn solid (done), not faint.
  final bool dotReached;

  /// How far the train is through the segment that LEAVES this stop (0…1) →
  /// fills that fraction of the line below the dot solid, the rest faint.
  final double belowFill;

  /// Fixed height of the station-name row. The timeline dot targets its centre,
  /// so every dot — endpoints (big Gleis chip) and intermediate stops alike —
  /// sits at the same vertical offset and lines up with its name.
  static const double _nameRowHeight = 26.0;

  const _StopRow({
    required this.stopover,
    required this.hasTop,
    required this.hasBottom,
    this.emphasize = false,
    this.muted = false,
    this.hideOccupancy = false,
    this.footer,
    this.arrivalPrimary = false,
    this.dotReached = false,
    this.belowFill = 0,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isPast = stopover.isPast;
    final cancelled = stopover.cancelled;
    var textColor = isPast
        ? theme.colorScheme.onSurfaceVariant.withAlpha(150)
        : theme.colorScheme.onSurface;
    if (muted) textColor = textColor.withAlpha(130);

    // Spine time: your alight endpoint shows ARRIVAL; board/intermediate stops
    // show departure (falling back to the other when one is absent).
    final spinePlanned = arrivalPrimary
        ? (stopover.plannedArrival ?? stopover.plannedDeparture)
        : (stopover.plannedDeparture ?? stopover.plannedArrival);
    final spineReal = arrivalPrimary
        ? (stopover.arrival ?? stopover.departure)
        : (stopover.departure ?? stopover.arrival);
    final spineDelay = arrivalPrimary
        ? (stopover.arrivalDelay ?? stopover.departureDelay)
        : (stopover.departureDelay ?? stopover.arrivalDelay);

    // The "an HH:MM / ab HH:MM" dwell detail — intermediate stops only (an
    // endpoint shows just its one relevant time, DB-app style). Shown when the
    // stop actually dwells (both times present and differing).
    final showAnAb = !emphasize &&
        stopover.plannedArrival != null &&
        stopover.plannedDeparture != null &&
        stopover.plannedArrival != stopover.plannedDeparture;

    // Progress colouring: a stop/segment the live train has reached is drawn
    // solid in the brand colour; what's still ahead is faint.
    final reached = dotReached && !muted;
    final doneColor = theme.colorScheme.primary;
    final dotColor = cancelled
        ? Colors.red
        : muted
            ? theme.colorScheme.outlineVariant
            : reached
                ? doneColor
                : theme.colorScheme.primary.withAlpha(90);

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 16, 0),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Time spine column
            SizedBox(
              width: _kSpineWidth,
              child: _spineTime(
                  spinePlanned, spineReal, spineDelay, cancelled, textColor),
            ),

            const SizedBox(width: 12),

            // Timeline line. The dot is pushed down by `topGap` so its centre
            // lines up with the vertical centre of the (fixed-height) station
            // name row beside it — same offset on every row, big chip or not,
            // so the first dot, last dot and every name align identically.
            Builder(builder: (context) {
              // The not-yet-reached line must stay clearly visible (a solid
              // muted track), not a near-invisible tint — otherwise the rail
              // looks broken between a reached stop and the next.
              final faint = theme.colorScheme.outlineVariant;
              final dotSize = emphasize ? 14.0 : 10.0;
              final topGap = _nameRowHeight / 2 - dotSize / 2;
              // The line ABOVE the dot belongs to the segment that arrives here;
              // it's done once the train has reached this stop.
              final topDone = reached;
              // The line BELOW splits into a solid "done" part (belowFill) and a
              // faint "ahead" part.
              final fill = muted ? 0.0 : belowFill.clamp(0.0, 1.0);
              final fillFlex = (fill * 1000).round();
              return SizedBox(
                width: 20,
                child: Column(
                  children: [
                    SizedBox(
                      height: topGap,
                      child: hasTop
                          ? Container(
                              width: topDone ? 4 : 2,
                              color: topDone ? doneColor : faint)
                          : null,
                    ),
                    Container(
                      width: dotSize,
                      height: dotSize,
                      decoration: BoxDecoration(
                        color: dotColor,
                        shape: BoxShape.circle,
                        border: emphasize
                            ? Border.all(
                                color: theme.colorScheme.primary.withAlpha(100),
                                width: 2)
                            : null,
                      ),
                    ),
                    if (hasBottom)
                      Expanded(
                        child: Column(
                          children: [
                            if (fillFlex > 0)
                              Expanded(
                                flex: fillFlex,
                                child: Container(width: 4, color: doneColor),
                              ),
                            if (fillFlex < 1000)
                              Expanded(
                                flex: 1000 - fillFlex,
                                child: Container(width: 2, color: faint),
                              ),
                          ],
                        ),
                      ),
                  ],
                ),
              );
            }),

            const SizedBox(width: 12),

            // Station info
            Expanded(
              child: Padding(
                // Inter-stop gap below the row — dropped to a minimum on the
                // last visible stop (no line continues), so there's no dead
                // space under e.g. the alight station. With a footer (the
                // wing-train split banner) the train card sits right under it,
                // so we tighten the gap — no ~1cm of dead space between them.
                padding: EdgeInsets.only(
                    bottom: footer != null ? 6 : (hasBottom ? 22 : 4)),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Name row: at least [_nameRowHeight] so the taller endpoint
                    // Gleis chip never shifts the name relative to the timeline
                    // dot (which targets that same centre) — but free to grow.
                    // It used to be a hard SizedBox, which cut a two-line
                    // station name off mid-glyph: the second line was there,
                    // just clipped to its first pixel row (#57).
                    ConstrainedBox(
                      constraints:
                          const BoxConstraints(minHeight: _nameRowHeight),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Expanded(
                            child: Text(
                              stopover.stop.name,
                              // Two lines is enough for the longest real name
                              // ("Frankfurt (Main) Flughafen Fernbahnhof");
                              // past that the row would push the timeline apart.
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: emphasize
                                    ? FontWeight.bold
                                    : FontWeight.w500,
                                color: cancelled ? Colors.red : textColor,
                                decoration: cancelled
                                    ? TextDecoration.lineThrough
                                    : null,
                              ),
                            ),
                          ),
                          // Gleis lives on the right, on the same line as the
                          // station name: blue-bordered normally, red-bordered
                          // (with struck-through old platform) when it changed.
                          if (stopover.platform != null ||
                              stopover.plannedPlatform != null) ...[
                            const SizedBox(width: 8),
                            _platformChip(context, big: emphasize),
                          ],
                        ],
                      ),
                    ),

                    // an HH:MM / ab HH:MM with realtime + red delay.
                    if (showAnAb)
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Wrap(
                          spacing: 14,
                          runSpacing: 2,
                          children: [
                            _anAb(context, 'an', stopover.plannedArrival,
                                stopover.arrival, stopover.arrivalDelay,
                                cancelled),
                            _anAb(context, 'ab', stopover.plannedDeparture,
                                stopover.departure, stopover.departureDelay,
                                cancelled),
                          ],
                        ),
                      ),

                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        if (cancelled)
                          Text('Ausfall',
                              style: TextStyle(
                                  color: theme.colorScheme.error,
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold)),
                        // A stop the train picked up that isn't timetabled —
                        // without this the rider can't tell an extra stop from
                        // a normal one, which is what makes a diversion
                        // readable as a route change rather than a delay (#17).
                        if (stopover.additional)
                          Text('Zusatzhalt',
                              style: TextStyle(
                                  color: Colors.amber.shade800,
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold)),
                        // The train stops here but won't let you on/off. Looks
                        // like an ordinary stop otherwise, so anyone planning
                        // to board or change here would only find out on the
                        // platform.
                        if (!cancelled &&
                            (stopover.noBoarding || stopover.noAlighting))
                          Text(
                              stopover.serviceNote ??
                                  (stopover.noBoarding
                                      ? 'Hält nur zum Aussteigen'
                                      : 'Hält nur zum Einsteigen'),
                              style: TextStyle(
                                  color: Colors.amber.shade800,
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold)),
                        if (!hideOccupancy &&
                            stopover.occupancy != OccupancyLevel.unknown)
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              OccupancyIndicator(level: stopover.occupancy),
                              const SizedBox(width: 4),
                              Text(
                                stopover.occupancy.expectedLabel,
                                style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant),
                              ),
                            ],
                          ),
                      ],
                    ),
                    if (footer != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 2, right: 4),
                        child: footer,
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Gleis chip, right-aligned on the station-name line. Blue outline normally;
  /// red outline + struck-through old platform when the Gleis changed. [big]
  /// scales it up for leg endpoints (Einstieg/Ausstieg) — the platform is the
  /// single most-looked-for fact, so it gets a prominent badge there.
  Widget _platformChip(BuildContext context, {bool big = false}) {
    final theme = Theme.of(context);
    final display = stopover.platform ?? stopover.plannedPlatform;
    if (display == null || display.isEmpty) return const SizedBox.shrink();
    final changed = stopover.platform != null &&
        stopover.plannedPlatform != null &&
        stopover.platform != stopover.plannedPlatform;
    final color = changed ? Colors.red : Colors.blue;
    return Container(
      padding: big
          ? const EdgeInsets.symmetric(horizontal: 7, vertical: 3)
          : const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
            color: color.withAlpha(muted ? 120 : 200), width: big ? 1.2 : 1),
        color: color.withAlpha(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          TrackIcon(
              size: big ? 14 : 13,
              color: changed
                  ? Colors.red
                  : (muted
                      ? theme.colorScheme.onSurfaceVariant
                      : color)),
          SizedBox(width: big ? 4 : 3),
          if (changed && stopover.plannedPlatform != null) ...[
            Text(
              stopover.plannedPlatform!,
              style: TextStyle(
                fontSize: big ? 12 : 11,
                color: theme.colorScheme.onSurfaceVariant,
                decoration: TextDecoration.lineThrough,
              ),
            ),
            SizedBox(width: big ? 4 : 4),
          ],
          Text(
            display,
            style: TextStyle(
              fontSize: big ? 13 : 12,
              fontWeight: big ? FontWeight.w800 : FontWeight.w700,
              color: changed
                  ? Colors.red
                  : (muted
                      ? theme.colorScheme.onSurfaceVariant
                      : theme.colorScheme.onSurface),
            ),
          ),
        ],
      ),
    );
  }

  /// Left "spine" time: planned struck through + realtime in red on delay.
  Widget _spineTime(DateTime? planned, DateTime? real, int? delaySec,
      bool cancelled, Color baseColor) {
    if (planned == null) return const SizedBox.shrink();
    final delayed = !cancelled && (delaySec ?? 0) >= 60;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        // Planned time occupies the same fixed-height row as the station name,
        // vertically centred — so it lines up with the timeline dot (which
        // targets that same centre), not floating above it.
        SizedBox(
          height: _nameRowHeight,
          child: Align(
            alignment: Alignment.centerRight,
            child: Text(
              planned.hhmm,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: cancelled
                    ? Colors.red
                    : (delayed ? baseColor.withAlpha(140) : baseColor),
                decoration: (cancelled || delayed)
                    ? TextDecoration.lineThrough
                    : null,
              ),
            ),
          ),
        ),
        if (delayed && real != null)
          Text(
            real.hhmm,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.bold,
              color: delaySec.delayColor,
            ),
          ),
      ],
    );
  }

  /// "an"/"ab" chunk: label + planned (struck on delay) + realtime + "+N" red.
  Widget _anAb(BuildContext context, String label, DateTime? planned,
      DateTime? real, int? delaySec, bool cancelled) {
    if (planned == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final delayed = !cancelled && (delaySec ?? 0) >= 60;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('$label ',
            style: TextStyle(fontSize: 11, color: muted)),
        Text(
          planned.hhmm,
          style: TextStyle(
            fontSize: 11,
            color: muted,
            decoration: delayed ? TextDecoration.lineThrough : null,
          ),
        ),
        if (delayed && real != null) ...[
          const SizedBox(width: 4),
          Text(
            '${real.hhmm} (+${delaySec! ~/ 60})',
            style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                color: delaySec.delayColor),
          ),
        ],
      ],
    );
  }
}
