import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../models/coach_sequence.dart';
import '../../../theme/app_colors.dart';

/// The Wagenreihung drawn TO SCALE on the actual platform: the section letters
/// (A, B, C …), the cars and the Gleis all share one horizontal coordinate
/// system (the platform's own start…end), so a car sits visually under the
/// section it actually stops in — and when you scroll left/right the sections
/// scroll WITH the cars and stay aligned.
///
/// Needs real geometry (a platform length and a position per car). Use
/// [hasGeometry] to decide; when it's false the caller falls back to the
/// simple equal-width row (no platform info to place things against).
class PlatformTrackView extends StatelessWidget {
  final CoachSequence sequence;
  final bool selectable;
  final Map<int, int> freeByWagon;
  final int? selectedWagon;
  final void Function(Coach coach)? onCoachTap;

  /// Height of a car box. Compact inline (~40) vs roomy fullscreen (~64).
  final double carHeight;

  /// Target on-screen width of an average car — drives the platform scale.
  final double targetCarWidth;

  const PlatformTrackView({
    super.key,
    required this.sequence,
    this.selectable = false,
    this.freeByWagon = const {},
    this.selectedWagon,
    this.onCoachTap,
    this.carHeight = 40,
    this.targetCarWidth = 46,
  });

  /// True when we can lay the train out to scale: a positive platform length
  /// and a real position on every car.
  static bool hasGeometry(CoachSequence s) {
    if (s.platform.length <= 0) return false;
    final coaches = s.allCoaches;
    if (coaches.isEmpty) return false;
    return coaches.every(
        (c) => c.platformPosition != null && c.platformPosition!.length > 0);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final coaches = sequence.allCoaches;
    final plat = sequence.platform;

    final trainStart =
        coaches.map((c) => c.platformPosition!.start).reduce(math.min);
    final trainEnd =
        coaches.map((c) => c.platformPosition!.end).reduce(math.max);
    final trainLen = (trainEnd - trainStart).abs();
    if (trainLen <= 0) return const SizedBox.shrink();

    final avgLen = trainLen / coaches.length;
    final scale = targetCarWidth / avgLen;

    // Which slice of the platform to draw. Normally the whole platform (so you
    // see the empty sections beyond the train too); but if the platform dwarfs
    // the train, zoom to the train + one car of padding so it isn't lost in a
    // sea of empty asphalt.
    double ds = plat.start, de = plat.end;
    if (de <= ds) {
      ds = trainStart;
      de = trainEnd;
    }
    final pad = avgLen * 0.9;
    if ((de - ds) > trainLen * 2.4) {
      ds = math.max(plat.start, trainStart - pad);
      de = math.min(plat.end, trainEnd + pad);
    }
    final span = de - ds;
    if (span <= 0) return const SizedBox.shrink();

    // Travel direction from the coaches' own orientation: a FORWARDS-majority
    // train heads toward the start-of-numbering end (left here). Hidden when no
    // coach reports an orientation — better no arrow than a guessed one.
    final fwd = coaches.where((c) => c.orientation == 'FORWARDS').length;
    final bwd = coaches.where((c) => c.orientation == 'BACKWARDS').length;
    final hasDir = fwd > 0 || bwd > 0;
    final dirToStart = fwd >= bwd; // arrow points left toward trainStart

    final dirH = hasDir ? 18.0 : 0.0;
    const labelH = 22.0;
    const labelGap = 4.0;
    const trackH = 16.0;
    final carTop = dirH + labelH + labelGap;
    final stackH = carTop + carHeight + trackH;

    // The end cars themselves are shaped into the snout (no separate nose) and
    // overhang their platform slot on the outer side. A high-speed train (ICE)
    // gets a long aerodynamic nose; a regional train a short, blunt cab.
    final highSpeed = _isHighSpeed(sequence);
    final overhang = carHeight * (highSpeed ? 0.95 : 0.7);
    final leadPad = overhang + 2;

    double px(double u) => (u - ds) * scale + leadPad;
    final totalW = span * scale + leadPad * 2;

    final bandEven = theme.colorScheme.surfaceContainerHighest.withValues(
        alpha: 0.55);
    final bandOdd = theme.colorScheme.surfaceContainerHighest.withValues(
        alpha: 0.20);
    final boundary = theme.colorScheme.outlineVariant;

    final children = <Widget>[];

    // 1) Section bands (alternating) + their right-edge boundary lines, full
    //    height so the eye buckets each car into its section.
    for (var i = 0; i < plat.sectors.length; i++) {
      final s = plat.sectors[i];
      final left = px(s.start);
      final w = (s.end - s.start) * scale;
      if (w <= 0 || left + w <= 0 || left >= totalW) continue;
      children.add(Positioned(
        left: left,
        width: w,
        top: 0,
        bottom: 0,
        child: Container(
          decoration: BoxDecoration(
            color: i.isEven ? bandEven : bandOdd,
            border: Border(right: BorderSide(color: boundary, width: 1)),
          ),
        ),
      ));
      // Big, clear section letter at the top of the band.
      children.add(Positioned(
        left: left,
        width: w,
        top: dirH,
        height: labelH,
        child: Center(
          child: Text(
            s.name,
            style: TextStyle(
              fontSize: carHeight >= 56 ? 18 : 13,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.5,
              color: theme.colorScheme.onSurface,
            ),
          ),
        ),
      ));
    }

    // 2) The Gleis (track) running the full width under the cars.
    children.add(Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      height: trackH,
      child: CustomPaint(painter: _TrackPainter(color: AppColors.locomotive)),
    ));

