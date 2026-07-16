import '../models/journey.dart';
import '../models/station.dart';
import '../models/trip.dart';

/// Products the Deutschlandticket is valid on: local and regional transport
/// only. Anything else (ICE/IC/EC, and any product we can't identify) needs a
/// ticket.
const _dTicketProducts = {
  'regional',
  'suburban',
  'subway',
  'tram',
  'bus',
  'ferry',
};

/// Does the Deutschlandticket cover a train of this [product]?
///
/// Null (an onward train we couldn't identify) is deliberately false: an
/// unidentified ICE must never read as free.
bool isDTicketProduct(String? product) =>
    product != null && _dTicketProducts.contains(product);

/// Is the segment from stop [i] to stop [j] of [stops] entirely travelled on
/// trains the Deutschlandticket covers?
///
/// Answered from the SELECTED connection's own trains (see `_product` above),
/// so it needs no network call and can't be fooled by a cheaper regional
/// alternative that the rider isn't taking. ALL hops must be covered: one ICE
/// hop makes the whole segment payable — the bug behind #13, where any single
/// D-Ticket-eligible section marked an ICE segment as free.
bool isSegmentDTicketCovered(
    List<Map<String, dynamic>> stops, int i, int j) {
  for (var k = i; k < j; k++) {
    final product = stops[k]['_product'];
    // '' = no train on this hop (transfer gap) → fare-neutral, keep checking.
    if (product == '') continue;
    // null = an onward train we couldn't identify → assume it needs a ticket.
    if (product is! String || !isDTicketProduct(product)) return false;
  }
  return true;
}

/// The train numbers the SELECTED connection uses from stop [i] to stop [j],
/// in order and de-duplicated (one train spans many hops).
///
/// Lets a segment price be checked against the trains the rider is actually
/// on: the backends return every connection between two stops, and the
/// cheapest offer may be a Sparpreis bound to a different train (#13).
/// Returns empty when any hop's train is unknown — then there's nothing to
/// match on and the price can't be vouched for.
List<String> segmentTrainNumbers(
    List<Map<String, dynamic>> stops, int i, int j) {
  final trains = <String>[];
  for (var k = i; k < j; k++) {
    if (stops[k]['_product'] == '') continue; // transfer gap, no train
    final nr = stops[k]['_fahrtNr'];
    if (nr is! String || nr.isEmpty) return const [];
    if (trains.isEmpty || trains.last != nr) trains.add(nr);
  }
  return trains;
}

/// One station of a split-candidate list, from whichever source supplied it.
class _Stop {
  final Station stop;
  final DateTime? time;
  const _Stop(this.stop, this.time);
}

String _norm(String s) => s.toLowerCase().trim().replaceAll(RegExp(r'\s+'), ' ');

bool _sameStation(Station a, Station b) {
  if (a.id.isNotEmpty && b.id.isNotEmpty) return a.id == b.id;
  return a.name.isNotEmpty && _norm(a.name) == _norm(b.name);
}

/// Index of [station] in [stops] at or after [from], or -1.
///
/// A run may call at the same station twice (Ring lines, Zürich-style
/// turnbacks), so when [when] is known the closest call in time wins rather
/// than blindly the first one.
int _indexOfStop(List<Stopover> stops, Station station, DateTime? when,
    {int from = 0}) {
  var best = -1;
  Duration? bestDiff;
  for (var i = from; i < stops.length; i++) {
    if (!_sameStation(stops[i].stop, station)) continue;
    final t = stops[i].departure ??
        stops[i].plannedDeparture ??
        stops[i].arrival ??
        stops[i].plannedArrival;
    if (when == null || t == null) {
      if (best < 0) best = i;
      continue;
    }
    final diff = t.difference(when).abs();
    if (bestDiff == null || diff < bestDiff) {
      best = i;
      bestDiff = diff;
    }
  }
  return best;
}

/// The stretch of a train's full run [trip] that [leg] actually rides —
/// board stop through alight stop, both included.
///
/// `/mob/zuglauf/{id}` answers with the WHOLE run: a Berlin Hbf → Braunschweig
/// leg on an ICE that carries on to Frankfurt comes back with Hildesheim and
/// Frankfurt(Main)Hbf in the list too. Handing those to the split engine offers
/// tickets *past* the rider's destination — "Berlin Hbf → Hildesheim Hbf" for a
/// trip that ends in Braunschweig (#22). So cut the run down to the leg first.
///
/// Returns null when either end can't be located; the caller then falls back to
/// the leg's own stop list, which is leg-scoped by construction.
List<Stopover>? tripStopsForLeg(Trip trip, JourneyLeg leg) {
  final board = _indexOfStop(
      trip.stopovers, leg.origin, leg.plannedDeparture ?? leg.departure);
  if (board < 0) return null;
  final alight = _indexOfStop(
      trip.stopovers, leg.destination, leg.plannedArrival ?? leg.arrival,
      from: board + 1);
  if (alight < 0) return null;
  return trip.stopovers.sublist(board, alight + 1);
}

