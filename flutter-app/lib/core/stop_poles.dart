import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

/// One physical pole of a stop — a single side of the street, a single bay at a
/// bus station.
///
/// A stop like "Gravelottestraße" or "ZOB, Kiel" is several poles; the
/// timetable names only the stop and a bay code ("A4"), never where that bay
/// is. Two open sources answer different halves of that (#55):
///
///  * **OpenStreetMap** carries `local_ref` — the letter on the sign, which is
///    the code DB puts in a leg's `gleis` ("A4"). Coverage is uneven: at
///    Wittenberger Passau nobody has tagged one.
///  * **DELFI** (the nationwide timetable dataset, via the Transitous/MOTIS
///    API) has every pole of every stop with exact coordinates and, per pole,
///    which line departs there and where it goes. Its own bay codes are
///    internal numbering ("11") and do NOT match the signs.
///
/// So neither alone does it: OSM knows the label the rider is looking for,
/// DELFI knows the poles and the directions. [mergePoles] joins them.
class StopPole {
  final LatLng latLng;

  /// The stop's name as its source spells it.
  final String name;

  /// The bay code as signed ("A4", "2"), when a source knows it. This is what
  /// gets matched against the leg's Gleis.
  final String? bay;

  /// Where buses from this pole go, most useful first ("14 → Laboe").
  final List<String> directions;

  final bool shelter;

  const StopPole({
    required this.latLng,
    required this.name,
    this.bay,
    this.directions = const [],
    this.shelter = false,
  });

  /// One line for the map marker: the bay code if there is one, else the name.
  String get label => bay ?? name;

  /// "Richtung 14 → Laboe · 15 → Heikendorf", capped so a busy bay stays
  /// readable.
  String? get directionLabel {
    if (directions.isEmpty) return null;
    return 'Richtung ${directions.take(3).join(' · ')}';
  }

  StopPole mergedWith(StopPole other) => StopPole(
        // Keep our coordinate; the two sources agree to within a few metres.
        latLng: latLng,
        name: name.isNotEmpty ? name : other.name,
        // The signed code wins over internal numbering — whichever side has one.
        bay: bay ?? other.bay,
        directions: [
          ...directions,
          ...other.directions.where((d) => !directions.contains(d)),
        ],
        shelter: shelter || other.shelter,
      );
}

/// Metres between two coordinates (equirectangular — fine at pole distances).
double metresBetween(LatLng a, LatLng b) {
  final dy = (a.latitude - b.latitude) * 111320.0;
  final dx = (a.longitude - b.longitude) *
      111320.0 *
      math.cos(a.latitude * math.pi / 180.0);
  return math.sqrt(dx * dx + dy * dy);
}

/// Two poles closer than this are the same physical pole seen by two datasets.
/// Measured at ZOB Kiel: the same bays sit 2–4 m apart between OSM and DELFI,
/// while neighbouring bays are 18–25 m apart — so 15 m separates them cleanly.
const double kSamePoleMetres = 15;

/// Join what OSM and DELFI know about the same stop.
///
/// [signed] carries the codes off the signs (OSM), [scheduled] the complete set
/// of poles with their departures (DELFI). Poles within [kSamePoleMetres] of
/// each other are one pole; everything else is kept, because a pole missing
/// from one source is still a pole the rider can be standing at.
List<StopPole> mergePoles(List<StopPole> signed, List<StopPole> scheduled) {
  final out = <StopPole>[...signed];
  for (final pole in scheduled) {
    var merged = false;
    for (var i = 0; i < out.length; i++) {
      if (metresBetween(out[i].latLng, pole.latLng) <= kSamePoleMetres) {
        out[i] = out[i].mergedWith(pole);
        merged = true;
        break;
      }
    }
    if (!merged) out.add(pole);
  }
  // Bay code order ("A1" before "A2" before "B1"), unlabelled last.
  out.sort((a, b) => (a.bay ?? '~~').compareTo(b.bay ?? '~~'));
  return out;
}

/// The pole a leg's Gleis refers to, or null when nothing matches.
///
/// Matching is on the code alone, case- and space-insensitively: DB says "A4",
/// the sign says "A4". Never guesses by distance — marking the wrong pole is
/// worse than marking none, because the rider would cross the road for it.
StopPole? poleForGleis(List<StopPole> poles, String? gleis) {
  final wanted = _normalize(gleis);
  if (wanted == null) return null;
  for (final p in poles) {
    if (_normalize(p.bay) == wanted) return p;
  }
  return null;
}

String? _normalize(String? s) {
  if (s == null) return null;
  final t = s.trim().toUpperCase().replaceAll(RegExp(r'[\s.\-_/]'), '');
  return t.isEmpty ? null : t;
}

/// How sure we are that a pole is the rider's.
enum PoleMatch {
  /// The bay code on the sign is the one on the ticket. No doubt.
  bay,

  /// This pole is where that line, going that way, departs from. Read off the
  /// timetable, so also no real doubt — just not printed on a sign.
  route,

  /// Neither code nor line matched, so the side of the road was worked out
  /// from where the bus goes next. Right in the overwhelming majority, but a
  /// deduction — the UI says "vermutlich".
  side,
}

