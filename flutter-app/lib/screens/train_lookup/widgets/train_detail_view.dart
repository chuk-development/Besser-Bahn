import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../models/coach_sequence.dart';
import '../../../models/seat_map.dart';
import '../../../models/trip.dart';
import '../../../providers/seat_map_provider.dart';
import 'coach_sequence_view.dart';
import 'seat_map_view.dart';
import 'stop_timeline.dart';
import 'train_info_header.dart';
import 'train_map_view.dart';

/// The full detail of one train: header, live map, coach sequence and stop
/// timeline. Used standalone on the train screen and stacked per leg in the
/// connection view. Returns column children (no Scaffold) so it can be embedded.
///
/// For trains with a reservable seat plan, the free-seat view lives *inside*
/// the Wagenreihung card: the train doubles as the coach picker (selectable
/// cars + free-seat badges) and the selected coach's seat plan renders below
/// it — no separate "Freie Sitzplätze" section. Selection + class state live
/// here and feed both. When there's no Wagenreihung, the panel stands alone.
class TrainDetailView extends ConsumerStatefulWidget {
  final Trip trip;
  final CoachSequence? coach;
  final void Function(Stopover stop)? onStopTap;

  /// EVA / name of the stop you board at and alight at on this leg. When set,
  /// the timeline collapses stops outside that segment (e.g. the train's run
  /// before your boarding station). Null = standalone train, show all stops.
  final String? boardingId;
  final String? alightingId;

  const TrainDetailView({
    super.key,
    required this.trip,
    this.coach,
    this.onStopTap,
    this.boardingId,
    this.alightingId,
  });

  @override
  ConsumerState<TrainDetailView> createState() => _TrainDetailViewState();
}

class _TrainDetailViewState extends ConsumerState<TrainDetailView> {
  bool _firstClass = false;
  int? _selectedWagon; // explicit user pick; null → auto (first free)

  @override
  Widget build(BuildContext context) {
    final trip = widget.trip;
    final reservable = SeatPlanBody.isAvailableFor(trip);

    final req = reservable
        ? SeatMapRequest.fromTrip(trip, firstClass: _firstClass)
        : null;
    final seatAsync = req != null ? ref.watch(seatMapProvider(req)) : null;
    final SeatMap? seatMap =
        seatAsync?.maybeWhen(data: (m) => m, orElse: () => null);

    // Free-seat count per wagon, and the effective selection (explicit pick or
    // first coach with free seats) shared by the Wagenreihung and the panel.
    final freeByWagon = <int, int>{};
    if (seatMap != null) {
      for (final c in seatMap.coaches) {
        final nr = int.tryParse(c.number);
        if (nr != null) freeByWagon[nr] = c.freeCount;
      }
    }
    final effectiveWagon = _effectiveWagon(seatMap);
    final hasWagenreihung = widget.coach != null;

    final seatPlan = reservable
        ? SeatPlanBody(
            trip: trip,
            firstClass: _firstClass,
            onFirstClass: (v) => setState(() {
              _firstClass = v;
              _selectedWagon = null;
            }),
            seatAsync: seatAsync,
            selectedWagon: effectiveWagon,
            onSelectWagon: (nr) => setState(() => _selectedWagon = nr),
            hasExternalSelector: hasWagenreihung,
          )
        : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TrainInfoHeader(trip: trip),
        TrainMapView(trip: trip),
        if (widget.coach != null)
          CoachSequenceView(
            sequence: widget.coach!,
            selectable: reservable,
            freeByWagon: freeByWagon,
            selectedWagon: effectiveWagon,
            onCoachTap: (c) => setState(() => _selectedWagon = c.wagonNumber),
            seatPlan: seatPlan,
          )
        else if (seatPlan != null)
          Card(
            margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            clipBehavior: Clip.antiAlias,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: seatPlan,
            ),
          ),
        StopTimeline(
          stopovers: trip.stopovers,
          onStopTap: widget.onStopTap,
          boardingId: widget.boardingId,
          alightingId: widget.alightingId,
        ),
      ],
    );
  }

  int? _effectiveWagon(SeatMap? map) {
    if (_selectedWagon != null) return _selectedWagon;
    if (map == null) return null;
    for (final c in map.coaches) {
      if (c.hasFree) return int.tryParse(c.number);
    }
    return map.coaches.isNotEmpty ? int.tryParse(map.coaches.first.number) : null;
  }
}
