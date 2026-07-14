import 'dart:math' as math;

import 'departure.dart';
import 'journey.dart' show JourneyLeg, OccupancyLevel;
import 'station.dart';

/// A train-wide attribute from the bahn.de `fahrt` `zugattribute` list, e.g.
/// `{kategorie: FAHRRADMITNAHME, key: FB, value: "Fahrradmitnahme begrenzt
/// möglich"}`. [kategorie] groups them (FAHRRADMITNAHME, BARRIEREFREI,
/// INFORMATION); [key] is the stable short code (FB, RO, EH, KL, …).
class TripAttribute {
  final String kategorie;
  final String key;
  final String value;

  const TripAttribute({
    required this.kategorie,
    required this.key,
    required this.value,
  });

  factory TripAttribute.fromDbWeb(Map<String, dynamic> json) => TripAttribute(
        kategorie: json['kategorie'] as String? ?? '',
        key: json['key'] as String? ?? '',
        value: json['value'] as String? ?? '',
      );
}

class Trip {
  final String id;
  final TransitLine line;
  final String direction;
  final Station origin;
  final Station destination;
  final List<Stopover> stopovers;
  final List<Map<String, double>>? polyline; // lat/lng points

  /// Train-wide attributes ("Fahrradmitnahme begrenzt möglich", "Rollstuhl-
  /// stellplatz", "Klimaanlage", …) from the bahn.de `fahrt` `zugattribute`.
  /// Belongs to the whole ride, regardless of whether a Wagenreihung exists —
  /// so even an RE without coach data still carries its bike/accessibility info.
  final List<TripAttribute> attributes;

  /// Disruption texts for the whole run — HIM messages (construction, closed
  /// track) and realtime notes ("Umleitung", "Verspätung aus vorheriger
  /// Fahrt"). Distinct from [attributes], which are amenities. Mirrors
  /// JourneyLeg.disruptions, which the journey search already collected while
  /// the train run threw them away (#17).
  final List<String> disruptions;

  const Trip({
    required this.id,
    required this.line,
    required this.direction,
    required this.origin,
    required this.destination,
    required this.stopovers,
    this.polyline,
    this.attributes = const [],
    this.disruptions = const [],
  });

  /// The run deviates from its timetabled route. Two independent signals:
  /// DB says so in a note, or the run picked up stops that aren't in the plan.
  ///
  /// Text matching is the only option — realtime notes carry no `typ`, just
  /// `text` (verified against live responses), which is also how _parseLeg
  /// detects a cancellation.
  bool get isRerouted =>
      stopovers.any((s) => s.additional) ||
      disruptions.any((d) {
        final t = d.toLowerCase();
        return t.contains('umleitung') ||
            t.contains('umgeleitet') ||
            t.contains('geänderte') && t.contains('laufweg') ||
            t.contains('änderung') && t.contains('laufweg');
      });

  /// Stops DB added to this run that the timetable doesn't have.
  List<Stopover> get additionalStops =>
      stopovers.where((s) => s.additional).toList();

  /// Timetabled stops this run drops ("Halt entfällt").
  List<Stopover> get cancelledStops =>
      stopovers.where((s) => s.cancelled).toList();

  /// Build a Trip from the data the journey search already returned for a leg.
  ///
  /// The stand-in for when `GET /mob/zuglauf/{id}` is unavailable (rate-limit,
  /// non-DB operator, offline). The journey response already carries this
  /// leg's stop list, so falling back to a train-number-only card threw away
  /// stops we were holding in memory (#14).
  ///
  /// Degraded on purpose: LegStopover has no planned-vs-actual split, no
  /// platform and no occupancy, and there's no polyline — so the timeline
  /// renders without platforms, load, or a map. Returns null when the leg
  /// carries no stops (nothing to show) or isn't a train.
  static Trip? fromLeg(JourneyLeg leg) {
    if (leg.isWalking || leg.stopovers.isEmpty || leg.line == null) return null;
    return Trip(
      id: leg.tripId ?? '',
      line: leg.line!,
      direction: leg.direction ?? leg.destination.name,
      origin: leg.origin,
      destination: leg.destination,
      stopovers: [
        for (final s in leg.stopovers)
          Stopover(
            stop: s.stop,
            // The leg's times are already realtime-resolved; without a planned
            // counterpart the timeline shows them as-is rather than inventing
            // a delay of zero.
            arrival: s.arrival,
            departure: s.departure,
            arrivalDelay: s.arrivalDelay,
            departureDelay: s.departureDelay,
            cancelled: s.cancelled,
          ),
      ],
    );
  }