/// The stops of [leg] to offer as split candidates, richest source first: the
/// already-fetched run from the trip cache (trimmed to this leg — see
/// [tripStopsForLeg]) when it knows more stops than the search did, else the
/// leg's own `halte`, else just its two endpoints.
List<_Stop> _legStops(JourneyLeg leg, Trip? trip) {
  final own = [
    for (final so in leg.stopovers) _Stop(so.stop, so.departure ?? so.arrival)
  ];
  if (trip != null) {
    final ride = tripStopsForLeg(trip, leg);
    if (ride != null && ride.length > own.length) {
      return [
        for (final so in ride)
          _Stop(
              so.stop,
              so.departure ??
                  so.plannedDeparture ??
                  so.arrival ??
                  so.plannedArrival)
      ];
    }
  }
  if (own.isNotEmpty) return own;
  return [
    _Stop(leg.origin, leg.plannedDeparture ?? leg.departure),
    _Stop(leg.destination, leg.arrival),
  ];
}

/// Build the ordered, de-duplicated station list (split candidates) for a
/// journey straight from its legs — the Vendo search already carries every
/// `halt` in `leg.stopovers`, so no extra trip fetch is needed. [tripFor] may
/// hand over an already-fetched full run per leg (the connection-detail screen
/// has one cached); it's only used where it adds stops, and always trimmed to
/// the leg. One list for the bulk comparison and the single analysis, so both
/// break at the same stations.
///
/// Each entry is `{name, id, departure_iso}`, ready for the split engine.
///
/// Each stop also carries `_product`, describing how the SELECTED connection
/// travels *onward* from it. That's what makes "is this hop covered by the
/// Deutschlandticket" answerable about the connection the rider actually
/// picked, rather than about some other train that happens to serve the same
/// pair of stations (#13). Three cases, deliberately distinct:
///
///  * a product string (`regional`, `nationalExpress`, …) — the onward train
///  * `''` — no train leaves here: the journey's last stop, or a transfer gap
///    between two legs. Fare-neutral.
///  * `null` — there IS an onward train but its product is unknown. Must block
///    coverage, or an unidentified ICE reads as free.
///
/// The candidate count is capped (the pairwise price scan grows with its
/// square): every leg boundary (start / terminus / transfer) is kept and the
/// intermediate stops are evenly sampled down to [cap].
List<Map<String, dynamic>> splitStopsFromJourney(
  Journey journey, {
  int cap = 12,
  Trip? Function(JourneyLeg leg)? tripFor,
}) {
  final stops = <Map<String, dynamic>>[];

  void add(String id, String name, DateTime? dep, bool boundary, String? product,
      String? fahrtNr) {
    if (id.isEmpty) return;
    if (stops.isNotEmpty && stops.last['id'] == id) {
      if (dep != null) stops.last['departure_iso'] = dep.toIso8601String();
      if (boundary) stops.last['_boundary'] = true;
      // A transfer stop is arrived at on one train and left on the next — the
      // onward train is the one that matters, so it overwrites the ''
      // the arriving leg left here.
      stops.last['_product'] = product;
      stops.last['_fahrtNr'] = fahrtNr;
      return;
    }
    stops.add({
      'name': name,
      'id': id,
      'departure_iso': dep?.toIso8601String() ?? '',
      '_boundary': boundary,
      '_product': product,
      '_fahrtNr': fahrtNr,
    });
  }

  for (final leg in journey.legs) {
    if (leg.isWalking) continue;
    // Every stop of this leg except its last is left aboard THIS train. A leg
    // with no line data yields null → unknown, which blocks coverage.
    final product = leg.line != null ? (leg.line!.product) : null;
    final fahrtNr = leg.line?.fahrtNr;
    // Boundaries are this leg's board and alight stop — where the rider really
    // gets on and off. Never the ends of the underlying train run, or the cap
    // below would protect stations the connection doesn't even reach (#22).
    final legStops = _legStops(leg, tripFor?.call(leg));
    for (var i = 0; i < legStops.length; i++) {
      final s = legStops[i];
      final last = i == legStops.length - 1;
      add(s.stop.id, s.stop.name, s.time, i == 0 || last, last ? '' : product,
          last ? null : fahrtNr);
    }
  }

  if (stops.length > cap) {
    final boundaries = stops.where((s) => s['_boundary'] == true).toList();
    final inner = stops.where((s) => s['_boundary'] != true).toList();
    final slots = (cap - boundaries.length).clamp(0, inner.length);
    final keep = <Map<String, dynamic>>{...boundaries};
    if (slots > 0) {
      final step = inner.length / slots;
      for (var k = 0; k < slots; k++) {
        keep.add(inner[(k * step).floor()]);
      }
    }
    stops.removeWhere((s) => !keep.contains(s));
  }

  return stops;
}
