import 'package:flutter/material.dart';
import '../../../models/coach_sequence.dart';
import '../../../theme/app_colors.dart';

class CoachSequenceView extends StatefulWidget {
  final CoachSequence sequence;

  /// When true the train doubles as a seat-plan picker: passenger cars become
  /// tappable, show their free-seat count and highlight the selected one.
  final bool selectable;

  /// Free-seat count per wagon number (from the seat map), shown on each car.
  final Map<int, int> freeByWagon;
  final int? selectedWagon;
  final void Function(Coach coach)? onCoachTap;

  /// Seat-plan content rendered inside this same card, below the train — so the
  /// free-seat view lives *in* the Wagenreihung instead of a separate section.
  final Widget? seatPlan;

  /// When true, render without the surrounding Card/margin so the Wagenreihung
  /// can be embedded inside the train's own card (not a separate section).
  final bool embedded;

  /// The station the user actually rides to on this leg. When the train splits
  /// (multiple groups with different destinations — a Flügelzug), this picks the
  /// portion the user must board and surfaces its platform section up front:
  /// "Für {target}: Abschnitt I einsteigen". Null on a standalone train lookup —
  /// then all portions are listed without a "for you" highlight.
  final String? targetDestination;

  /// Whether to render the wing-train split banner inside this card. False in a
  /// connection leg, where the banner is hoisted up under the boarding stop (you
  /// decide which portion to board there, not down in the Wagenreihung).
  final bool showSplitBanner;

  const CoachSequenceView({
    super.key,
    required this.sequence,
    this.selectable = false,
    this.freeByWagon = const {},
    this.selectedWagon,
    this.onCoachTap,
    this.seatPlan,
    this.embedded = false,
    this.targetDestination,
    this.showSplitBanner = true,
  });

  @override
  State<CoachSequenceView> createState() => _CoachSequenceViewState();
}

class _CoachSequenceViewState extends State<CoachSequenceView> {
  // Collapsed by default — the Wagenreihung is a sub-section you open when you
  // need it (which coach, free seats), not always-on clutter.
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final sequence = widget.sequence;
    final selectable = widget.selectable;
    final freeByWagon = widget.freeByWagon;
    final selectedWagon = widget.selectedWagon;
    final onCoachTap = widget.onCoachTap;
    final seatPlan = widget.seatPlan;
    final embedded = widget.embedded;

    final theme = Theme.of(context);
    final coaches = sequence.allCoaches;
    if (coaches.isEmpty) return const SizedBox.shrink();

    final platformLength = sequence.platform.length;

    final body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
            InkWell(
              onTap: () => setState(() => _expanded = !_expanded),
              child: Row(
                children: [
                  Text('Wagenreihung',
                      style: theme.textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.bold)),
                  const Spacer(),
                  // Gleis NOT repeated here — already on the boarding stop above
                  // (shown red there when it changed).
                  Icon(_expanded ? Icons.expand_less : Icons.expand_more,
                      size: 20, color: theme.colorScheme.onSurfaceVariant),
                ],
              ),
            ),

            // Wing-train guidance (standalone train view only — in a connection
            // leg it's hoisted up under the boarding stop). Shown even collapsed.
            if (widget.showSplitBanner && sequence.groups.length > 1)
              splitTrainBanner(context, sequence,
                  targetDestination: widget.targetDestination),

            if (_expanded) ...[
            const SizedBox(height: 8),

            // Sector labels
            if (sequence.platform.sectors.isNotEmpty && platformLength > 0)
              SizedBox(
                height: 16,
                child: Row(
                  children: [
                    for (final sector in sequence.platform.sectors)
                      Expanded(
                        flex: ((sector.end - sector.start) / platformLength * 1000)
                            .round(),
                        child: Container(
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            border: Border(
                              bottom: BorderSide(
                                  color: theme.colorScheme.outlineVariant),
                            ),
                          ),
                          child: Text(
                            sector.name,
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),

            const SizedBox(height: 8),

            // Coach visualization as a connected train (horizontal scroll)
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // Streamlined ICE nose at the very front of the train.
                  const _NoseCap(front: true),
                  for (var i = 0; i < coaches.length; i++) ...[
                    _Car(
                      coach: coaches[i],
                      selectable: selectable,
                      freeCount: freeByWagon[coaches[i].wagonNumber],
                      isSelected: selectedWagon != null &&
                          coaches[i].wagonNumber == selectedWagon,
                      onTap: onCoachTap == null
                          ? null
                          : () => onCoachTap(coaches[i]),
                    ),
                    if (i < coaches.length - 1) const _Coupler(),
                  ],
                  // …and at the rear.
                  const _NoseCap(front: false),
                ],
              ),
            ),

            const SizedBox(height: 8),

            // Legend
            Wrap(
              spacing: 10,
              runSpacing: 4,
              children: [
                _legendItem(AppColors.firstClass, '1. Klasse'),
                _legendItem(AppColors.secondClass, '2. Klasse'),
                _legendItem(AppColors.restaurant, 'Restaurant'),
                _legendItem(AppColors.locomotive, 'Triebkopf'),
              ],
            ),

            // Groups info (multiple train portions)
            if (sequence.groups.length > 1) ...[
              const SizedBox(height: 8),
              const Divider(),
              const SizedBox(height: 4),
              for (final group in sequence.groups)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(
                    children: [
                      Icon(Icons.train, size: 14,
                          color: theme.colorScheme.onSurfaceVariant),
                      const SizedBox(width: 4),
                      Text(
                        '${group.transport.category} ${group.transport.number}'
                        ' → ${group.transport.destination ?? ""}',
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
            ],
            ], // end if (_expanded)
          ],
        ),
      ),
      if (_expanded && seatPlan != null) ...[
        const Divider(height: 1),
        seatPlan,
      ],
        ],
      );

    if (embedded) return body;
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      clipBehavior: Clip.antiAlias,
      child: body,
    );
  }

  Widget _legendItem(Color color, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 4),
        Text(label, style: const TextStyle(fontSize: 10)),
      ],
    );
  }
}

