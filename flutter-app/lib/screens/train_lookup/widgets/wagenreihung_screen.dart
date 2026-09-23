import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../models/coach_sequence.dart';
import '../../../models/seat_map.dart';
import '../../../models/trip.dart';
import '../../../providers/seat_map_provider.dart';
import '../../../theme/app_colors.dart';
import 'coach_sequence_view.dart' show splitTrainBanner;
import 'platform_track_view.dart';
import 'seat_map_view.dart';
import '../../../widgets/app_nav_bar.dart';

/// Dedicated, full-screen Wagenreihung + Sitzplatz view. The inline card is
/// cramped (especially the platform layout and the seat plan); here both get
/// the whole screen: a large to-scale platform with section letters and the
/// Gleis, and — for the tapped coach — a big, vertical seat plan.
class WagenreihungScreen extends ConsumerStatefulWidget {
  final Trip trip;

  /// The coach sequence to draw to scale. Null for trains that only offer a
  /// seat plan (no Wagenreihung) — then a coach-chip picker stands in for the
  /// platform layout.
  final CoachSequence? sequence;

  /// Coach pre-selected from the inline view, so opening fullscreen keeps your
  /// place. Null → first coach with free seats.
  final int? initialWagon;

  /// Destination on this leg — highlights the right portion of a wing train.
  final String? targetDestination;

  const WagenreihungScreen({
    super.key,
    required this.trip,
    this.sequence,
    this.initialWagon,
    this.targetDestination,
  });

  @override
  ConsumerState<WagenreihungScreen> createState() => _WagenreihungScreenState();
}

class _WagenreihungScreenState extends ConsumerState<WagenreihungScreen> {
  int? _selectedWagon;

