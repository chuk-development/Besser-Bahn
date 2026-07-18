import '../models/journey.dart';
import '../models/station.dart';
import '../models/trip.dart';

/// German short weekday names (Mon=1 … Sun=7), as DB writes them ("Fr.").
const _weekdayDe = ['Mo.', 'Di.', 'Mi.', 'Do.', 'Fr.', 'Sa.', 'So.'];

/// Stopover in [trip] for [station] — match by id, fall back to name. Mirrors
/// the connection detail's matcher so a shared journey reads the SAME realtime
/// stop the detail screen shows.
Stopover? _stopFor(Trip trip, Station station) {
  if (station.id.isNotEmpty) {
    for (final so in trip.stopovers) {
      if (so.stop.id == station.id) return so;
    }
  }
  for (final so in trip.stopovers) {
    if (station.name.isNotEmpty && so.stop.name == station.name) return so;
  }
  return null;
}

/// Realtime departure platform for [leg], preferring the freshly-fetched [live]
/// trip's stop (which carries `ezGleis`) over the leg's search-time value — so a
/// Gleiswechsel announced after the search still shows in the share (#50).
String? _livePlatform(JourneyLeg leg, Map<String, Trip>? live,
    {required bool arrival}) {
  final id = leg.tripId;
  final trip = (id != null && live != null) ? live[id] : null;
  if (trip != null) {
    final so = _stopFor(trip, arrival ? leg.destination : leg.origin);
    final p = arrival ? so?.arrivalPlatform : so?.departurePlatform;
    if (p != null) return p;
  }
  return arrival ? leg.arrivalPlatform : leg.departurePlatform;
}

DateTime? _liveTime(JourneyLeg leg, Map<String, Trip>? live,
    {required bool arrival}) {
  final id = leg.tripId;
  final trip = (id != null && live != null) ? live[id] : null;
  if (trip != null) {
    final so = _stopFor(trip, arrival ? leg.destination : leg.origin);
    final t = arrival ? (so?.arrival ?? so?.plannedArrival)
        : (so?.departure ?? so?.plannedDeparture);
    if (t != null) return t;
  }
  return arrival
      ? (leg.arrival ?? leg.plannedArrival)
      : (leg.departure ?? leg.plannedDeparture);
}

String _hhmm(DateTime? t) {
  if (t == null) return '';
  final l = t.toLocal();
  return '${l.hour.toString().padLeft(2, '0')}:'
      '${l.minute.toString().padLeft(2, '0')}';
}

/// Train label as the DB Navigator app prints it. DB only parenthesises the
/// train number when the line itself is numbered ("RE7 (11283)", "S1 (…)");
/// for category-only services the number is appended with a space ("ICE 705").
String _lineLabel(JourneyLeg leg) {
  final name = leg.line?.name.trim() ?? '';
  final nr = leg.line?.fahrtNr.trim() ?? '';
  if (name.isEmpty) return leg.line?.displayName ?? 'Zug';
  if (nr.isEmpty || name.contains(nr)) return name;
  // Line carries its own number (RE7, RB33, S1) → "name (nr)"; pure category
  // (ICE, IC, EC) → "name nr".
  return name.contains(RegExp(r'\d')) ? '$name ($nr)' : '$name $nr';
}

/// Rich "Reise teilen" text mirroring the official DB Navigator share: route,
/// date, each train (label · direction · Ab/An with platform), then the bahn.de
/// vbid deep link. Example:
///
///   Kiel Hbf → Berlin Hbf
///   Fr. 29.05.2026
///
///   RE7 (11283)
///   Nach Neumünster
///   Ab 19:05 Kiel Hbf, Gleis 4
///   An 20:22 Hamburg Hbf, Gleis 7G-I
///
///   ICE 705
///   …
///
///   Verbindung ansehen: https://www.bahn.de/buchung/start?vbid=…
/// [live] optionally maps `leg.tripId` → a freshly-fetched [Trip]; when given,
/// each leg's platform and time are read from it (realtime `ezGleis`), so the
/// share reflects a Gleiswechsel/delay the search snapshot didn't have (#50).
String journeyShareText(Journey journey, String link,
    {Map<String, Trip>? live}) {
  final o = journey.origin?.name ?? '';
  final d = journey.destination?.name ?? '';
  final dep = (journey.plannedDeparture ?? journey.departure)?.toLocal();

  final b = StringBuffer()..writeln('$o → $d');
  if (dep != null) {
    b.writeln('${_weekdayDe[dep.weekday - 1]} '
        '${dep.day.toString().padLeft(2, '0')}.'
        '${dep.month.toString().padLeft(2, '0')}.${dep.year}');
  }

  for (final leg in journey.legs.where((l) => !l.isWalking)) {
    b.writeln();
    b.writeln(_lineLabel(leg));
    final dir = leg.direction?.trim();
    if (dir != null && dir.isNotEmpty) b.writeln('Nach $dir');
    final depPlat = _livePlatform(leg, live, arrival: false);
    final arrPlat = _livePlatform(leg, live, arrival: true);
    final abG = depPlat != null ? ', Gleis $depPlat' : '';
    final anG = arrPlat != null ? ', Gleis $arrPlat' : '';
    b.writeln('Ab ${_hhmm(_liveTime(leg, live, arrival: false))} '
        '${leg.origin.name}$abG');
    b.writeln('An ${_hhmm(_liveTime(leg, live, arrival: true))} '
        '${leg.destination.name}$anG');
  }

  b..writeln()..write('Verbindung ansehen: $link');
  return b.toString();
}

/// Arrival-focused "ETA für Abholer" message: where to, when you arrive (with
/// platform + delay) and a live link to follow the train. Short and skimmable —
/// meant for the person picking you up, not a full itinerary.
///
///   🚆 Ich komme nach Berlin Hbf
///   Ankunft ~20:22, Gleis 7 (ICE 705)
///   +6 Min später als geplant
///   Live verfolgen: https://www.bahn.de/buchung/start?vbid=…
String etaShareText(Journey journey, String link, {Map<String, Trip>? live}) {
  final d = journey.destination?.name ?? 'Ziel';
  final transit = journey.legs.where((l) => !l.isWalking).toList();
  final last = transit.isEmpty ? null : transit.last;
  final arr = last == null ? null : _liveTime(last, live, arrival: true);
  final plat = last == null ? null : _livePlatform(last, live, arrival: true);
  final line = last?.line?.displayName;
  final delay = last?.arrivalDelayMinutes ?? 0;

  final b = StringBuffer()..writeln('🚆 Ich komme nach $d');
  if (arr != null) {
    b.writeln('Ankunft ~${_hhmm(arr)}'
        '${plat != null ? ', Gleis $plat' : ''}'
        '${line != null ? ' ($line)' : ''}');
  }
  if (delay > 0) b.writeln('+$delay Min später als geplant');
  b.write('Live verfolgen: $link');
  return b.toString();
}
