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
    this.embedded = false,
    this.inlineHeader = false,
  });

  @override
  State<StopTimeline> createState() => _StopTimelineState();
}

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
          hasTop: beforeCount > 0 && _expandedBefore, hasBottom: true));
      rows.add(_inlineTrainBlock(
        context,
        middleCount: middleCount,
        duration: _legDuration(stops, board, alight),
        expandable: middleCount > 0,
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
        // board endpoint
        rows.add(_stopRow(board, board, alight,
            hasTop: beforeCount > 0 && _expandedBefore, hasBottom: true));
        // collapsible middle — continuous spine line + duration
        rows.add(_middleHeader(
          context,
          expanded: _expandedMiddle,
          count: middleCount,
          duration: _legDuration(stops, board, alight),
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

  /// One real stop row, wired into the timeline.
  Widget _stopRow(int i, int board, int alight,
      {required bool hasTop, required bool hasBottom}) {
    final s = widget.stopovers[i];
    final inSegment = i >= board && i <= alight;
    final isEndpoint = i == board || i == alight;
    return InkWell(
      onTap: widget.onStopTap == null ? null : () => widget.onStopTap!(s),
      child: _StopRow(
        stopover: s,
        hasTop: hasTop,
        hasBottom: hasBottom,
        emphasize: isEndpoint,
        // Stops outside the ridden segment are visually muted.
        muted: !inSegment,
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
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Row(
          children: [
            // align under the timeline dots
            const SizedBox(width: 48 + 12),
            SizedBox(
              width: 20,
              child: Icon(
                expanded ? Icons.unfold_less : Icons.more_vert,
                size: 18,
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(width: 12),
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
      required VoidCallback onTap}) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;
    final lineColor = primary.withAlpha(60);
    final amenities = widget.legAmenities;
    return InkWell(
      onTap: onTap,
      child: IntrinsicHeight(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // spine: leg duration, centred between the two stop times
              SizedBox(
                width: 52,
                child: duration == null
                    ? const SizedBox.shrink()
                    : Center(
                        child: Text(
                          duration,
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
              ),
              const SizedBox(width: 12),
              // continuous timeline line
              SizedBox(
                width: 20,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [Container(width: 2, color: lineColor)],
                ),
              ),
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
      required bool expandable}) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;
    final lineColor = primary.withAlpha(60);
    final amenities = widget.legAmenities;
    final expanded = _expandedMiddle;
    return InkWell(
      onTap: expandable
          ? () => setState(() => _expandedMiddle = !_expandedMiddle)
          : null,
      child: IntrinsicHeight(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // spine gutter: leg duration, centred against the train card
              SizedBox(
                width: 52,
                child: duration == null
                    ? const SizedBox.shrink()
                    : Center(
                        child: Text(
                          duration,
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
              ),
              const SizedBox(width: 12),
              // continuous timeline line joining the board dot to the alight dot
              SizedBox(
                width: 20,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [Container(width: 2, color: lineColor)],
                ),
              ),
              const SizedBox(width: 12),
              // content: train header + (optional) Zwischenhalte expander + amenities
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (widget.header != null) widget.header!,
                      if (expandable) ...[
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Icon(
                                expanded
                                    ? Icons.unfold_less
                                    : Icons.more_horiz,
                                size: 18,
                                color: primary),
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
                            Icon(
                                expanded
                                    ? Icons.expand_less
                                    : Icons.expand_more,
                                size: 18,
                                color: primary),
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
}

class _StopRow extends StatelessWidget {
  final Stopover stopover;
  final bool hasTop;
  final bool hasBottom;
  final bool emphasize;
  final bool muted;

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

    // Spine time = the realtime departure, else arrival.
    final spinePlanned = stopover.plannedDeparture ?? stopover.plannedArrival;
    final spineReal = stopover.departure ?? stopover.arrival;
    final spineDelay = stopover.departureDelay ?? stopover.arrivalDelay;

    // The expanded "an HH:MM / ab HH:MM" detail — only for intermediate stops
    // that actually dwell (both an and ab, and they differ).
    final showAnAb = stopover.plannedArrival != null &&
        stopover.plannedDeparture != null &&
        stopover.plannedArrival != stopover.plannedDeparture;

    final dotColor = cancelled
        ? Colors.red
        : (muted || isPast)
            ? theme.colorScheme.outlineVariant
            : theme.colorScheme.primary;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Time spine column
            SizedBox(
              width: 52,
              child: _spineTime(
                  spinePlanned, spineReal, spineDelay, cancelled, textColor),
            ),

            const SizedBox(width: 12),

            // Timeline line. The dot is pushed down by `topGap` so its centre
            // lines up with the vertical centre of the (fixed-height) station
            // name row beside it — same offset on every row, big chip or not,
            // so the first dot, last dot and every name align identically.
            Builder(builder: (context) {
              final lineColor = isPast || muted
                  ? theme.colorScheme.outlineVariant
                  : theme.colorScheme.primary.withAlpha(60);
              final dotSize = emphasize ? 14.0 : 10.0;
              final topGap = _nameRowHeight / 2 - dotSize / 2;
              return SizedBox(
                width: 20,
                child: Column(
                  children: [
                    SizedBox(
                      height: topGap,
                      child: hasTop
                          ? Container(width: 2, color: lineColor)
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
                      Expanded(child: Container(width: 2, color: lineColor)),
                  ],
                ),
              );
            }),

            const SizedBox(width: 12),

            // Station info
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 22),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Fixed-height name row, contents vertically centred, so the
                    // taller endpoint Gleis chip never shifts the name relative
                    // to the timeline dot (which targets this same centre).
                    SizedBox(
                      height: _nameRowHeight,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Expanded(
                            child: Text(
                              stopover.stop.name,
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
                        if (stopover.occupancy != OccupancyLevel.unknown)
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
        Text(
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
