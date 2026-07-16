import '../models/journey.dart';
import '../models/station.dart';
import '../models/transfer_profile.dart';
import '../models/trip.dart';
import 'split_stops.dart';

/// Rescue option B for a transfer that's about to break (#26).
///
/// Option A — already in the leg switcher — rides the delayed train to the
/// planned change station, watches the connection leave, and offers the next
/// train from there. Option B is the move a seasoned rider makes instead: get
/// off EARLIER, at a stop the train hasn't reached yet, and carry on from
/// there on a different route. It often wins outright, because the transfer is
/// never missed in the first place.
///
/// Everything here is pure: which stops are worth spending a search on, which
/// results are actually a win, and what the suggestion costs in ticket terms.
/// The searching itself lives in `services/earlier_alight_service.dart` — this
/// file must stay testable without a backend, because every rule below is a
/// judgement call that can quietly go wrong (suggest a change you can't make,
/// or one that lands you later than doing nothing).

/// A stop of the train you're riding that you could get off at, with the time
/// you'd REALLY be there.
class AlightStop {
  final Station station;

  /// Live arrival — realtime wherever the source has it. The whole feature
  /// turns on this: judging an early exit against the timetable while the
  /// train is 40 minutes down would offer changes that left long ago.
  final DateTime? arrival;

  /// Timetabled arrival, where the source keeps both. For display only —
  /// never decides anything.
  final DateTime? plannedArrival;

  /// This stop is dropped from the run — the train won't call here at all.
  final bool cancelled;

  /// The train stops but won't let you off ("Hält nur zum Einsteigen").
  /// Looks like any other stop, and you simply cannot get out.
  final bool noAlighting;

  const AlightStop({
    required this.station,
    this.arrival,
    this.plannedArrival,
    this.cancelled = false,
    this.noAlighting = false,
  });
}

/// The stops [leg] calls at, board through alight, as alight candidates.
///
/// [trip] is the already-fetched full run of the same train (the connection
/// screen caches one per leg). It's the fresher source — the journey search's
/// `halte` carry the realtime of the moment you searched, while the trip is
/// re-fetched around every stop — so it wins whenever it's there, trimmed to
/// the stretch actually ridden (see [tripStopsForLeg]; the raw run reaches
/// past the rider's destination, #22).
List<AlightStop> alightStopsOfLeg(JourneyLeg leg, {Trip? trip}) {
  if (trip != null) {
    final ride = tripStopsForLeg(trip, leg);
    if (ride != null && ride.length >= leg.stopovers.length) {
      return [
        for (final so in ride)
          AlightStop(
            station: so.stop,
            arrival: so.arrival ?? so.plannedArrival,
            plannedArrival: so.plannedArrival,
            cancelled: so.cancelled,
            noAlighting: so.noAlighting,
          )
      ];
    }
  }
  return [
    for (final so in leg.stopovers)
      AlightStop(
        station: so.stop,
        // LegStopover.arrival is already realtime-preferring (vendo
        // `ezAnkunftsDatum ?? ankunftsDatum`), so there is no planned value
        // to keep apart here.
        arrival: so.arrival,
        cancelled: so.cancelled,
        noAlighting: so.noAlighting,
      )
  ];
}

/// The earlier stops worth spending a search on, in route order.
///
/// [stops] is the leg's full ride from [alightStopsOfLeg]: first entry = where
/// you boarded, last = the planned change station. Both are dropped — getting
/// off where you got on is nonsense, and getting off at the change station is
/// just the plan.
///
/// Every rule here exists to keep the request count down (one search per stop,
/// against a backend that answers a burst with a 4-minute 429 — see
/// `project_vendo_rate_limit`) while only dropping stops that are useless
/// anyway:
///
///  * no live arrival → nothing to compute a change from;
///  * cancelled / "Hält nur zum Einsteigen" → you can't get out there;
///  * arriving within [lead] → the train is practically at the door: no time
///    to read a suggestion, pack up and get off. [now] must be the real clock,
///    which is why it's a parameter.
///
/// [cap] then keeps the LAST candidates before the change station, not the
/// first. They sit closest to the hub the connection was routed through, so
/// they're the ones that plausibly offer another way to the same destination —
/// searching from the stop an hour back mostly rediscovers the train you're
/// already on.
List<AlightStop> pickEarlierAlightStops({
  required List<AlightStop> stops,
  required DateTime now,
  int cap = 4,
  Duration lead = const Duration(minutes: 5),
}) {
  if (stops.length < 3) return const [];
  final earliest = now.add(lead);
  final usable = <AlightStop>[];
  for (final s in stops.sublist(1, stops.length - 1)) {
    if (s.cancelled || s.noAlighting) continue;
    final arr = s.arrival;
    if (arr == null || arr.isBefore(earliest)) continue;
    usable.add(s);
  }
  if (usable.length <= cap) return usable;
  return usable.sublist(usable.length - cap);
}

