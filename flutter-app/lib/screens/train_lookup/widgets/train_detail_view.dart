import 'package:flutter/material.dart';

import '../../../models/coach_sequence.dart';
import '../../../models/trip.dart';
import 'coach_sequence_view.dart';
import 'stop_timeline.dart';
import 'train_info_header.dart';
import 'train_map_view.dart';

/// The full detail of one train: header, live map, coach sequence and stop
/// timeline. Used standalone on the train screen and stacked per leg in the
/// connection view. Returns column children (no Scaffold) so it can be embedded.
class TrainDetailView extends StatelessWidget {
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
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TrainInfoHeader(trip: trip),
        TrainMapView(trip: trip),
        if (coach != null) CoachSequenceView(sequence: coach!),
        StopTimeline(
          stopovers: trip.stopovers,
          onStopTap: onStopTap,
          boardingId: boardingId,
          alightingId: alightingId,
        ),
      ],
    );
  }
}
