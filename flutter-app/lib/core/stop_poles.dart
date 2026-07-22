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