/// Free-seat indicator on a coach: a seat icon with the free count, or a
/// struck-through seat (like the DB app) when the coach is fully reserved.
class _FreeSeatBadge extends StatelessWidget {
  final int free;
  const _FreeSeatBadge({required this.free});

  @override
  Widget build(BuildContext context) {
    final full = free == 0;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        SizedBox(
          width: 11,
          height: 11,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Icon(Icons.event_seat,
                  size: 11,
                  color: full ? AppColors.closedCoach : AppColors.onTime),
              if (full)
                Transform.rotate(
                  angle: -0.7,
                  child: Container(width: 13, height: 1.6, color: AppColors.delay),
                ),
            ],
          ),
        ),
        const SizedBox(width: 2),
        Text(
          full ? 'voll' : '$free',
          style: TextStyle(
            fontSize: 9,
            fontWeight: FontWeight.w700,
            color: full ? AppColors.closedCoach : AppColors.onTime,
          ),
        ),
      ],
    );
  }
}

/// Coupler bar drawn between two cars to make the train look connected.
class _Coupler extends StatelessWidget {
  const _Coupler();
  @override
  Widget build(BuildContext context) => Container(
        width: 4,
        height: 4,
        color: AppColors.locomotive.withAlpha(140),
      );
}

/// A single car drawn train-style. End power cars (Triebköpfe) get a tapered
/// ICE-like nose; passenger cars get a class stripe + window band.
class _Car extends StatelessWidget {
  final Coach coach;
  final bool selectable;
  final int? freeCount;
  final bool isSelected;
  final VoidCallback? onTap;

