/// "Früher weiter": a long wait at a change, while an earlier train already
/// goes where the next change is.
///
/// Bremen → Kiel: RE4 into Hamburg-Harburg 15:30, booked S3 at 15:59, RE7 out
/// of Hamburg Hbf 16:39. Half an hour on a cold platform in Harburg — while a
/// metronom or an earlier S3 reaches Hamburg Hbf by 15:55. Same RE7, same
/// arrival in Kiel, but the wait moves to the big station: more trains to
/// fall back on, warm, food. The rider only sees that if the app says it.
///
/// Pure: the caller fetches the candidates (one search from the change
/// station to where the following train leaves) and this decides.
library;

import '../models/journey.dart';

/// A long-distance product: a Sparpreis binds it to the booked train, so an
/// earlier one is never suggested for it.
bool isLongDistanceProduct(String? product) =>
    product == 'nationalExpress' || product == 'national';

/// At what wait this is worth a search at all.
const earlierOnwardMinWaitMinutes = 15;

/// How much earlier the suggestion must leave to be worth the hassle.
const earlierOnwardMinGainMinutes = 8;

/// One suggestion: take [journey] instead of the booked leg(s) between the two
/// changes.
class EarlierOnward {
  /// The found connection, from the change station to [JourneyLeg.origin] of
  /// the following train (or to the booked leg's destination when there is no
  /// following train).
  final Journey journey;

  /// The train in [journey] — the one to name in the hint.
  final JourneyLeg train;

  /// Minutes it leaves before the booked one.
  final int gainMinutes;

  /// The wait at the next change after taking it. Null when the booked leg is
  /// the last train (then the gain is an earlier arrival).
  final int? waitThereMinutes;

  const EarlierOnward({
    required this.journey,
    required this.train,
    required this.gainMinutes,
    this.waitThereMinutes,
  });
}

DateTime? _dep(JourneyLeg l) => l.departure ?? l.plannedDeparture;
DateTime? _arr(JourneyLeg l) => l.arrival ?? l.plannedArrival;

/// The best earlier way from the change into [booked] onwards, or null.
///
/// * [readyAt] — when the rider can board at the change station (live arrival
///   plus a buffer, or now when they are already standing there).
/// * [mustArriveBy] — when the rider has to be at the next change, ready for
///   the following train (its departure minus a buffer). Null when [booked] is
///   the last train.
///
/// A candidate must have one train only (a second change to gain time is not
/// a simplification), leave at or after [readyAt], leave at least
/// [earlierOnwardMinGainMinutes] before [booked], and arrive in time. Of those
/// the one that arrives first wins — that is the one that moves the most of
/// the wait.
EarlierOnward? pickEarlierOnward({
  required List<Journey> candidates,
  required JourneyLeg booked,
  required DateTime readyAt,
  DateTime? mustArriveBy,
}) {
  final bookedDep = _dep(booked);
  final bookedArr = _arr(booked);
  if (bookedDep == null) return null;
  EarlierOnward? best;
  DateTime? bestArr;
  for (final j in candidates) {
    final trains = j.legs.where((l) => !l.isWalking).toList();
    if (trains.length != 1) continue;
    final t = trains.single;
    if (t.cancelled || t.partiallyCancelled || t.endsEarly) continue;
    if (isLongDistanceProduct(t.line?.product)) continue;
    if (t.tripId != null && t.tripId == booked.tripId) continue;
    final dep = j.legs.first.departure ?? j.legs.first.plannedDeparture;
    final arr = j.legs.last.arrival ?? j.legs.last.plannedArrival;
    if (dep == null || arr == null) continue;
    if (dep.isBefore(readyAt)) continue;
    final gain = bookedDep.difference(dep).inMinutes;
    if (gain < earlierOnwardMinGainMinutes) continue;
    if (mustArriveBy != null) {
      if (arr.isAfter(mustArriveBy)) continue;
    } else if (bookedArr != null && !arr.isBefore(bookedArr)) {
      // Last train: earlier only counts when it also arrives earlier.
      continue;
    }
    if (bestArr != null && !arr.isBefore(bestArr)) continue;
    bestArr = arr;
    // waitThereMinutes is filled by [earlierOnwardFor], which knows the
    // following train's real departure (not the buffered deadline).
    best = EarlierOnward(journey: j, train: t, gainMinutes: gain);
  }
  return best;
}

/// [pickEarlierOnward] plus the wait at the next change, which needs the
/// following train's departure rather than the buffered deadline.
EarlierOnward? earlierOnwardFor({
  required List<Journey> candidates,
  required JourneyLeg booked,
  required DateTime readyAt,
  JourneyLeg? following,
  int bufferMinutes = 5,
}) {
  final followDep = following == null ? null : _dep(following);
  final pick = pickEarlierOnward(
    candidates: candidates,
    booked: booked,
    readyAt: readyAt,
    mustArriveBy: followDep?.subtract(Duration(minutes: bufferMinutes)),
  );
  if (pick == null || followDep == null) return pick;
  final arr =
      pick.journey.legs.last.arrival ?? pick.journey.legs.last.plannedArrival;
  return EarlierOnward(
    journey: pick.journey,
    train: pick.train,
    gainMinutes: pick.gainMinutes,
    waitThereMinutes: arr == null ? null : followDep.difference(arr).inMinutes,
  );
}

/// [legs] with everything from [fromIndex] up to (not including) [untilIndex]
/// replaced by [onward]'s legs. [untilIndex] null = to the end.
List<JourneyLeg> spliceEarlierOnward(
  List<JourneyLeg> legs,
  int fromIndex,
  int? untilIndex,
  Journey onward,
) => [
  ...legs.sublist(0, fromIndex),
  ...onward.legs,
  if (untilIndex != null) ...legs.sublist(untilIndex),
];