/// What the suggestion costs in ticket terms — the part that must never be
/// left off (#26).
///
/// A Sparpreis is bound to the booked trains: getting off early can void it
/// and turn a helpful tip into a Fahrpreisnacherhebung. The app cannot know
/// which ticket the rider holds — the journey search offers a price, it does
/// not report what was bought — so the default is to say so plainly rather
/// than stay silent.
enum AlightTicketNote {
  /// We don't know the fare. Assume it may be bound and say it.
  mayBeTrainBound(
    'Ticket kann zugbunden sein',
    'Sparpreise gelten nur in den gebuchten Zügen. Früher aussteigen kann das '
        'Ticket entwerten — im Zweifel vorher das Zugpersonal fragen.',
  ),

  /// The rider travels on the Deutschlandticket and the new route stays on
  /// trains it covers — a flat pass has no Zugbindung, so this is genuinely
  /// free to do.
  dTicketCovered(
    'Deutschlandticket gilt',
    'Keine Zugbindung — du kannst frei früher aussteigen und anders weiter.',
  ),

  /// Deutschlandticket rider, but the new route uses trains it doesn't cover.
  /// Not a Zugbindung problem — a "you'd have to buy something" problem.
  dTicketNotCovered(
    'Deutschlandticket gilt hier nicht',
    'Diese Route nutzt Fernverkehr — dafür brauchst du ein zusätzliches '
        'Ticket.',
  );

  const AlightTicketNote(this.label, this.detail);

  /// Short headline for the suggestion.
  final String label;

  /// The full sentence, for the detail line.
  final String detail;
}

/// Judge the ticket risk of leaving [original] early and taking [onward].
///
/// [hasDeutschlandTicket] alone is not enough: a D-Ticket holder riding an ICE
/// bought a separate ticket for that stretch, and *that* one is the Sparpreis
/// at risk. So the pass only answers the question when the booked journey is
/// itself entirely on D-Ticket trains — otherwise we're back to "unknown, warn".
AlightTicketNote ticketNoteFor({
  required Journey original,
  required Journey onward,
  required bool hasDeutschlandTicket,
}) {
  if (!hasDeutschlandTicket) return AlightTicketNote.mayBeTrainBound;
  final booked = [for (final l in original.legs) if (!l.isWalking) l];
  if (booked.isEmpty ||
      !booked.every((l) => isDTicketProduct(l.line?.product))) {
    return AlightTicketNote.mayBeTrainBound;
  }
  final next = [for (final l in onward.legs) if (!l.isWalking) l];
  if (next.isEmpty) return AlightTicketNote.mayBeTrainBound;
  return next.every((l) => isDTicketProduct(l.line?.product))
      ? AlightTicketNote.dTicketCovered
      : AlightTicketNote.dTicketNotCovered;
}

/// One "get off early and go this way instead" suggestion, ready to show.
class EarlierAlightOption {
  /// Where to get off — earlier than planned.
  final AlightStop stop;

  /// The journey found from [stop] to the final destination.
  final Journey onward;

  /// Live arrival at [stop] (i.e. when you're standing on that platform).
  final DateTime alightArrival;

  /// Minutes between getting off and the onward departure.
  final int waitMinutes;

  /// Live arrival at the final destination on this route.
  final DateTime arrival;

  /// How much earlier than the do-nothing fallback ("connection breaks, take
  /// the next train from the planned change station") you'd get there. Always
  /// > 0 — an option that isn't a win never becomes an [EarlierAlightOption].
  final int gainMinutes;

  final AlightTicketNote ticketNote;

  const EarlierAlightOption({
    required this.stop,
    required this.onward,
    required this.alightArrival,
    required this.waitMinutes,
    required this.arrival,
    required this.gainMinutes,
    required this.ticketNote,
  });
}

/// The do-nothing fallback: you ride to the planned change station, the
/// connection is gone, you take the next thing to the final destination.
///
/// [journeys] are results of a search from the change station; [readyAt] is
/// when the delayed train really puts you there. [plannedOnwardTripId] is the
/// train you were supposed to catch — it must be excluded, or the baseline
/// becomes "you caught it after all" and nothing could ever beat it, which is
/// exactly the connection we've already judged at risk.
Journey? pickFallbackJourney({
  required List<Journey> journeys,
  required DateTime readyAt,
  String? plannedOnwardTripId,
}) {
  Journey? best;
  for (final j in journeys) {
    final dep = j.departure;
    final arr = j.arrival;
    if (dep == null || arr == null) continue;
    if (dep.isBefore(readyAt)) continue;
    if (plannedOnwardTripId != null && _firstTripId(j) == plannedOnwardTripId) {
      continue;
    }
    if (best == null || arr.isBefore(best.arrival!)) best = j;
  }
  return best;
}