    // 2b) Fahrtrichtung arrow in the top strip, at the leading end.
    if (hasDir) {
      children.add(Positioned(
        left: 0,
        right: 0,
        top: 0,
        height: dirH,
        child: Align(
          alignment: dirToStart ? Alignment.centerLeft : Alignment.centerRight,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (dirToStart)
                  Icon(Icons.keyboard_double_arrow_left,
                      size: 15, color: theme.colorScheme.primary),
                Text(' Fahrtrichtung ',
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: theme.colorScheme.primary)),
                if (!dirToStart)
                  Icon(Icons.keyboard_double_arrow_right,
                      size: 15, color: theme.colorScheme.primary),
              ],
            ),
          ),
        ),
      ));
    }

    // 3) The cars at their true platform positions. The FIRST and LAST car are
    //    shaped into the ICE snout themselves (no separate nose element): their
    //    outer end is the rounded wedge, overhanging the slot by [overhang].
    for (var i = 0; i < coaches.length; i++) {
      final c = coaches[i];
      final pos = c.platformPosition!;
      final slotLeft = px(pos.start);
      final slotW = math.max((pos.end - pos.start) * scale, 18.0);
      final isFirst = i == 0;
      final isLast = i == coaches.length - 1;
      final freeCount = freeByWagon[c.wagonNumber];
      final isSel = selectedWagon != null && c.wagonNumber == selectedWagon;
      final onTap = onCoachTap == null ? null : () => onCoachTap!(c);

      if (isFirst || isLast) {
        // Front nose on the first car (its outer end is the LEFT), rear nose on
        // the last car (outer end RIGHT). A lone single car gets a front nose.
        final front = isFirst;
        final left = front ? slotLeft - overhang : slotLeft;
        final w = slotW + overhang;
        children.add(Positioned(
          left: left,
          width: w,
          top: carTop,
          height: carHeight,
          child: _TrackEndCar(
            coach: c,
            front: front,
            highSpeed: highSpeed,
            width: w,
            height: carHeight,
            selectable: selectable,
            freeCount: freeCount,
            isSelected: isSel,
            onTap: onTap,
          ),
        ));
      } else {
        children.add(Positioned(
          left: slotLeft,
          width: slotW,
          top: carTop,
          height: carHeight,
          child: _TrackCar(
            coach: c,
            width: slotW,
            height: carHeight,
            selectable: selectable,
            freeCount: freeCount,
            isSelected: isSel,
            onTap: onTap,
          ),
        ));
      }
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SizedBox(
        width: math.max(totalW, 1),
        height: stackH,
        child: Stack(clipBehavior: Clip.none, children: children),
      ),
    );
  }
}

