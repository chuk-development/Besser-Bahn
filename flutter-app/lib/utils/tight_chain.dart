/// "Schneller ankommen mit knappen Umstiegen."
///
/// DB plans every change with the station's own minimum transfer time, and
/// `minUmstiegsdauer` can only raise it, never lower it. On Bremen → Kiel that
/// meant half an hour in Hamburg-Harburg and again half an hour at Hamburg
/// Hbf — while a rider who changes in 3 minutes was on earlier trains at
/// both and in Kiel much sooner.
///
/// So the chain is built here, one change at a time: from the change station,
/// search onward from "arrival + [tightMinutes]", ride only the FIRST train of
/// the best answer, and repeat from where that train ends. Each search then
/// starts on the platform the rider really stands on, at the time they really
/// get there — the backend's transfer rule never applies, because every hop
/// is a fresh start.
library;

import '../models/journey.dart';
import '../models/station.dart';

/// One search: connections from [from] leaving at [at] or later.
typedef ChainSearch = Future<List<Journey>> Function(Station from, DateTime at);

DateTime? _dep(Journey j) =>
    j.legs.firstOrNull?.departure ?? j.legs.firstOrNull?.plannedDeparture;
DateTime? _arr(Journey j) =>
    j.legs.lastOrNull?.arrival ?? j.legs.lastOrNull?.plannedArrival;

/// The candidate that arrives first, of those leaving at or after [at].
Journey? _bestFrom(List<Journey> candidates, DateTime at) {
  Journey? best;
  for (final j in candidates) {
    final d = _dep(j);
    final a = _arr(j);
    if (d == null || a == null || d.isBefore(at)) continue;
    if (j.legs.any(
      (l) => !l.isWalking && (l.cancelled || l.partiallyCancelled),
    )) {
      continue;
    }
    if (best == null) {
      best = j;
      continue;
    }
    final ba = _arr(best)!;
    // First to arrive; on a tie the later departure (less waiting).
    if (a.isBefore(ba) || (a == ba && d.isAfter(_dep(best)!))) best = j;
  }
  return best;
}

/// [j]'s legs up to and including its first train (leading walks kept).
List<JourneyLeg> _throughFirstTrain(Journey j) {
  final out = <JourneyLeg>[];
  for (final l in j.legs) {
    out.add(l);
    if (!l.isWalking) break;
  }
  return out;
}

/// The chain from [start] (ready to board at [readyAt]) to [destination] with
/// changes of [tightMinutes], or null when a search finds nothing.
///
/// [maxHops] caps the searches: every hop is one request against a backend
/// that answers bursts with minutes of 429.
Future<Journey?> buildTightChain({
  required ChainSearch search,
  required Station start,
  required DateTime readyAt,
  required int tightMinutes,
  int maxHops = 4,
}) async {
  final legs = <JourneyLeg>[];
  var from = start;
  var at = readyAt;
  for (var hop = 0; hop < maxHops; hop++) {
    final best = _bestFrom(await search(from, at), at);
    if (best == null) return null;
    final trains = best.legs.where((l) => !l.isWalking).length;
    // Last hop (a direct answer) → take it whole, walk to the exit included.
    if (trains <= 1) {
      legs.addAll(best.legs);
      return Journey(legs: legs);
    }
    final part = _throughFirstTrain(best);
    legs.addAll(part);
    final train = part.last;
    final arr = train.arrival ?? train.plannedArrival;
    if (arr == null) return null;
    from = train.destination;
    at = arr.add(Duration(minutes: tightMinutes));
  }
  return null;
}

/// The smallest change in [chain], with where it is — for "4 min in Hamburg
/// Hbf" on the card, so the rider sees what they sign up for.
({int minutes, String station})? tightestChange(Journey chain) {
  ({int minutes, String station})? out;
  JourneyLeg? prev;
  for (final l in chain.legs) {
    if (l.isWalking) continue;
    if (prev != null) {
      final a = prev.arrival ?? prev.plannedArrival;
      final d = l.departure ?? l.plannedDeparture;
      if (a != null && d != null) {
        final m = d.difference(a).inMinutes;
        if (out == null || m < out.minutes) {
          out = (minutes: m, station: l.origin.name);
        }
      }
    }
    prev = l;
  }
  return out;
}