/// Turn one searched-from-[stop] result into a suggestion, or reject it.
///
/// Rejects, in order of how badly each would mislead:
///
///  * the found route just stays on the train you're already on — that's not
///    getting off, that's the plan;
///  * it leaves before you're off the train;
///  * the change is one THIS rider can't make. The profile is the app's own
///    yardstick everywhere else (#11.7), so an option it would flag as "evtl.
///    nicht erreichbar" must not be offered as the rescue;
///  * it doesn't actually get you there earlier than doing nothing. The issue
///    is explicit: anything else is not a win and must not appear.
EarlierAlightOption? evaluateAlightCandidate({
  required AlightStop stop,
  required Journey onward,
  required Journey original,
  required DateTime fallbackArrival,
  required TransferProfile profile,
  required bool hasDeutschlandTicket,
  String? currentTripId,
  int minGainMinutes = 1,
  int minEffectiveGapMinutes = 3,
}) {
  final alightArrival = stop.arrival;
  final dep = onward.departure;
  final arr = onward.arrival;
  if (alightArrival == null || dep == null || arr == null) return null;
  if (currentTripId != null && _firstTripId(onward) == currentTripId) {
    return null;
  }

  final wait = dep.difference(alightArrival).inMinutes;
  if (wait < 0) return null;
  // A hard floor the rider asked for ("Mit Kind: mindestens 12 Minuten") beats
  // any scaling — they set it precisely so nothing shorter gets suggested.
  final floor = profile.minTransferMinutes;
  if (floor != null && wait < floor) return null;
  // samePlatform is deliberately not claimed: this change was never planned,
  // so nobody told us it stays on one platform. Assume a walk.
  if (profile.effectiveGap(wait) < minEffectiveGapMinutes) return null;

  final gain = fallbackArrival.difference(arr).inMinutes;
  if (gain < minGainMinutes) return null;

  return EarlierAlightOption(
    stop: stop,
    onward: onward,
    alightArrival: alightArrival,
    waitMinutes: wait,
    arrival: arr,
    gainMinutes: gain,
    ticketNote:
        ticketNoteFor(original: original, onward: onward, hasDeutschlandTicket: hasDeutschlandTicket),
  );
}

/// Best suggestion first: earliest at the destination wins, then the one with
/// fewer changes, then the later exit (stay on the train while you can — the
/// less of the plan you throw away, the less can go wrong).
List<EarlierAlightOption> rankEarlierAlightOptions(
    List<EarlierAlightOption> options) {
  final sorted = List<EarlierAlightOption>.of(options);
  sorted.sort((a, b) {
    final byArrival = a.arrival.compareTo(b.arrival);
    if (byArrival != 0) return byArrival;
    final byTransfers = a.onward.transfers.compareTo(b.onward.transfers);
    if (byTransfers != 0) return byTransfers;
    return b.alightArrival.compareTo(a.alightArrival);
  });
  return sorted;
}

/// Rebuild [legs] so the journey gets off at [option]'s stop and takes its
/// route onward: everything up to the ridden train stays, that train is cut
/// short at the new exit, and the found route is appended.
///
/// [currentLegIndex] is the train being ridden (the one whose connection is at
/// risk). Returns null when the exit isn't on that leg's stop list — better no
/// reroute than a journey that claims a stop the train doesn't make.
List<JourneyLeg>? rerouteViaEarlierAlight({
  required List<JourneyLeg> legs,
  required int currentLegIndex,
  required EarlierAlightOption option,
}) {
  if (currentLegIndex < 0 || currentLegIndex >= legs.length) return null;
  final current = legs[currentLegIndex];
  final cut = _truncateLegAt(current, option.stop);
  if (cut == null) return null;
  return [
    ...legs.sublist(0, currentLegIndex),
    cut,
    ...option.onward.legs,
  ];
}

/// [leg] as ridden only up to [stop] — the same train, a shorter ride.
///
/// Arrival data moves to the new exit; the stop list is cut there too, so the
/// timeline stops where the rider does. Platform/delay fields that described
/// the old, no-longer-travelled-to destination are dropped rather than carried
/// over — a leg ending in Fulda must not still show Frankfurt's arrival track.
JourneyLeg? _truncateLegAt(JourneyLeg leg, AlightStop stop) {
  final idx = _indexOfStation(leg.stopovers, stop.station);
  if (idx <= 0) return null;
  final so = leg.stopovers[idx];
  return JourneyLeg(
    tripId: leg.tripId,
    origin: leg.origin,
    destination: stop.station,
    departure: leg.departure,
    plannedDeparture: leg.plannedDeparture,
    departureDelay: leg.departureDelay,
    departurePlatform: leg.departurePlatform,
    plannedDeparturePlatform: leg.plannedDeparturePlatform,
    arrival: stop.arrival ?? so.arrival,
    plannedArrival: stop.plannedArrival ?? so.arrival,
    line: leg.line,
    direction: leg.direction,
    isWalking: leg.isWalking,
    cancelled: leg.cancelled,
    stopovers: leg.stopovers.sublist(0, idx + 1),
    occupancy: leg.occupancy,
    disruptions: leg.disruptions,
  );
}

int _indexOfStation(List<LegStopover> stops, Station station) {
  for (var i = 0; i < stops.length; i++) {
    final s = stops[i].stop;
    if (station.id.isNotEmpty && s.id.isNotEmpty) {
      if (s.id == station.id) return i;
      continue;
    }
    if (station.name.isNotEmpty && s.name == station.name) return i;
  }
  return -1;
}

/// The train a journey starts on, skipping the walk to the platform.
String? _firstTripId(Journey j) {
  for (final l in j.legs) {
    if (!l.isWalking) return l.tripId;
  }
  return null;
}