  Trip copyWith({List<Map<String, double>>? polyline, TransitLine? line}) {
    return Trip(
      id: id,
      line: line ?? this.line,
      direction: direction,
      origin: origin,
      destination: destination,
      stopovers: stopovers,
      polyline: polyline ?? this.polyline,
      attributes: attributes,
    );
  }

  /// Stable signature of the *physical route* (ordered stop ids), independent
  /// of the date-bearing trip id. Used to cache the track geometry across days.
  String get routeKey {
    final ids = stopovers
        .map((s) => s.stop.id.isNotEmpty ? s.stop.id : s.stop.name)
        .where((s) => s.isNotEmpty)
        .toList();
    return ids.join('>');
  }

  factory Trip.fromHafas(Map<String, dynamic> json) {
    final lineJson = json['line'] as Map<String, dynamic>? ?? {};
    final originJson = json['origin'] as Map<String, dynamic>? ?? {};
    final destJson = json['destination'] as Map<String, dynamic>? ?? {};
    final stopsJson = json['stopovers'] as List<dynamic>? ?? [];
    final polyJson = json['polyline'] as Map<String, dynamic>?;

    List<Map<String, double>>? polyline;
    if (polyJson != null) {
      final features = polyJson['features'] as List<dynamic>? ?? [];
      polyline = features
          .whereType<Map<String, dynamic>>()
          .where((f) => f['geometry'] != null)
          .map((f) {
        final coords = (f['geometry'] as Map<String, dynamic>)['coordinates'];
        if (coords is List && coords.length >= 2) {
          return {
            'lat': (coords[1] as num).toDouble(),
            'lng': (coords[0] as num).toDouble(),
          };
        }
        return <String, double>{};
      }).where((m) => m.isNotEmpty).toList();
    }

    return Trip(
      id: json['id'] as String? ?? '',
      line: TransitLine.fromHafas(lineJson),
      direction: json['direction'] as String? ?? '',
      origin: Station.fromHafas(originJson),
      destination: Station.fromHafas(destJson),
      stopovers: stopsJson
          .whereType<Map<String, dynamic>>()
          .map(Stopover.fromHafas)
          .toList(),
      polyline: polyline,
    );
  }

  /// Representative 2nd-class occupancy for the whole run: the worst level
  /// reported across all stops (DB reports it per segment). [OccupancyLevel
  /// .unknown] when no stop carries data — the banner then hides itself.
  OccupancyLevel get occupancy {
    var worst = OccupancyLevel.unknown;
    for (final s in stopovers) {
      if (s.occupancy.index > worst.index) worst = s.occupancy;
    }
    return worst;
  }

  /// Find the current/next stop based on time
  Stopover? get currentStop {
    final now = DateTime.now();
    for (final stop in stopovers) {
      final dep = stop.departure ?? stop.arrival;
      if (dep != null && dep.isAfter(now)) return stop;
    }
    return stopovers.lastOrNull;
  }