/// Two rails + sleepers, drawn the full width so the cars read as standing on a
/// real track.
class _TrackPainter extends CustomPainter {
  final Color color;
  const _TrackPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final rail = Paint()
      ..color = color.withValues(alpha: 0.85)
      ..strokeWidth = 1.6;
    final tie = Paint()
      ..color = color.withValues(alpha: 0.35)
      ..strokeWidth = 1.4;
    final y1 = size.height * 0.38;
    final y2 = size.height * 0.74;
    // Sleepers first (under the rails).
    for (double x = 4; x < size.width; x += 12) {
      canvas.drawLine(Offset(x, y1 - 2), Offset(x, y2 + 2), tie);
    }
    canvas.drawLine(Offset(0, y1), Offset(size.width, y1), rail);
    canvas.drawLine(Offset(0, y2), Offset(size.width, y2), rail);
  }

  @override
  bool shouldRepaint(covariant _TrackPainter old) => old.color != color;
}

/// Class colour that fills a whole car body.
Color _coachAccent(Coach c) {
  if (!c.isOpen) return AppColors.closedCoach;
  if (c.isLocomotive) return AppColors.locomotive;
  if (c.isRestaurant) return AppColors.restaurant;
  if (c.isFirstClass || c.isMixed) return AppColors.firstClass;
  return AppColors.secondClass;
}

/// True for a high-speed train (ICE/ICE-E) — gets the long aerodynamic nose.
bool _isHighSpeed(CoachSequence s) {
  for (final g in s.groups) {
    final c = g.transport.category.toUpperCase();
    if (c == 'ICE' || c == 'ECE') return true;
    if (g.transport.type.toUpperCase().contains('HIGH_SPEED')) return true;
  }
  return false;
}

/// Horizontal length (px) of the snout part of an end car; the rest is the
/// full-height body that carries the number.
double _snoutPx(double w, double h, bool highSpeed) =>
    highSpeed ? 0.62 * w : math.min(h, 0.6 * w);

/// Outline of an end car, built with the nose at the LEFT (front); the rear car
/// mirrors it. ICE: a long nose converging to a SHARP but rounded point at mid
/// height. Regional: the front is a single quarter-circle from the roof down to
/// the underframe.
Path _endCarPath(Size size, {required bool front, required bool highSpeed}) {
  final w = size.width, h = size.height;
  final nf = _snoutPx(w, h, highSpeed); // snout length in px
  final Path p;
  if (highSpeed) {
    p = Path()
      ..moveTo(0.16 * nf, h) // belly base behind the tip
      ..lineTo(w, h) // flat underframe to the inner end
      ..lineTo(w, 0) // full-height inner (coupling) edge
      ..lineTo(0.82 * nf, 0) // short flat roof, then the long sweep…
      ..cubicTo(0.40 * nf, 0, 0.06 * nf, 0.24 * h, 0, 0.46 * h)
      // …to a sharp but rounded tip at the very front, mid height
      ..quadraticBezierTo(0, 0.50 * h, 0, 0.54 * h)
      ..cubicTo(0.06 * nf, 0.76 * h, 0.16 * nf, 0.94 * h, 0.16 * nf, h)
      ..close();
  } else {
    // A quarter-circle front: flat roof to (r,0), then a 90° arc (cubic with
    // kappa) bulging out to the bottom-front (0,h).
    final r = nf;
    const k = 0.5523;
    p = Path()
      ..moveTo(0, h) // bottom-front
      ..lineTo(w, h) // underframe to the inner end
      ..lineTo(w, 0) // full-height inner edge
      ..lineTo(r, 0) // roof to the top of the arc
      ..cubicTo(r * (1 - k), 0, 0, h * (1 - k), 0, h) // quarter circle
      ..close();
  }
  if (front) return p;
  // Mirror horizontally (x' = w - x) so the rear car's nose points the other
  // way — a column-major flip matrix, no deprecated Matrix4 helpers.
  final flip = Float64List.fromList([
    -1, 0, 0, 0, //
    0, 1, 0, 0, //
    0, 0, 1, 0, //
    w, 0, 0, 1, //
  ]);
  return p.transform(flip);
}

/// The first/last car of an ICE: the car itself IS the snout (no separate nose
/// element). Its outer end is the rounded wedge; the full-height inner body
/// carries the wagon number + free-seat badge, in the car's class colour.
class _TrackEndCar extends StatelessWidget {
  final Coach coach;
  final bool front;
  final bool highSpeed;
  final double width;
  final double height;
  final bool selectable;
  final int? freeCount;
  final bool isSelected;
  final VoidCallback? onTap;

