/// Swapping one leg of a journey for another departure moves everything behind
/// it: on Kiel→München, taking the next ICE out of Kiel means the Hamburg
/// connection you had is gone (or an hour of waiting). These decide whether the
/// tail has to be re-planned and which onward journey can actually be boarded.
library;

import '../models/journey.dart';

/// Whether the legs after [index] still describe a journey that can be
/// travelled after the swap.
///
/// True as soon as the arrival moved at all *and* there is a train behind it:
/// later means the old connection may be missed, earlier means the rider would
/// sit around for a connection that could be taken sooner. Both are "the tail
/// no longer belongs to this ride".
bool tailNeedsReplan(
  List<JourneyLeg> legs,
  int index, {
  required DateTime? oldArrival,
  required DateTime? newArrival,
}) {
  if (index < 0 || index >= legs.length) return false;
  if (newArrival == null || newArrival == oldArrival) return false;
  return legs.skip(index + 1).any((l) => !l.isWalking);
}

/// The first journey in [candidates] that leaves no earlier than [arrival] —
/// i.e. one the rider standing on that platform can actually board.
///
/// The backend answers a departure query with a window that can start slightly
/// before the requested time, so the list is filtered rather than trusted.
/// Null when nothing in the window is boardable.
Journey? firstBoardable(List<Journey> candidates, DateTime arrival) {
  for (final j in candidates) {
    final dep = j.plannedDeparture ?? j.departure;
    if (dep != null && !dep.isBefore(arrival)) return j;
  }
  return null;
}

/// [legs] up to and including [index], then [onward]'s legs — the swapped ride
/// plus its re-planned continuation.
List<JourneyLeg> spliceTail(
  List<JourneyLeg> legs,
  int index,
  Journey onward,
) =>
    [...legs.sublist(0, index + 1), ...onward.legs];