  /// Estimated current position between stops
  CurrentPosition? get estimatedPosition {
    final now = DateTime.now();
    for (int i = 0; i < stopovers.length - 1; i++) {
      final current = stopovers[i];
      final next = stopovers[i + 1];
      final depTime = current.departure;
      final arrTime = next.arrival;

      if (depTime != null && arrTime != null) {
        if (now.isAfter(depTime) && now.isBefore(arrTime)) {
          final total = arrTime.difference(depTime).inSeconds;
          final elapsed = now.difference(depTime).inSeconds;
          final progress = total > 0 ? elapsed / total : 0.0;

          if (current.stop.hasLocation && next.stop.hasLocation) {
            // Straight chord between the two stops — the naive estimate. This
            // cuts across the landscape, so the marker floats off the rails.
            var lat = current.stop.latitude! +
                (next.stop.latitude! - current.stop.latitude!) * progress;
            var lng = current.stop.longitude! +
                (next.stop.longitude! - current.stop.longitude!) * progress;

            // Once the real DB track geometry is loaded, snap onto it: walk the
            // polyline between the two stops at the same time-progress so the
            // train sits where it would actually be on the rails.
            final snapped = _snapToTrack(
              fromLat: current.stop.latitude!,
              fromLng: current.stop.longitude!,
              toLat: next.stop.latitude!,
              toLng: next.stop.longitude!,
              progress: progress,
            );
            if (snapped != null) {
              lat = snapped[0];
              lng = snapped[1];
            }

            return CurrentPosition(
              latitude: lat,
              longitude: lng,
              fromStop: current,
              toStop: next,
              progress: progress,
            );
          }
        }
      }
    }
    return null;
  }

  /// Snaps a time-progress between two stops onto the real track [polyline].
  ///
  /// Finds the polyline vertices nearest the two stops, then walks the track
  /// between them by [progress] of the cumulative *track* distance (not the
  /// straight chord). Returns `[lat, lng]`, or `null` when there is no usable
  /// geometry so the caller keeps the straight-line fallback.
  List<double>? _snapToTrack({
    required double fromLat,
    required double fromLng,
    required double toLat,
    required double toLng,
    required double progress,
  }) {
    final poly = polyline;
    if (poly == null || poly.length < 2) return null;

    final i0 = _nearestIndex(poly, fromLat, fromLng);
    final i1 = _nearestIndex(poly, toLat, toLng);
    if (i0 == i1) return null;

    final lo = i0 < i1 ? i0 : i1;
    final hi = i0 < i1 ? i1 : i0;

    // Cumulative distance along the track slice between the two stops.
    final seg = <double>[0];
    var total = 0.0;
    for (var i = lo; i < hi; i++) {
      total += _dist(
          poly[i]['lat']!, poly[i]['lng']!, poly[i + 1]['lat']!, poly[i + 1]['lng']!);
      seg.add(total);
    }
    if (total <= 0) return null;

    // Progress runs from→to; flip it when the track is indexed to→from.
    final p = i0 <= i1 ? progress : 1 - progress;
    final target = (p.clamp(0.0, 1.0)) * total;

    for (var i = 0; i < seg.length - 1; i++) {
      if (target <= seg[i + 1]) {
        final segLen = seg[i + 1] - seg[i];
        final t = segLen > 0 ? (target - seg[i]) / segLen : 0.0;
        final a = poly[lo + i];
        final b = poly[lo + i + 1];
        return [
          a['lat']! + (b['lat']! - a['lat']!) * t,
          a['lng']! + (b['lng']! - a['lng']!) * t,
        ];
      }
    }
    final last = poly[hi];
    return [last['lat']!, last['lng']!];
  }

  static int _nearestIndex(
      List<Map<String, double>> poly, double lat, double lng) {
    var best = 0;
    var bestD = double.infinity;
    for (var i = 0; i < poly.length; i++) {
      final d = _dist(lat, lng, poly[i]['lat']!, poly[i]['lng']!);
      if (d < bestD) {
        bestD = d;
        best = i;
      }
    }
    return best;
  }

  /// Cheap squared equirectangular distance — fine for nearest-point / segment
  /// comparisons over a single trip's extent (no sqrt, no earth radius needed).
  static double _dist(double aLat, double aLng, double bLat, double bLng) {
    final mLat = (aLat + bLat) * 0.5 * (math.pi / 180);
    final dLat = bLat - aLat;
    final dLng = (bLng - aLng) * math.cos(mLat);
    return dLat * dLat + dLng * dLng;
  }
}

class Stopover {
  final Station stop;
  final DateTime? arrival;
  final DateTime? plannedArrival;
  final int? arrivalDelay; // seconds
  final DateTime? departure;
  final DateTime? plannedDeparture;
  final int? departureDelay; // seconds
  final String? arrivalPlatform;
  final String? plannedArrivalPlatform;
  final String? departurePlatform;
  final String? plannedDeparturePlatform;
  final bool cancelled;