  const _TrackEndCar({
    required this.coach,
    required this.front,
    required this.highSpeed,
    required this.width,
    required this.height,
    required this.selectable,
    required this.freeCount,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final accent = _coachAccent(coach);
    final fg = AppColors.onClass(accent);
    final canSelect = selectable && !coach.isLocomotive && coach.wagonNumber > 0;
    final compact = height < 50;
    final bodyW = (width - _snoutPx(width, height, highSpeed)) * 0.96;

    final content = Align(
      alignment: front ? Alignment.centerRight : Alignment.centerLeft,
      child: Padding(
        padding: EdgeInsets.only(
            right: front ? width * 0.06 : 0, left: front ? 0 : width * 0.06),
        child: SizedBox(
          width: bodyW,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (!coach.isLocomotive)
                Text(
                  coach.wagonNumber > 0 ? '${coach.wagonNumber}' : '–',
                  style: TextStyle(
                    fontSize: compact ? 13 : 16,
                    fontWeight: FontWeight.w800,
                    color: fg,
                  ),
                )
              else
                Icon(Icons.train, color: fg, size: 16),
              if (freeCount != null) ...[
                const SizedBox(height: 3),
                _FreeSeatBadge(free: freeCount!, big: !compact),
              ],
            ],
          ),
        ),
      ),
    );

    final car = Stack(
      children: [
        Positioned.fill(
          child: CustomPaint(
            painter: _EndCarPainter(
                front: front,
                highSpeed: highSpeed,
                accent: accent,
                selected: isSelected),
          ),
        ),
        Positioned.fill(child: content),
      ],
    );

    return Tooltip(
      message: _tooltip(coach, freeCount),
      child: canSelect
          ? InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(6),
              child: car)
          : car,
    );
  }
}

class _EndCarPainter extends CustomPainter {
  final bool front;
  final bool highSpeed;
  final Color accent;
  final bool selected;
  const _EndCarPainter(
      {required this.front,
      required this.highSpeed,
      required this.accent,
      required this.selected});

  @override
  void paint(Canvas canvas, Size size) {
    final body = _endCarPath(size, front: front, highSpeed: highSpeed);
    canvas.drawPath(body, Paint()..color = accent);
    canvas.drawPath(
      body,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = selected ? 3 : 1.2
        ..color = selected ? AppColors.onTime : Colors.black.withValues(alpha: 0.22),
    );
  }

  @override
  bool shouldRepaint(covariant _EndCarPainter old) =>
      old.front != front ||
      old.highSpeed != highSpeed ||
      old.accent != accent ||
      old.selected != selected;
}

/// Shared tooltip text for a car on the track.
String _tooltip(Coach coach, int? freeCount) {
  final parts = <String>[];
  if (coach.wagonNumber > 0) parts.add('Wagen ${coach.wagonNumber}');
  if (coach.isFirstClass) parts.add('1. Klasse');
  if (coach.isSecondClass) parts.add('2. Klasse');
  if (coach.isMixed) parts.add('1./2. Klasse');
  if (coach.isRestaurant) parts.add('Bordrestaurant');
  if (coach.isLocomotive) parts.add('Triebkopf');
  if (coach.platformPosition != null &&
      coach.platformPosition!.sector.trim().isNotEmpty) {
    parts.add('Abschnitt ${coach.platformPosition!.sector}');
  }
  if (freeCount != null) parts.add('$freeCount frei');
  if (!coach.isOpen) parts.add('Gesperrt');
  return parts.join(' · ');
}

/// One car sized to fill its platform slot: class stripe, wagon number and a
/// free-seat badge (or amenity icons). Tappable when selecting a coach.
class _TrackCar extends StatelessWidget {
  final Coach coach;
  final double width;
  final double height;
  final bool selectable;
  final int? freeCount;
  final bool isSelected;
  final VoidCallback? onTap;

  const _TrackCar({
    required this.coach,
    required this.width,
    required this.height,
    required this.selectable,
    required this.freeCount,
    required this.isSelected,
    required this.onTap,
  });

  Color get _classColor => coach.isLocomotive
      ? AppColors.locomotive
      : coach.isRestaurant
          ? AppColors.restaurant
          : coach.isFirstClass
              ? AppColors.firstClass
              : coach.isMixed
                  ? AppColors.firstClass
                  : AppColors.secondClass;