/// The rider's pole and how it was found.
typedef PickedPole = ({StopPole pole, PoleMatch how});

/// Which pole the rider needs, using everything we know about the ride.
///
/// Three steps, most certain first (#55):
///
///  1. **The bay code.** DB puts "A4" in the leg and OSM has it on the pole.
///  2. **The line and where it goes.** At a plain roadside stop nobody signs
///     the poles, but the timetable knows that line 310 towards Oldenburg
///     leaves from *this* side and towards Kiel from the other. [line] is the
///     leg's line ("310"), [towardsName] where this ride is headed.
///  3. **The side of the road.** With neither, the direction of travel still
///     answers it: buses in Germany stop on the right-hand side, so the pole
///     right of the line from here to [nextStop] is the one. This is the case
///     the rider solves by looking at the map — worth doing for them.
///
/// Returns null only when there is genuinely nothing to go on, in which case
/// the map marks no pole at all rather than guessing at random.
PickedPole? pickPole(
  List<StopPole> poles, {
  String? gleis,
  String? line,
  String? towardsName,
  LatLng? stop,
  LatLng? nextStop,
}) {
  final byBay = poleForGleis(poles, gleis);
  if (byBay != null) return (pole: byBay, how: PoleMatch.bay);

  final byRoute = poleForRoute(poles, line: line, towardsName: towardsName);
  if (byRoute != null) return (pole: byRoute, how: PoleMatch.route);

  if (stop != null && nextStop != null) {
    final bySide = poleOnTravelSide(poles, stop: stop, nextStop: nextStop);
    if (bySide != null) return (pole: bySide, how: PoleMatch.side);
  }
  return null;
}

/// The pole where [line] departs towards [towardsName], or null.
///
/// A pole's directions read "310 → Oldenburg (Holstein), Markt"; the leg says
/// it is going to "Oldenburg (Holstein), Markt" or some prefix of it. Matching
/// is on the leading word(s) of the destination, because timetable and headsign
/// spell the same place differently often enough ("Kiel ZOB" vs "Kiel, ZOB").
/// Ambiguity is failure: if two poles both fit, we know nothing.
StopPole? poleForRoute(
  List<StopPole> poles, {
  String? line,
  String? towardsName,
}) {
  final wantedTo = _placeKey(towardsName);
  if (wantedTo == null) return null;
  final wantedLine = _normalize(line);
  final hits = <StopPole>[];
  for (final p in poles) {
    for (final d in p.directions) {
      final parts = d.split('→');
      final dLine = parts.length > 1 ? _normalize(parts.first) : null;
      final dTo = _placeKey(parts.last);
      if (dTo == null) continue;
      // A line we know about must agree; a pole that lists no line is judged
      // on the destination alone.
      if (wantedLine != null && dLine != null && dLine != wantedLine) continue;
      if (dTo == wantedTo || dTo.startsWith(wantedTo) ||
          wantedTo.startsWith(dTo)) {
        if (!hits.contains(p)) hits.add(p);
      }
    }
  }
  return hits.length == 1 ? hits.first : null;
}

/// Comparable form of a place name: lower case, no punctuation, town suffix
/// dropped ("Oldenburg (Holstein), Markt" → "oldenburgholstein").
String? _placeKey(String? s) {
  if (s == null) return null;
  final head = s.split(',').first;
  final t = head.toLowerCase().replaceAll(RegExp(r'[^a-z0-9äöüß]'), '');
  return t.isEmpty ? null : t;
}

/// The pole on the right-hand side of the ride's direction of travel.
///
/// Buses stop on the right in Germany, so of two poles facing each other the
/// one right of the vector [stop] → [nextStop] is where this bus calls. Poles
/// too close to that line (within [_sidewaysMinM] sideways) can't be told
/// apart and disqualify the answer, as does more than one pole on that side —
/// a bus station is not this question.
StopPole? poleOnTravelSide(
  List<StopPole> poles, {
  required LatLng stop,
  required LatLng nextStop,
}) {
  if (poles.length < 2) return poles.isEmpty ? null : poles.first;
  final cosLat = math.cos(stop.latitude * math.pi / 180.0);
  // Direction of travel as a plane vector (east, north) in metres.
  final tx = (nextStop.longitude - stop.longitude) * 111320.0 * cosLat;
  final ty = (nextStop.latitude - stop.latitude) * 111320.0;
  final len = math.sqrt(tx * tx + ty * ty);
  if (len < 30) return null; // next stop practically on top of this one

  final right = <StopPole>[];
  for (final p in poles) {
    final px = (p.latLng.longitude - stop.longitude) * 111320.0 * cosLat;
    final py = (p.latLng.latitude - stop.latitude) * 111320.0;
    // Signed sideways offset: negative = right of the direction of travel.
    final side = (tx * py - ty * px) / len;
    if (side < -_sidewaysMinM) right.add(p);
  }
  return right.length == 1 ? right.first : null;
}

/// A pole has to sit at least this far to the side of the route line before we
/// call it "the right-hand one" — under that the two sides aren't separable.
const double _sidewaysMinM = 4;
