import 'package:flutter/material.dart';
import '../../../models/trip.dart';
import '../../../core/extensions.dart';
import '../../../widgets/delay_badge.dart';
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

  const StopTimeline({
    super.key,
    required this.stopovers,
    this.onStopTap,
    this.boardingId,
    this.alightingId,
  });

  @override
  State<StopTimeline> createState() => _StopTimelineState();
}

class _StopTimelineState extends State<StopTimeline> {
  bool _expandedBefore = false;
  bool _expandedAfter = false;

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
    var board = _indexOf(widget.boardingId);
    var alight = _indexOf(widget.alightingId);
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

    // --- the ridden segment (always shown) --------------------------------
    for (var i = board; i <= alight; i++) {
      rows.add(_stopRow(
        i,
        board,
        alight,
        hasTop: i != board || (beforeCount > 0 && _expandedBefore),
        hasBottom: i != alight || (afterCount > 0),
      ));
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
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Text(
                'Halte',
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
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
    var textColor = isPast
        ? theme.colorScheme.onSurfaceVariant.withAlpha(150)
        : theme.colorScheme.onSurface;
    if (muted) textColor = textColor.withAlpha(130);

    // Times
    final arrTime = stopover.plannedArrival?.hhmm;
    final depTime = stopover.plannedDeparture?.hhmm;
    final displayTime = depTime ?? arrTime;

    final dotColor = stopover.cancelled
        ? Colors.red
        : muted
            ? theme.colorScheme.outlineVariant
            : isPast
                ? theme.colorScheme.outlineVariant
                : theme.colorScheme.primary;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Time column
            SizedBox(
              width: 48,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (displayTime != null)
                    Text(
                      displayTime,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: stopover.cancelled ? Colors.red : textColor,
                        decoration: stopover.cancelled
                            ? TextDecoration.lineThrough
                            : null,
                      ),
                    ),
                ],
              ),
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
                              color:
                                  stopover.cancelled ? Colors.red : textColor,
                              decoration: stopover.cancelled
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
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        DelayBadge(
                          delaySeconds:
                              stopover.departureDelay ?? stopover.arrivalDelay,
                          cancelled: stopover.cancelled,
                        ),
                        if (stopover.platform != null) ...[
                          const SizedBox(width: 8),
                          PlatformBadge(
                            platform: stopover.platform,
                            plannedPlatform: stopover.plannedPlatform,
                          ),
                        ],
                      ],
                    ),

                    // Show both arr and dep times for intermediate stops
                    if (!emphasize &&
                        arrTime != null &&
                        depTime != null &&
                        arrTime != depTime)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          'an $arrTime  ab $depTime',
                          style: TextStyle(
                            fontSize: 11,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
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
}