  /// An extra stop this run makes that isn't in the timetable (vendo
  /// `istZusatzhalt`). Usually the visible symptom of a diversion (#17).
  final bool additional;

  /// 2nd-class occupancy expected at this stop (DB `auslastungsmeldungen`).
  final OccupancyLevel occupancy;

  const Stopover({
    required this.stop,
    this.arrival,
    this.plannedArrival,
    this.arrivalDelay,
    this.departure,
    this.plannedDeparture,
    this.departureDelay,
    this.arrivalPlatform,
    this.plannedArrivalPlatform,
    this.departurePlatform,
    this.plannedDeparturePlatform,
    this.cancelled = false,
    this.additional = false,
    this.occupancy = OccupancyLevel.unknown,
  });

  bool get hasArrivalPlatformChange =>
      arrivalPlatform != null &&
      plannedArrivalPlatform != null &&
      arrivalPlatform != plannedArrivalPlatform;

  bool get hasDeparturePlatformChange =>
      departurePlatform != null &&
      plannedDeparturePlatform != null &&
      departurePlatform != plannedDeparturePlatform;

  /// First stop of the run: it has a departure but no arrival → an Einstieg.
  bool get isOrigin =>
      (departure != null || plannedDeparture != null) &&
      arrival == null &&
      plannedArrival == null;

  /// Last stop of the run: it has an arrival but no departure → an Ausstieg.
  bool get isTerminus =>
      (arrival != null || plannedArrival != null) &&
      departure == null &&
      plannedDeparture == null;

  String? get platform => departurePlatform ?? arrivalPlatform;
  String? get plannedPlatform =>
      plannedDeparturePlatform ?? plannedArrivalPlatform;

  bool get hasPlatformChange =>
      hasArrivalPlatformChange || hasDeparturePlatformChange;

  int get delayMinutes {
    final d = departureDelay ?? arrivalDelay;
    return d != null ? d ~/ 60 : 0;
  }

  /// Whether this stop is in the past
  bool get isPast {
    final dep = departure ?? arrival;
    return dep != null && dep.isBefore(DateTime.now());
  }

  factory Stopover.fromHafas(Map<String, dynamic> json) {
    final stopJson = json['stop'] as Map<String, dynamic>? ?? {};
    return Stopover(
      stop: Station.fromHafas(stopJson),
      arrival: _parse(json['arrival']),
      plannedArrival: _parse(json['plannedArrival']),
      arrivalDelay: json['arrivalDelay'] as int?,
      departure: _parse(json['departure']),
      plannedDeparture: _parse(json['plannedDeparture']),
      departureDelay: json['departureDelay'] as int?,
      arrivalPlatform: json['arrivalPlatform'] as String?,
      plannedArrivalPlatform: json['plannedArrivalPlatform'] as String?,
      departurePlatform: json['departurePlatform'] as String?,
      plannedDeparturePlatform: json['plannedDeparturePlatform'] as String?,
      cancelled: json['cancelled'] as bool? ?? false,
      occupancy: _loadFactorToLevel(json['loadFactor'] as String?),
    );
  }
}

/// HAFAS `loadFactor` strings → our [OccupancyLevel].
OccupancyLevel _loadFactorToLevel(String? f) {
  switch (f) {
    case 'low-to-medium':
      return OccupancyLevel.low;
    case 'high':
      return OccupancyLevel.high;
    case 'very-high':
    case 'exceptionally-high':
      return OccupancyLevel.veryHigh;
    default:
      return OccupancyLevel.unknown;
  }
}

class CurrentPosition {
  final double latitude;
  final double longitude;
  final Stopover fromStop;
  final Stopover toStop;
  final double progress; // 0.0 to 1.0

  const CurrentPosition({
    required this.latitude,
    required this.longitude,
    required this.fromStop,
    required this.toStop,
    required this.progress,
  });
}

DateTime? _parse(dynamic value) {
  if (value is String) return DateTime.tryParse(value);
  return null;
}
