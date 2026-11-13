import 'dart:math' as math;

import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../models/seat_map.dart';
import '../../../models/trip.dart';
import '../../../services/seat_map_service.dart';
import '../../../theme/app_colors.dart';

/// The free-seat panel, rendered *inside* the Wagenreihung card. Collapsed by
/// default — the tappable header expands it. The class of each seat is implied
/// by the coach (shown in the Wagenreihung colours), so there's no class
/// toggle: tapping a coach above shows that coach's seats. When there's no
/// Wagenreihung, the panel draws its own DB-style train strip as picker.
class SeatPlanBody extends StatelessWidget {
  final Trip trip;
  final bool expanded;
  final VoidCallback onToggle;

  /// Result of `seatMapProvider`; null while collapsed (not yet watched).
  final AsyncValue<SeatMap?>? seatAsync;

  /// The wagon currently selected (already resolved to a sensible default by
  /// the parent), and the tap callback to change it.
  final int? selectedWagon;
  final ValueChanged<int> onSelectWagon;

  /// True when the Wagenreihung above already acts as the coach picker, so we
  /// must not draw a second strip here.
  final bool hasExternalSelector;

  const SeatPlanBody({
    super.key,
    required this.trip,
    required this.expanded,
    required this.onToggle,
    required this.seatAsync,
    required this.selectedWagon,
    required this.onSelectWagon,
    required this.hasExternalSelector,
  });