  @override
  void initState() {
    super.initState();
    _selectedWagon = widget.initialWagon;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final trip = widget.trip;
    final sequence = widget.sequence;
    final reservable = SeatPlanBody.isAvailableFor(trip);
    final req = reservable ? SeatMapRequest.fromTrip(trip) : null;
    final seatAsync = req != null ? ref.watch(seatMapProvider(req)) : null;
    final SeatMap? seatMap = seatAsync?.maybeWhen(
      data: (m) => m,
      orElse: () => null,
    );

    final freeByWagon = <int, int>{};
    if (seatMap != null) {
      for (final c in seatMap.coaches) {
        final nr = int.tryParse(c.number);
        if (nr != null) freeByWagon[nr] = c.freeCount;
      }
    }
    final effectiveWagon = _effectiveWagon(seatMap);

    final showTrack =
        sequence != null && PlatformTrackView.hasGeometry(sequence);
    final gleis = sequence?.departurePlatform ?? '';

    return Scaffold(
      appBar: AppBar(
        title: Text(
          trip.line.displayName.isNotEmpty
              ? 'Wagenreihung · ${trip.line.displayName}'
              : 'Wagenreihung',
        ),
      ),
      body: ListView(
        padding: EdgeInsets.only(bottom: 32 + AppNavBar.insetOf(context)),
        children: [
          if (gleis.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Row(
                children: [
                  Icon(Icons.train, size: 18, color: theme.colorScheme.primary),
                  const SizedBox(width: 6),
                  Text(
                    'Gleis $gleis',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  if (sequence!.hasPlatformChange) ...[
                    const SizedBox(width: 8),
                    Text(
                      '(statt ${sequence.scheduledPlatform})',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                    ),
                  ],
                ],
              ),
            ),

          if (sequence != null && sequence.splits)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: splitTrainBanner(
                context,
                sequence,
                targetDestination: widget.targetDestination,
              ),
            ),

          // Large to-scale platform: section letters + cars + Gleis, all
          // sharing one scale so they line up and scroll together.
          if (showTrack) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 14, 8, 6),
              child: PlatformTrackView(
                sequence: sequence,
                selectable: reservable,
                freeByWagon: freeByWagon,
                selectedWagon: effectiveWagon,
                onCoachTap: reservable
                    ? (c) => setState(() => _selectedWagon = c.wagonNumber)
                    : null,
                carHeight: 64,
                targetCarWidth: 78,
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Wrap(
                spacing: 14,
                runSpacing: 6,
                children: [
                  _legendItem(AppColors.firstClass, '1. Klasse'),
                  _legendItem(AppColors.secondClass, '2. Klasse'),
                  _legendItem(AppColors.restaurant, 'Restaurant'),
                  _legendItem(AppColors.locomotive, 'Triebkopf'),
                  // Only when this train actually carries one — an entry that
                  // is always there teaches nothing (#100).
                  if (_hasUnavailableCoach(sequence)) _unavailableLegendItem(),
                ],
              ),
            ),
          ]
          // No platform geometry → chip picker built from the seat map.
          else if (seatMap != null && seatMap.coaches.isNotEmpty)
            _coachChips(theme, seatMap, effectiveWagon),

          if (reservable) ...[
            const Divider(height: 28),
            _seatSection(theme, seatAsync, effectiveWagon),
          ],
        ],
      ),
    );
  }

  /// Horizontal chips, one per coach, used when there's no platform layout to
  /// draw — tap to pick the coach whose seats are shown below.
  Widget _coachChips(ThemeData theme, SeatMap map, int? selected) {
    return SizedBox(
      height: 72,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
        itemCount: map.coaches.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (_, i) {
          final c = map.coaches[i];
          final nr = int.tryParse(c.number);
          final isSel = nr != null && nr == selected;
          final full = !c.hasFree;
          return InkWell(
            onTap: nr != null
                ? () => setState(() => _selectedWagon = nr)
                : null,
            borderRadius: BorderRadius.circular(10),
            child: Container(
              width: 64,
              decoration: BoxDecoration(
                color: isSel
                    ? AppColors.onTime.withValues(alpha: 0.16)
                    : theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: isSel
                      ? AppColors.onTime
                      : theme.colorScheme.outlineVariant,
                  width: isSel ? 2.5 : 1,
                ),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    'Wg ${c.number}',
                    style: theme.textTheme.labelLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${c.freeCount} frei',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: full ? AppColors.closedCoach : AppColors.onTime,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _seatSection(
    ThemeData theme,
    AsyncValue<SeatMap?>? async,
    int? wagon,
  ) {
    if (async == null) return const SizedBox.shrink();
    return async.when(
      loading: () => const Padding(
        padding: EdgeInsets.all(40),
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (_, _) => _info(theme, 'Sitzplan konnte nicht geladen werden.'),
      data: (map) {
        if (map == null || map.isEmpty) {
          return _info(theme, 'Für diesen Zug ist kein Sitzplan verfügbar.');
        }
        final coach = _coachFor(map, wagon);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: Text(
                '${map.totalFree} von ${map.totalSeats} Plätzen frei'
                '${coach != null ? '  ·  Wagen ${coach.number}: ${coach.freeCount} frei' : map.freeCoachHint}',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            if (coach == null)
              _info(theme, 'Wagen oben antippen, um den Sitzplan zu sehen.')
            else if (coach.layout == null)
              _info(theme, 'Für Wagen ${coach.number} liegt kein Plan vor.')
            else
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: Container(
                    color: theme.colorScheme.surfaceContainerHighest.withValues(
                      alpha: 0.35,
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    child: Center(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        // Bigger unit → a roomy plan; the page itself scrolls
                        // vertically so the whole (tall) coach is reachable.
                        child: CoachSeatPlan(
                          coach: coach,
                          layout: coach.layout!,
                          unit: 10,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Wrap(
                spacing: 16,
                runSpacing: 8,
                children: [
                  _legendItem(AppColors.onTime, 'frei'),
                  _legendItem(AppColors.closedCoach, 'reserviert'),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  SeatCoach? _coachFor(SeatMap map, int? wagon) {
    if (map.coaches.isEmpty) return null;
    if (wagon != null) {
      for (final c in map.coaches) {
        if (int.tryParse(c.number) == wagon) return c;
      }
    }
    for (final c in map.coaches) {
      if (c.hasFree) return c;
    }
    return map.coaches.first;
  }

  int? _effectiveWagon(SeatMap? map) {
    if (_selectedWagon != null) return _selectedWagon;
    if (map == null) return null;
    for (final c in map.coaches) {
      if (c.hasFree) return int.tryParse(c.number);
    }
    return map.coaches.isNotEmpty
        ? int.tryParse(map.coaches.first.number)
        : null;
  }

  /// Whether any car of this train is closed to riders — the red-✗ car DB
  /// labels "Nicht verfügbarer Wagen" (#100).
  static bool _hasUnavailableCoach(CoachSequence? seq) =>
      seq != null &&
      seq.groups.any((g) => g.coaches.any((c) => !c.isOpen && !c.isLocomotive));

  Widget _unavailableLegendItem() => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 11,
        height: 11,
        decoration: BoxDecoration(
          color: AppColors.closedCoach,
          borderRadius: BorderRadius.circular(3),
        ),
        alignment: Alignment.center,
        child: unavailableCoachMark(size: 9),
      ),
      const SizedBox(width: 5),
      const Text('Nicht verfügbar', style: TextStyle(fontSize: 12)),
    ],
  );

  Widget _legendItem(Color color, String label) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 11,
        height: 11,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(3),
        ),
      ),
      const SizedBox(width: 5),
      Text(label, style: const TextStyle(fontSize: 12)),
    ],
  );

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