  @override
  Widget build(BuildContext context) {
    final open = coach.isOpen;
    final isLoco = coach.isLocomotive;
    // The whole car body is filled with its class colour now (blue car = fully
    // blue, gold = fully gold), with the number/icons in a contrasting tone.
    final accent = open ? _classColor : AppColors.closedCoach;
    final fg = AppColors.onClass(accent);
    final canSelect = selectable && !isLoco && coach.wagonNumber > 0;
    final compact = height < 50;

    final car = Container(
      margin: const EdgeInsets.symmetric(horizontal: 0.6),
      decoration: BoxDecoration(
        color: accent,
        borderRadius: BorderRadius.circular(5),
        border: Border.all(
          color: isSelected ? AppColors.onTime : Colors.black.withValues(alpha: 0.18),
          width: isSelected ? 3 : 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: isLoco
          ? Center(child: Icon(Icons.train, color: fg, size: 16))
          : Column(
              children: [
                const SizedBox(height: 3),
                Expanded(
                  child: Center(
                    child: Text(
                      coach.wagonNumber > 0 ? '${coach.wagonNumber}' : '–',
                      style: TextStyle(
                        fontSize: compact ? 13 : 16,
                        fontWeight: FontWeight.w800,
                        color: fg,
                      ),
                    ),
                  ),
                ),
                if (freeCount != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 3),
                    child: _FreeSeatBadge(free: freeCount!, big: !compact),
                  )
                else if (!compact)
                  SizedBox(
                    height: 14,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        if (coach.hasBikeSpace)
                          Icon(Icons.pedal_bike, size: 11, color: fg),
                        if (coach.hasQuietZone)
                          Icon(Icons.volume_off, size: 11, color: fg),
                        if (coach.hasFamilyZone)
                          Icon(Icons.family_restroom, size: 11, color: fg),
                        if (coach.hasWheelchairSpace)
                          Icon(Icons.accessible, size: 11, color: fg),
                        if (coach.isRestaurant)
                          Icon(Icons.restaurant, size: 11, color: fg),
                      ],
                    ),
                  ),
              ],
            ),
    );

    return Tooltip(
      message: _tooltip(),
      child: canSelect
          ? InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(5),
              child: car,
            )
          : car,
    );
  }

  String _tooltip() {
    final parts = <String>[];
    if (coach.wagonNumber > 0) parts.add('Wagen ${coach.wagonNumber}');
    if (coach.isFirstClass) parts.add('1. Klasse');
    if (coach.isSecondClass) parts.add('2. Klasse');
    if (coach.isMixed) parts.add('1./2. Klasse');
    if (coach.isRestaurant) parts.add('Bordrestaurant');
    if (coach.isLocomotive) parts.add('Triebkopf');
    if (coach.platformPosition != null &&
        coach.platformPosition!.sector.trim().isNotEmpty) {
      parts.add('Abschnitt ${coach.platformPosition!.sector}');
    }
    if (freeCount != null) parts.add('$freeCount frei');
    if (!coach.isOpen) parts.add('Gesperrt');
    return parts.join(' · ');
  }
}

/// Free-seat indicator: a seat icon with the count, or a struck-through seat
/// when the coach is full.
class _FreeSeatBadge extends StatelessWidget {
  final int free;
  final bool big;
  const _FreeSeatBadge({required this.free, this.big = false});

  @override
  Widget build(BuildContext context) {
    final full = free == 0;
    final sz = big ? 13.0 : 11.0;
    // A white pill so the badge reads on top of a fully-coloured car body.
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(7),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: sz,
            height: sz,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Icon(Icons.event_seat,
                    size: sz,
                    color: full ? AppColors.closedCoach : AppColors.onTime),
                if (full)
                  Transform.rotate(
                    angle: -0.7,
                    child: Container(
                        width: sz + 2, height: 1.6, color: AppColors.delay),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 2),
          Text(
            full ? 'voll' : '$free',
            style: TextStyle(
              fontSize: big ? 11 : 9,
              fontWeight: FontWeight.w700,
              color: full ? const Color(0xFF8A9097) : AppColors.onTime,
            ),
          ),
        ],
      ),
    );
  }
}