  /// Whether this train carries a reservable seat plan worth offering.
  static bool isAvailableFor(Trip trip) {
    final p = trip.line.productName.toUpperCase();
    return SeatMapService.reservableProducts.contains(p) &&
        trip.stopovers.length >= 2;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final async = seatAsync;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Tappable collapse header (compact).
        InkWell(
          onTap: onToggle,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                const Icon(Icons.event_seat, size: 17, color: AppColors.onTime),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Freie Sitzplätze',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                Icon(
                  expanded ? Icons.expand_less : Icons.expand_more,
                  size: 20,
                ),
              ],
            ),
          ),
        ),
        if (expanded)
          if (async == null)
            const SizedBox(height: 8)
          else
            async.when(
              loading: () => const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (e, _) =>
                  _info(theme, 'Sitzplan konnte nicht geladen werden.'),
              data: (map) {
                if (map == null || map.isEmpty) {
                  return _info(
                    theme,
                    'Für diesen Zug ist kein Sitzplan verfügbar.',
                  );
                }
                return _content(theme, map);
              },
            ),
      ],
    );
  }

  Widget _content(ThemeData theme, SeatMap map) {
    final coach = _selectedCoach(map);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
          child: Text(
            '${map.totalFree} von ${map.totalSeats} Plätzen frei'
            '${coach != null ? '  ·  Wagen ${coach.number}: ${coach.freeCount} frei' : map.freeCoachHint}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        // Own DB-style train strip only when there's no Wagenreihung selector.
        if (!hasExternalSelector)
          _TrainStrip(
            map: map,
            selectedWagon: selectedWagon,
            onSelect: onSelectWagon,
          ),
        if (coach == null)
          _info(theme, 'Wagen oben antippen, um den Sitzplan zu sehen.')
        else if (coach.layout == null)
          Padding(
            padding: const EdgeInsets.all(16),
            child: _coachFallback(theme, coach),
          )
        else
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 12),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Container(
                color: theme.colorScheme.surfaceContainerHighest.withValues(
                  alpha: 0.35,
                ),
                // The coach is drawn vertically now (long axis top-to-bottom),
                // so it scrolls DOWN inside a bounded window and fits the phone
                // width instead of being a cramped sideways strip.
                child: SizedBox(
                  height: 380,
                  child: SingleChildScrollView(
                    scrollDirection: Axis.vertical,
                    padding: const EdgeInsets.symmetric(
                      vertical: 12,
                      horizontal: 12,
                    ),
                    child: Center(
                      child: CoachSeatPlan(coach: coach, layout: coach.layout!),
                    ),
                  ),
                ),
              ),
            ),
          ),
        _legend(theme),
      ],
    );
  }

  /// The coach matching [selectedWagon], else the first with free seats.
  SeatCoach? _selectedCoach(SeatMap map) {
    if (map.coaches.isEmpty) return null;
    if (selectedWagon != null) {
      for (final c in map.coaches) {
        if (int.tryParse(c.number) == selectedWagon) return c;
      }
    }
    for (final c in map.coaches) {
      if (c.hasFree) return c;
    }
    return map.coaches.first;
  }

  Widget _coachFallback(ThemeData theme, SeatCoach coach) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final s in coach.seats)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: _statusColor(s.status),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              s.number,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: s.status == SeatStatus.free
                    ? Colors.white
                    : theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );
  }

  Widget _legend(ThemeData theme) {
    Widget chip(Color c, String label) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 11,
          height: 11,
          decoration: BoxDecoration(
            color: c,
            borderRadius: BorderRadius.circular(3),
          ),
        ),
        const SizedBox(width: 5),
        Text(label, style: theme.textTheme.labelSmall),
      ],
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Wrap(
        spacing: 16,
        runSpacing: 8,
        children: [
          chip(AppColors.onTime, 'frei'),
          chip(AppColors.closedCoach, 'reserviert'),
        ],
      ),
    );
  }

  Widget _info(ThemeData theme, String msg) => Padding(
    padding: const EdgeInsets.all(20),
    child: Row(
      children: [
        Icon(
          Icons.info_outline,
          size: 20,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            msg,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    ),
  );
}

Color _statusColor(SeatStatus s) {
  switch (s) {
    case SeatStatus.free:
      return AppColors.onTime;
    case SeatStatus.occupied:
    case SeatStatus.unknown:
      return AppColors.closedCoach;
  }
}

/// Fallback DB-style train strip (used only when no Wagenreihung is present).
/// Draws a rounded nose at both ends and a class-coloured block per coach with
/// its free-seat count; tapping selects a coach.
class _TrainStrip extends StatelessWidget {
  final SeatMap map;
  final int? selectedWagon;
  final ValueChanged<int> onSelect;

  const _TrainStrip({
    required this.map,
    required this.selectedWagon,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: 70,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        itemCount: map.coaches.length + 2,
        itemBuilder: (_, i) {
          if (i == 0) return const _Nose(front: true);
          if (i == map.coaches.length + 1) return const _Nose(front: false);
          final c = map.coaches[i - 1];
          final nr = int.tryParse(c.number);
          final isSel = nr != null && nr == selectedWagon;
          final first = c.layout?.klasse == 'KLASSE_1';
          final classColor = first
              ? AppColors.firstClass
              : AppColors.secondClass;
          final full = !c.hasFree;
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 1),
            child: InkWell(
              onTap: nr != null ? () => onSelect(nr) : null,
              borderRadius: BorderRadius.circular(5),
              child: Container(
                width: 52,
                decoration: BoxDecoration(
                  color: isSel
                      ? AppColors.onTime.withValues(alpha: 0.18)
                      : theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(5),
                  border: Border.all(
                    color: isSel ? AppColors.onTime : classColor,
                    width: isSel ? 2.5 : 2,
                  ),
                ),
                clipBehavior: Clip.antiAlias,
                child: Column(
                  children: [
                    Container(height: 5, color: classColor),
                    Expanded(
                      child: Center(
                        child: Text(
                          'Wg ${c.number}',
                          style: theme.textTheme.labelMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(
                        '${c.freeCount} frei',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: full
                              ? AppColors.closedCoach
                              : AppColors.onTime,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// A rounded ICE-style nose cap for the ends of the fallback train strip.
class _Nose extends StatelessWidget {
  final bool front;
  const _Nose({required this.front});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 26,
      margin: const EdgeInsets.symmetric(horizontal: 1),
      decoration: BoxDecoration(
        color: AppColors.locomotive,
        borderRadius: front
            ? const BorderRadius.horizontal(
                left: Radius.circular(22),
                right: Radius.circular(4),
              )
            : const BorderRadius.horizontal(
                left: Radius.circular(4),
                right: Radius.circular(22),
              ),
      ),
      child: const Center(
        child: Icon(Icons.train, color: Colors.white, size: 16),
      ),
    );
  }
}

/// Bounding box of a coach layout's elements, in grid units. Used to centre the
/// plan within its canvas (the raw grid leaves uneven top/bottom margins).
class _Bounds {
  final double minX, minY, maxX, maxY;
  const _Bounds(this.minX, this.minY, this.maxX, this.maxY);
  double get width => maxX - minX;
  double get height => maxY - minY;

  factory _Bounds.of(CoachLayout layout) {
    double minX = double.infinity, minY = double.infinity;
    double maxX = -double.infinity, maxY = -double.infinity;
    for (final el in layout.elements) {
      final ext = el.type == LayoutElementType.platz ? 3.0 : 2.4;
      minX = math.min(minX, el.x);
      minY = math.min(minY, el.y);
      maxX = math.max(maxX, el.x + ext);
      maxY = math.max(maxY, el.y + ext);
    }
    if (minX == double.infinity) {
      return const _Bounds(0, 0, 1, 1);
    }
    return _Bounds(minX, minY, maxX, maxY);
  }
}

/// Renders one coach's seat plan from DB grid geometry, centred in its canvas.
///
/// Drawn ROTATED 90°: the coach runs top-to-bottom (its long axis is vertical),
/// so it fits a phone's width and scrolls vertically instead of being a wide,
/// short strip you had to scroll sideways. DB's grid is X = along the train,
/// Y = across it; we map grid-X → screen-Y and grid-Y → screen-X.
class CoachSeatPlan extends StatelessWidget {
  final SeatCoach coach;
  final CoachLayout layout;

  /// px per grid unit — bumped up on the fullscreen screen for a bigger plan.
  final double unit;

  /// Seat numbers in this coach the rider holds (their reservation): drawn in
  /// their own colour with a ring, so "your seat" is found at a glance.
  final Set<String> mySeats;

  const CoachSeatPlan({
    super.key,
    required this.coach,
    required this.layout,
    this.unit = 7.0,
    this.mySeats = const {},
  });

  static const _margin = 2.0; // grid-unit padding around the content

  @override
  Widget build(BuildContext context) {
    final b = _Bounds.of(layout);
    // Rotated: on-screen width comes from the grid's short (Y) axis, height
    // from the long (X) axis.
    final w = (b.height + _margin * 2) * unit;
    final h = (b.width + _margin * 2) * unit;
    return CustomPaint(
      size: Size(w, h),
      painter: _CoachPainter(
        coach: coach,
        layout: layout,
        bounds: b,
        unit: unit,
        margin: _margin,
        onSurfaceVariant: Theme.of(context).colorScheme.onSurfaceVariant,
        mySeats: mySeats,
      ),
    );
  }
}

class _CoachPainter extends CustomPainter {
  final SeatCoach coach;
  final CoachLayout layout;
  final _Bounds bounds;
  final double unit;
  final double margin;
  final Color onSurfaceVariant;
  final Set<String> mySeats;

  _CoachPainter({
    required this.coach,
    required this.layout,
    required this.bounds,
    required this.unit,
    required this.margin,
    required this.onSurfaceVariant,
    this.mySeats = const {},
  });

  // Translate a grid coordinate into canvas pixels (content centred via bbox).
  // Rotated 90°: grid-X (along the train) → screen-Y (down), grid-Y (across)
  // → screen-X (right), so the coach reads top-to-bottom.
  Offset _p(double x, double y) => Offset(
    (y - bounds.minY + margin) * unit,
    (x - bounds.minX + margin) * unit,
  );

  @override
  void paint(Canvas canvas, Size size) {
    // Coach body outline filling the canvas (uniform margin all around).
    final body = RRect.fromRectAndRadius(
      Rect.fromLTWH(
        unit * 0.6,
        unit * 0.6,
        size.width - unit * 1.2,
        size.height - unit * 1.2,
      ),
      Radius.circular(unit * 1.5),
    );
    canvas.drawRRect(
      body,
      Paint()
        ..color = onSurfaceVariant.withValues(alpha: 0.25)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );

    final seatSize = unit * 3.0;
    for (final el in layout.elements) {
      final o = _p(el.x, el.y);
      switch (el.type) {
        case LayoutElementType.platz:
          _paintSeat(canvas, el, o, seatSize);
          break;
        case LayoutElementType.einbau:
          _paintFixture(canvas, el, o);
          break;
        case LayoutElementType.symbol:
          _paintSymbol(canvas, el, o);
          break;
        case LayoutElementType.unknown:
          break;
      }
    }
  }

  void _paintSeat(Canvas canvas, LayoutElement el, Offset o, double s) {
    final status = coach.statusOf(el.number ?? '');
    final mine = mySeats.contains(el.number);
    final rect = Rect.fromLTWH(o.dx, o.dy, s, s);
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, Radius.circular(unit * 0.6)),
      Paint()..color = mine ? AppColors.mySeat : _statusColor(status),
    );
    if (mine) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          rect.inflate(unit * 0.45),
          Radius.circular(unit * 0.9),
        ),
        Paint()
          ..color = AppColors.mySeat
          ..style = PaintingStyle.stroke
          ..strokeWidth = unit * 0.35,
      );
    }

    // Backrest: a thicker bar on the side the seat faces. Directions are
    // remapped for the 90° rotation (grid-X→screen-Y, grid-Y→screen-X):
    // links→top, rechts→bottom, oben→left, unten→right.
    final back = Paint()
      ..color = Colors.black.withValues(alpha: 0.22)
      ..strokeWidth = unit * 0.7
      ..strokeCap = StrokeCap.round;
    switch (el.direction) {
      case ElementDirection.links:
        canvas.drawLine(rect.topLeft, rect.topRight, back);
        break;
      case ElementDirection.rechts:
        canvas.drawLine(rect.bottomLeft, rect.bottomRight, back);
        break;
      case ElementDirection.oben:
        canvas.drawLine(rect.topLeft, rect.bottomLeft, back);
        break;
      case ElementDirection.unten:
        canvas.drawLine(rect.topRight, rect.bottomRight, back);
        break;
      case ElementDirection.none:
        break;
    }

    if (el.number?.isNotEmpty ?? false) {
      final tp = TextPainter(
        text: TextSpan(
          text: el.number,
          style: TextStyle(
            fontSize: unit * 1.25,
            height: 1.0,
            fontWeight: FontWeight.w700,
            color: (mine || status == SeatStatus.free)
                ? Colors.white
                : Colors.black.withValues(alpha: 0.55),
          ),
        ),
        textAlign: TextAlign.center,
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: s);
      // Centre the glyph box within the seat square.
      tp.paint(
        canvas,
        Offset(o.dx + (s - tp.width) / 2, o.dy + (s - tp.height) / 2),
      );
    }
  }

  void _paintFixture(Canvas canvas, LayoutElement el, Offset o) {
    final sub = el.subtype ?? '';
    if (sub.startsWith('TISCH')) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(o.dx, o.dy, unit * 2.4, unit * 2.4),
          Radius.circular(unit * 0.4),
        ),
        Paint()..color = onSurfaceVariant.withValues(alpha: 0.3),
      );
    } else if (sub.startsWith('WAND')) {
      // Rotated: a partition that ran across the train is horizontal now.
      canvas.drawLine(
        Offset(o.dx, o.dy),
        Offset(o.dx + unit * 2.4, o.dy),
        Paint()
          ..color = onSurfaceVariant.withValues(alpha: 0.45)
          ..strokeWidth = unit * 0.6,
      );
    }
  }

  void _paintSymbol(Canvas canvas, LayoutElement el, Offset o) {
    final box = Rect.fromLTWH(o.dx, o.dy, unit * 2.8, unit * 2.8);
    final rr = RRect.fromRectAndRadius(box, Radius.circular(unit * 0.5));

    // Class markers ("1"/"2") render as a coloured chip — green for 2nd class,
    // gold for 1st — like DB's own coach class badge.
    final cls = _classMarker(el.subtype);
    if (cls != null) {
      final col = cls == '1' ? AppColors.firstClass : AppColors.onTime;
      canvas.drawRRect(rr, Paint()..color = col.withValues(alpha: 0.20));
      canvas.drawRRect(
        rr,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..color = col,
      );
      _centerText(
        canvas,
        box,
        cls,
        TextStyle(
          fontSize: unit * 1.7,
          height: 1.0,
          fontWeight: FontWeight.w800,
          color: cls == '1' ? const Color(0xFF8A6D00) : AppColors.onTime,
        ),
      );
      return;
    }

    final icon = _symbolIcon(el.subtype);
    if (icon == null) return;
    // Framed pictogram so symbols read as boxed amenities, not loose glyphs.
    canvas.drawRRect(
      rr,
      Paint()..color = onSurfaceVariant.withValues(alpha: 0.10),
    );
    canvas.drawRRect(
      rr,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0
        ..color = onSurfaceVariant.withValues(alpha: 0.4),
    );
    _centerText(
      canvas,
      box,
      String.fromCharCode(icon.codePoint),
      TextStyle(
        fontSize: unit * 1.9,
        height: 1.0,
        fontFamily: icon.fontFamily,
        package: icon.fontPackage,
        color: onSurfaceVariant,
      ),
    );
  }

  void _centerText(Canvas canvas, Rect box, String text, TextStyle style) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: style),
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(
      canvas,
      Offset(
        box.left + (box.width - tp.width) / 2,
        box.top + (box.height - tp.height) / 2,
      ),
    );
  }

  IconData? _symbolIcon(String? subtype) {
    switch (subtype) {
      case 'WC':
      case 'WC_BEHINDERT':
        return Icons.wc;
      case 'FAHRRAD':
        return Icons.directions_bike;
      case 'HANDY':
        return Icons.smartphone;
      case 'BEHINDERT':
      case 'ROLLSTUHL':
        return Icons.accessible;
      case 'GEPAECK':
        return Icons.luggage;
      case 'RESTAURANT':
      case 'BISTRO':
        return Icons.restaurant;
      case 'KINDER':
      case 'KLEINKIND':
        return Icons.child_friendly;
      case 'RUHE':
        return Icons.volume_off;
      case 'STROM':
      case 'STECKDOSE':
        return Icons.power;
      default:
        return null;
    }
  }

  String? _classMarker(String? subtype) {
    switch (subtype) {
      case 'KLASSE_1':
        return '1';
      case 'KLASSE_2':
        return '2';
      default:
        return null;
    }
  }

  @override
  bool shouldRepaint(covariant _CoachPainter old) =>
      old.coach != coach ||
      old.layout != layout ||
      !setEquals(old.mySeats, mySeats);
}
