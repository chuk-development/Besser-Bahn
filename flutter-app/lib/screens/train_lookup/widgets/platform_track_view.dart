import 'dart:math' as math;

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

    // A rounded loco-style snout sits at each end of the train, so leave room
    // for it on both sides and shift the whole layout right by one nose width.
    final noseW = carHeight * 1.05;
    final leadPad = noseW + 2;

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

    // 3) Rounded loco-style snouts at both ends — the "Schnauze" up front.
    children.add(Positioned(
      left: px(trainStart) - noseW,
      width: noseW,
      top: carTop,
      height: carHeight,
      child: const _TrackNose(front: true),
    ));
    children.add(Positioned(
      left: px(trainEnd),
      width: noseW,
      top: carTop,
      height: carHeight,
      child: const _TrackNose(front: false),
    ));

    // 4) The cars, each placed at its true platform position.
    for (final c in coaches) {
      final pos = c.platformPosition!;
      final left = px(pos.start);
      final w = math.max((pos.end - pos.start) * scale, 18.0);
      children.add(Positioned(
        left: left,
        width: w,
        top: carTop,
        height: carHeight,
        child: _TrackCar(
          coach: c,
          width: w,
          height: carHeight,
          selectable: selectable,
          freeCount: freeByWagon[c.wagonNumber],
          isSelected:
              selectedWagon != null && c.wagonNumber == selectedWagon,
          onTap: onCoachTap == null ? null : () => onCoachTap!(c),
        ),
      ));
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

/// The ICE snout drawn as a SIDE-VIEW silhouette: a low, rounded nose tip up
/// front, the roof sweeping up to full body height, a flat underframe and a
/// small notch at the coupling (car) end — a wedge, like the sketch.
/// [front] = nose points left (head of train); false mirrors it for the rear.
class _TrackNose extends StatelessWidget {
  final bool front;
  const _TrackNose({required this.front});

  @override
  Widget build(BuildContext context) => CustomPaint(painter: _NosePainter(front));
}

class _NosePainter extends CustomPainter {
  final bool front;
  const _NosePainter(this.front);

  @override
  void paint(Canvas canvas, Size size) {
    // Built nose-left; mirror for the rear car so its tip points right.
    if (!front) {
      canvas.translate(size.width, 0);
      canvas.scale(-1, 1);
    }
    final w = size.width, h = size.height;

    final body = Path()
      ..moveTo(0.12 * w, h) // bottom, just behind the nose tip
      ..lineTo(w, h) // flat underframe to the car end
      ..lineTo(w, 0.24 * h) // up the car-end edge (stop short for the notch)
      ..lineTo(0.86 * w, 0.24 * h) // notch in…
      ..lineTo(0.86 * w, 0.05 * h) // …and up to the roof
      ..lineTo(0.72 * w, 0) // roof corner
      // roof sweeps down to the low, rounded nose tip
      ..cubicTo(0.42 * w, 0, 0.15 * w, 0.16 * h, 0.06 * w, 0.42 * h)
      // belly curves back under the nose to the underframe
      ..cubicTo(0, 0.56 * h, 0, 0.82 * h, 0.12 * w, h)
      ..close();

    canvas.drawPath(body, Paint()..color = AppColors.locomotive);
    canvas.drawPath(
      body,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4
        ..color = Colors.black.withValues(alpha: 0.30),
    );

    // Slanted windscreen following the nose sweep.
    final windscreen = Path()
      ..moveTo(0.30 * w, 0.14 * h)
      ..lineTo(0.44 * w, 0.14 * h)
      ..lineTo(0.20 * w, 0.46 * h)
      ..lineTo(0.12 * w, 0.42 * h)
      ..close();
    canvas.drawPath(
        windscreen, Paint()..color = Colors.black.withValues(alpha: 0.42));

    // A thin side window band along the body.
    final band = RRect.fromRectAndRadius(
      Rect.fromLTWH(0.50 * w, 0.30 * h, 0.40 * w, 0.20 * h),
      const Radius.circular(2),
    );
    canvas.drawRRect(band, Paint()..color = Colors.black.withValues(alpha: 0.28));
  }

  @override
  bool shouldRepaint(covariant _NosePainter old) => old.front != front;
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
