import 'package:flutter/material.dart';
import '../../../models/journey.dart' show OccupancyLevel;
import '../../../models/trip.dart';
import '../../../core/extensions.dart';
import '../../../widgets/occupancy_indicator.dart';
import '../../../widgets/platform_badge.dart';

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

  const StopTimeline({
    super.key,
    required this.stopovers,
    this.onStopTap,
    this.boardingId,
    this.alightingId,
    this.legAmenities = const [],
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

    // --- the ridden segment -----------------------------------------------
    // Endpoints (board, alight) are always shown. On a journey leg the stops
    // between them collapse behind a "N Zwischenhalte" header; on a standalone
    // train lookup every stop stays visible.
    final middleCount = alight - board - 1;
    final collapseMiddle = isLeg && middleCount > 0;

    if (collapseMiddle) {
      // Leg duration (board departure → alight arrival), shown on the spine of
      // the collapsed middle so the gap still carries information.
      final depT =
          stops[board].departure ?? stops[board].plannedDeparture;
      final arrT =
          stops[alight].arrival ?? stops[alight].plannedArrival;
      String? legDur;
      if (depT != null && arrT != null) {
        final d = arrT.difference(depT);
        if (!d.isNegative) {
          final h = d.inHours;
          final m = d.inMinutes % 60;
          legDur = h > 0 ? '${h}h ${m}min' : '${m}min';
        }
      }
      // board endpoint
      rows.add(_stopRow(board, board, alight,
          hasTop: beforeCount > 0 && _expandedBefore, hasBottom: true));
      // collapsible middle — continuous spine line + duration
      rows.add(_middleHeader(
        context,
        expanded: _expandedMiddle,
        count: middleCount,
        duration: legDur,
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

    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
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
            ...rows,
          ],
        ),
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
        tappable: widget.onStopTap != null,
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
    return InkWell(
      onTap: onTap,
      child: IntrinsicHeight(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // spine: leg duration, vertically centred
              SizedBox(
                width: 52,
                child: duration == null
                    ? const SizedBox.shrink()
                    : Align(
                        alignment: Alignment.centerRight,
                        child: Text(
                          duration,
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
              // content: expander icon + label + chevron (pushed right)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 11),
                  child: Row(
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
  final bool tappable;

  const _StopRow({
    required this.stopover,
    required this.hasTop,
    required this.hasBottom,
    this.emphasize = false,
    this.muted = false,
    this.tappable = false,
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

            // Timeline line
            SizedBox(
              width: 20,
              child: Column(
                children: [
                  if (hasTop)
                    Container(
                      width: 2,
                      height: 8,
                      color: isPast || muted
                          ? theme.colorScheme.outlineVariant
                          : theme.colorScheme.primary.withAlpha(60),
                    ),
                  Container(
                    width: emphasize ? 14 : 10,
                    height: emphasize ? 14 : 10,
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
                      child: Container(
                        width: 2,
                        color: isPast || muted
                            ? theme.colorScheme.outlineVariant
                            : theme.colorScheme.primary.withAlpha(60),
                      ),
                    ),
                ],
              ),
            ),

            const SizedBox(width: 12),

            // Station info
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            stopover.stop.name,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight:
                                  emphasize ? FontWeight.bold : FontWeight.w500,
                              color: cancelled ? Colors.red : textColor,
                              decoration: cancelled
                                  ? TextDecoration.lineThrough
                                  : null,
                            ),
                          ),
                        ),
                        if (tappable) ...[
                          const SizedBox(width: 6),
                          Icon(Icons.map_outlined,
                              size: 15,
                              color: muted
                                  ? theme.colorScheme.primary.withAlpha(130)
                                  : theme.colorScheme.primary),
                        ],
                      ],
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
                        if (stopover.platform != null)
                          PlatformBadge(
                            platform: stopover.platform,
                            plannedPlatform: stopover.plannedPlatform,
                          ),
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