  const _Car({
    required this.coach,
    this.selectable = false,
    this.freeCount,
    this.isSelected = false,
    this.onTap,
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
    final theme = Theme.of(context);
    final open = coach.isOpen;
    final accent = open ? _classColor : AppColors.closedCoach;
    final isLoco = coach.isLocomotive;
    final canSelect = selectable && !isLoco && coach.wagonNumber > 0;
    final borderColor = isSelected ? AppColors.onTime : accent;

    final car = Container(
      width: isLoco ? 32 : 44,
      height: 38,
      decoration: BoxDecoration(
        color: isSelected
            ? AppColors.onTime.withValues(alpha: 0.16)
            : isLoco
                ? AppColors.locomotive
                : theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: borderColor, width: isSelected ? 2.5 : 1.5),
      ),
      clipBehavior: Clip.antiAlias,
      child: isLoco
          ? const Center(
              child: Icon(Icons.train, color: Colors.white, size: 16))
          : Column(
              children: [
                // class stripe
                Container(height: 4, color: accent),
                // window band
                Expanded(
                  child: Center(
                    child: Text(
                      coach.wagonNumber > 0 ? '${coach.wagonNumber}' : '–',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: open ? null : Colors.grey,
                      ),
                    ),
                  ),
                ),
                // free-seat badge when selecting; amenity icons otherwise.
                SizedBox(
                  height: 13,
                  child: freeCount != null
                      ? _FreeSeatBadge(free: freeCount!)
                      : Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            if (coach.hasBikeSpace)
                              const Icon(Icons.pedal_bike, size: 9),
                            if (coach.hasQuietZone)
                              const Icon(Icons.volume_off, size: 9),
                            if (coach.hasFamilyZone)
                              const Icon(Icons.family_restroom, size: 9),
                            if (coach.hasWheelchairSpace)
                              const Icon(Icons.accessible, size: 9),
                            if (coach.isRestaurant)
                              const Icon(Icons.restaurant, size: 9),
                          ],
                        ),
                ),
              ],
            ),
    );

    return Tooltip(
      message: _tooltipText(),
      child: canSelect
          ? InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(8),
              child: car,
            )
          : car,
    );
  }

  String _tooltipText() {
    final parts = <String>[];
    if (coach.wagonNumber > 0) parts.add('Wagen ${coach.wagonNumber}');
    if (coach.isFirstClass) parts.add('1. Klasse');
    if (coach.isSecondClass) parts.add('2. Klasse');
    if (coach.isMixed) parts.add('1./2. Klasse');
    if (coach.isRestaurant) parts.add('Bordrestaurant');
    if (coach.isLocomotive) parts.add('Triebkopf');
    if (coach.hasBikeSpace) parts.add('Fahrrad');
    if (coach.hasQuietZone) parts.add('Ruhebereich');
    if (coach.hasFamilyZone) parts.add('Familienbereich');
    if (coach.hasWheelchairSpace) parts.add('Rollstuhl');
    if (!coach.isOpen) parts.add('Gesperrt');
    if (coach.platformPosition != null) {
      parts.add('Sektor ${coach.platformPosition!.sector}');
    }
    return parts.join(' · ');
  }
}

/// The streamlined ICE nose cap drawn at each end of the train. Tapers to a
/// soft point at the outer end with a dark windscreen near the tip.
/// [front] = nose points left (head of the train); false mirrors it for the
/// rear. Sits flush against the first/last car so the train reads as an ICE.
class _NoseCap extends StatelessWidget {
  final bool front;
  const _NoseCap({required this.front});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: const Size(28, 38),
      painter: _NosePainter(front: front),
    );
  }
}

class _NosePainter extends CustomPainter {
  final bool front;
  const _NosePainter({required this.front});

  @override
  void paint(Canvas canvas, Size size) {
    // Drawn as a SIDE view of an ICE: the roof sweeps down at the front into a
    // low, rounded nose; the underframe is flat. Built nose-left, then mirrored
    // for a rear car.
    if (!front) {
      canvas.translate(size.width, 0);
      canvas.scale(-1, 1);
    }
    final w = size.width, h = size.height;
    const c = 5.0; // rounding of the inner (coupling) end

    final body = Path()
      ..moveTo(w - c, 0) // back roof corner
      ..lineTo(w * 0.46, 0) // roof runs forward, then…
      // …windscreen sweeps down to the low nose tip at the front
      ..cubicTo(w * 0.20, 0, 0, h * 0.34, w * 0.04, h * 0.56)
      // belly curves back under the nose to the flat underframe
      ..cubicTo(0, h * 0.80, w * 0.10, h, w * 0.26, h)
      ..lineTo(w - c, h) // underframe to the back
      ..arcToPoint(Offset(w, h - c), radius: const Radius.circular(c))
      ..lineTo(w, c)
      ..arcToPoint(Offset(w - c, 0), radius: const Radius.circular(c))
      ..close();

    canvas.drawPath(body, Paint()..color = AppColors.locomotive);
    canvas.drawPath(
      body,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = Colors.black.withValues(alpha: 0.3),
    );

    // Slanted windscreen following the nose sweep.
    final windscreen = Path()
      ..moveTo(w * 0.30, h * 0.16)
      ..lineTo(w * 0.46, h * 0.16)
      ..lineTo(w * 0.16, h * 0.50)
      ..lineTo(w * 0.08, h * 0.46)
      ..close();
    canvas.drawPath(
        windscreen, Paint()..color = Colors.black.withValues(alpha: 0.40));

    // A thin side window band along the body.
    final band = RRect.fromRectAndRadius(
      Rect.fromLTWH(w * 0.50, h * 0.30, w * 0.46, h * 0.20),
      const Radius.circular(2),
    );
    canvas.drawRRect(band, Paint()..color = Colors.black.withValues(alpha: 0.28));
  }

  @override
  bool shouldRepaint(covariant _NosePainter old) => old.front != front;
}

// ---------------------------------------------------------------------------
// Wing-train (Flügelzug) split banner — shared by the Wagenreihung card (the
// standalone train view) and the connection leg, where it's hoisted up under
// the boarding stop. RED on purpose: "board the wrong portion and you don't
// arrive" is a do-this-or-else fact, not a nice-to-know.
// ---------------------------------------------------------------------------

/// Banner that tells the rider which portion of a splitting train to board.
/// Caller must guarantee `sequence.groups.length > 1`.
Widget splitTrainBanner(BuildContext context, CoachSequence sequence,
    {String? targetDestination}) {
  final theme = Theme.of(context);
  final groups = sequence.groups;
  final target = targetDestination;
  CoachGroup? mine;
  if (target != null && target.isNotEmpty) {
    for (final g in groups) {
      if (_destMatches(g.transport.destination, target)) {
        mine = g;
        break;
      }
    }
  }
  // Red, theme-aware (works in light & dark): tinted fill, solid border, red text.
  final red = theme.colorScheme.error;
  return Container(
    margin: const EdgeInsets.only(top: 8, bottom: 4),
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    decoration: BoxDecoration(
      color: red.withAlpha(28),
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: red.withAlpha(140), width: 1.5),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.call_split, size: 19, color: red),
            const SizedBox(width: 6),
            Text('Zug teilt sich',
                style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.bold, color: red)),
          ],
        ),
        if (mine != null) ...[
          const SizedBox(height: 6),
          _bannerLine(
            context,
            red,
            primary: true,
            icon: Icons.check_circle,
            text: _sectorsOf(mine).isNotEmpty
                ? 'Für $target: in Abschnitt ${_sectorsOf(mine)} einsteigen'
                : 'Für $target: Zugteil Richtung '
                    '${mine.transport.destination ?? target}',
          ),
        ],
        const SizedBox(height: 4),
        for (final g in groups)
          if (!identical(g, mine))
            _bannerLine(
              context,
              red,
              primary: false,
              icon: Icons.train_outlined,
              text: _sectorsOf(g).isNotEmpty
                  ? 'Nicht: Richtung ${g.transport.destination ?? "?"} · '
                      'Abschnitt ${_sectorsOf(g)}'
                  : 'Nicht: Richtung ${g.transport.destination ?? "?"}',
            ),
        if (mine == null) ...[
          const SizedBox(height: 4),
          Text('Vor Einstieg Fahrtzielanzeige am Zug beachten.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: red.withAlpha(220))),
        ],
      ],
    ),
  );
}

Widget _bannerLine(BuildContext context, Color red,
    {required bool primary, required IconData icon, required String text}) {
  final theme = Theme.of(context);
  final muted = theme.colorScheme.onSurfaceVariant;
  return Padding(
    padding: const EdgeInsets.only(top: 2),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: primary ? 17 : 14, color: primary ? red : muted),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            style: theme.textTheme.bodySmall?.copyWith(
              color: primary ? red : muted,
              fontWeight: primary ? FontWeight.w800 : FontWeight.w400,
            ),
          ),
        ),
      ],
    ),
  );
}

/// Distinct platform sections the coaches of [g] occupy, e.g. "I" or "G–I".
String _sectorsOf(CoachGroup g) {
  final s = <String>{};
  for (final c in g.coaches) {
    final sec = c.platformPosition?.sector;
    if (sec != null && sec.trim().isNotEmpty) s.add(sec.trim());
  }
  final list = s.toList()..sort();
  return list.join('–');
}

bool _destMatches(String? a, String b) {
  final na = _norm(a ?? ''), nb = _norm(b);
  if (na.isEmpty || nb.isEmpty) return false;
  return na == nb || na.contains(nb) || nb.contains(na);
}

String _norm(String s) => s
    .toLowerCase()
    .replaceAll('hauptbahnhof', 'hbf')
    .replaceAll(RegExp(r'[^a-zäöüß0-9]'), '');
