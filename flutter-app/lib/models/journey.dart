import 'departure.dart';
import 'station.dart';

class JourneyResult {
  final List<Journey> journeys;
  final String? earlierRef;
  final String? laterRef;

  const JourneyResult({
    required this.journeys,
    this.earlierRef,
    this.laterRef,
  });

  factory JourneyResult.fromHafas(Map<String, dynamic> json) {
    final list = json['journeys'] as List<dynamic>? ?? [];
    return JourneyResult(
      journeys:
          list.whereType<Map<String, dynamic>>().map(Journey.fromHafas).toList(),
      earlierRef: json['earlierRef'] as String?,
      laterRef: json['laterRef'] as String?,
    );
  }
}

class Journey {
  final List<JourneyLeg> legs;
  final String? refreshToken;
  final JourneyPrice? price;

  /// Notes about the connection as a whole, e.g. "Der Zielhalt Berlin Hbf
  /// entfällt. Ausstieg in Berlin-Spandau möglich." Sometimes the only place
  /// that spells out what changed — the legs can carry nothing at all.
  final List<String> disruptions;

  /// When this connection does NOT run, in DB's own words (vendo
  /// `serviceDays[].irregular`) — e.g. "nicht 22. Aug bis 4. Sep 2026".
  ///
  /// About the connection's *pattern*, never about the date you searched: the
  /// day you're offered is always a day it runs (verified over 34 connections
  /// across two routes and three dates — the travel date never fell inside one
  /// of these ranges). So it's shown as information for planning or re-booking,
  /// not as a warning.
  ///
  /// Deliberately NOT the zuglauf's `fahrplan.tageOhneFahrt`, which reads like
  /// the same thing and isn't: every sampled run was bookable on a day inside
  /// its own "tageOhneFahrt" range (RE 10909 on 18 Jul says "16. bis 23. Jul").
  /// See #20, point 8.
  final String? serviceDaysNote;

  const Journey({
    required this.legs,
    this.refreshToken,
    this.price,
    this.disruptions = const [],
    this.serviceDaysNote,
  });

  factory Journey.fromHafas(Map<String, dynamic> json) {
    final legsJson = json['legs'] as List<dynamic>? ?? [];
    final priceJson = json['price'] as Map<String, dynamic>?;
    return Journey(
      legs: legsJson
          .whereType<Map<String, dynamic>>()
          .map(JourneyLeg.fromHafas)
          .toList(),
      refreshToken: json['refreshToken'] as String?,
      price: priceJson != null ? JourneyPrice.fromJson(priceJson) : null,
    );
  }

  Map<String, dynamic> toJson() => {
        'legs': legs.map((l) => l.toJson()).toList(),
        'refreshToken': refreshToken,
        'price': price?.toJson(),
        'disruptions': disruptions,
        'serviceDaysNote': serviceDaysNote,
      };

  factory Journey.fromJson(Map<String, dynamic> json) => Journey(
        legs: (json['legs'] as List<dynamic>? ?? [])
            .whereType<Map<String, dynamic>>()
            .map(JourneyLeg.fromJson)
            .toList(),
        refreshToken: json['refreshToken'] as String?,
        disruptions: (json['disruptions'] as List<dynamic>? ?? const [])
            .whereType<String>()
            .toList(),
        serviceDaysNote: json['serviceDaysNote'] as String?,
        price: json['price'] is Map<String, dynamic>
            ? JourneyPrice.fromJson(json['price'] as Map<String, dynamic>)
            : null,
      );

  Station? get origin => legs.firstOrNull?.origin;
  Station? get destination => legs.lastOrNull?.destination;
  DateTime? get departure => legs.firstOrNull?.departure;
  DateTime? get arrival => legs.lastOrNull?.arrival;
  DateTime? get plannedDeparture => legs.firstOrNull?.plannedDeparture;
  DateTime? get plannedArrival => legs.lastOrNull?.plannedArrival;

  int get transfers => legs.where((l) => !l.isWalking).length - 1;

  Duration? get duration {
    final dep = departure;
    final arr = arrival;
    if (dep == null || arr == null) return null;
    return arr.difference(dep);
  }

  String get durationString {
    final d = duration;
    if (d == null) return '';
    final hours = d.inHours;
    final minutes = d.inMinutes % 60;
    if (hours > 0) return '${hours}h ${minutes}min';
    return '${minutes}min';
  }

  bool get hasDelay => legs.any((l) =>
      (l.departureDelay != null && l.departureDelay! > 0) ||
      (l.arrivalDelay != null && l.arrivalDelay! > 0));

  /// At least one transit leg of this connection is fully cancelled — the
  /// connection as planned cannot be travelled.
  bool get hasCancelledLeg => legs.any((l) => !l.isWalking && l.cancelled);

  /// A leg runs but drops one of its intermediate stops (Teilausfall), without
  /// the whole leg being cancelled.
  bool get hasPartialCancellation =>
      !hasCancelledLeg &&
      legs.any((l) => !l.isWalking && l.partiallyCancelled);

  /// Whether the change into [leg] stays on one platform, as DB says
  /// (`weiterfahrtAmGleichenBahnsteig`, #20 point 6).
  ///
  /// Vendo models every transfer as a FUSSWEG leg and puts the flag there, so
  /// the answer sits on the walk *before* the train, not on the train. The
  /// fallback reads the train's own flag, for a source that pairs two trains
  /// without a walk between them.
  bool samePlatformTransferInto(JourneyLeg leg) {
    final i = legs.indexOf(leg);
    if (i <= 0) return false;
    final before = legs[i - 1];
    return before.isWalking
        ? before.samePlatformTransfer
        : leg.samePlatformTransfer;
  }
}

class JourneyLeg {
  final String? tripId;
  final Station origin;
  final Station destination;
  final DateTime? departure;
  final DateTime? plannedDeparture;
  final int? departureDelay;
  final String? departurePlatform;
  final String? plannedDeparturePlatform;
  final DateTime? arrival;
  final DateTime? plannedArrival;
  final int? arrivalDelay;
  final String? arrivalPlatform;
  final String? plannedArrivalPlatform;
  final TransitLine? line;
  final String? direction;
  final bool isWalking;
  final int? walkingDistance;

  /// How long DB reckons this walk actually takes (vendo `abschnittsDauer` on
  /// a FUSSWEG), when it says so — see [transferAvailable].
  final Duration? walkingDuration;

  /// The full window for this transfer (vendo `verfuegbareZeit`): from the
  /// previous train's arrival to the next one's departure. Equal to the gap we
  /// compute from timestamps, but it's DB's own number and it comes with
  /// [walkingDuration] — together they are "12 min Zeit, 7 min Weg" instead of
  /// a bare "12 min", which reads as if the whole window were slack.
  ///
  /// Only present where the walk crosses between two distinct stations
  /// (Köln Messe/Deutz → Köln Messe/Deutz Gl.11-12). For a change within one
  /// station DB sends neither, and `abschnittsDauer` is then just the window
  /// again — NOT a walk estimate, which is why [walkingDuration] is only read
  /// alongside this field.
  final Duration? transferAvailable;

  /// DB's own answer to "do I have to change platforms?"
  /// (`weiterfahrtAmGleichenBahnsteig`). True also for Gleis 4 → 5 on one
  /// island platform — you cross to the other side, no stairs, no lift. That
  /// can't be derived from the Gleis numbers: 4 → 5 may be one platform while
  /// 8 → 9 is two.
  final bool samePlatformTransfer;

  final bool cancelled;
  final List<LegStopover> stopovers;
  final OccupancyInfo? occupancy;

  /// Disruption notes for this leg — HIM messages (construction, broken
  /// elevators, …) and realtime notes ("Reparatur an der Strecke"), collected
  /// from the leg and its stops. Shown as a warning banner. Amenities and
  /// reservation hints are deliberately NOT included here.
  final List<String> disruptions;

  /// Where the train actually ends when it stops short of [destination]
  /// (vendo `ersatzAnkunftsHalt`, note typ NEUER_ENDHALT) — e.g. terminating
  /// at Berlin-Spandau while [destination] still reads Berlin Hbf.
  ///
  /// [destination]/[arrival] deliberately keep the *planned* values: the rider
  /// searched for Berlin Hbf and needs to see that it's the leg that changed,
  /// not their search. The UI shows both.
  final Station? replacementDestination;
  final DateTime? replacementArrival;
  final String? replacementArrivalPlatform;

  /// True when the train terminates before its planned destination.
  bool get endsEarly => replacementDestination != null;

  const JourneyLeg({
    this.tripId,
    required this.origin,
    required this.destination,
    this.departure,
    this.plannedDeparture,
    this.departureDelay,
    this.departurePlatform,
    this.plannedDeparturePlatform,
    this.arrival,
    this.plannedArrival,
    this.arrivalDelay,
    this.arrivalPlatform,
    this.plannedArrivalPlatform,
    this.line,
    this.direction,
    this.isWalking = false,
    this.walkingDistance,
    this.walkingDuration,
    this.transferAvailable,
    this.samePlatformTransfer = false,
    this.cancelled = false,
    this.stopovers = const [],
    this.occupancy,
    this.disruptions = const [],
    this.replacementDestination,
    this.replacementArrival,
    this.replacementArrivalPlatform,
  });

  /// Minutes of slack this transfer really leaves: the window minus the walk.
  /// Null unless DB gave both — never guessed, since "12 min" and "12 min of
  /// which 7 are walking" are different transfers.
  int? get transferBufferMinutes {
    final available = transferAvailable;
    final walk = walkingDuration;
    if (available == null || walk == null) return null;
    return (available - walk).inMinutes;
  }

  bool get hasDeparturePlatformChange =>
      departurePlatform != null &&
      plannedDeparturePlatform != null &&
      departurePlatform != plannedDeparturePlatform;

  bool get hasArrivalPlatformChange =>
      arrivalPlatform != null &&
      plannedArrivalPlatform != null &&
      arrivalPlatform != plannedArrivalPlatform;

  int get departureDelayMinutes =>
      departureDelay != null ? departureDelay! ~/ 60 : 0;
  int get arrivalDelayMinutes =>
      arrivalDelay != null ? arrivalDelay! ~/ 60 : 0;

  /// The leg runs but at least one of its intermediate stops is dropped
  /// ("Halt entfällt"), while the leg itself isn't fully cancelled.
  bool get partiallyCancelled =>
      !cancelled && stopovers.any((s) => s.cancelled);

  factory JourneyLeg.fromHafas(Map<String, dynamic> json) {
    final originJson = json['origin'] as Map<String, dynamic>? ?? {};
    final destJson = json['destination'] as Map<String, dynamic>? ?? {};
    final lineJson = json['line'] as Map<String, dynamic>?;
    final stopsJson = json['stopovers'] as List<dynamic>? ?? [];
    final loadJson = json['loadFactor'] as String?;

    return JourneyLeg(
      tripId: json['tripId'] as String?,
      origin: Station.fromHafas(originJson),
      destination: Station.fromHafas(destJson),
      departure: _parse(json['departure']),
      plannedDeparture: _parse(json['plannedDeparture']),
      departureDelay: json['departureDelay'] as int?,
      departurePlatform: json['departurePlatform'] as String?,
      plannedDeparturePlatform: json['plannedDeparturePlatform'] as String?,
      arrival: _parse(json['arrival']),
      plannedArrival: _parse(json['plannedArrival']),
      arrivalDelay: json['arrivalDelay'] as int?,
      arrivalPlatform: json['arrivalPlatform'] as String?,
      plannedArrivalPlatform: json['plannedArrivalPlatform'] as String?,
      line: lineJson != null ? TransitLine.fromHafas(lineJson) : null,
      direction: json['direction'] as String?,
      isWalking: json['walking'] as bool? ?? false,
      walkingDistance: json['distance'] as int?,
      cancelled: json['cancelled'] as bool? ?? false,
      stopovers: stopsJson
          .whereType<Map<String, dynamic>>()
          .map(LegStopover.fromHafas)
          .toList(),
      occupancy: loadJson != null
          ? OccupancyInfo(level: _parseLoadFactor(loadJson))
          : null,
    );
  }

  Map<String, dynamic> toJson() => {
        'tripId': tripId,
        'origin': origin.toJson(),
        'destination': destination.toJson(),
        'departure': departure?.toIso8601String(),
        'plannedDeparture': plannedDeparture?.toIso8601String(),
        'departureDelay': departureDelay,
        'departurePlatform': departurePlatform,
        'plannedDeparturePlatform': plannedDeparturePlatform,
        'arrival': arrival?.toIso8601String(),
        'plannedArrival': plannedArrival?.toIso8601String(),
        'arrivalDelay': arrivalDelay,
        'arrivalPlatform': arrivalPlatform,
        'plannedArrivalPlatform': plannedArrivalPlatform,
        'line': line?.toJson(),
        'direction': direction,
        'walking': isWalking,
        'distance': walkingDistance,
        'walkingSeconds': walkingDuration?.inSeconds,
        'transferAvailableSeconds': transferAvailable?.inSeconds,
        'samePlatformTransfer': samePlatformTransfer,
        'cancelled': cancelled,
        'stopovers': stopovers.map((s) => s.toJson()).toList(),
        'occupancy': occupancy?.level.name,
        'disruptions': disruptions,
        'replacementDestination': replacementDestination?.toJson(),
        'replacementArrival': replacementArrival?.toIso8601String(),
        'replacementArrivalPlatform': replacementArrivalPlatform,
      };

  factory JourneyLeg.fromJson(Map<String, dynamic> json) => JourneyLeg(
        tripId: json['tripId'] as String?,
        origin: Station.fromJson(json['origin'] as Map<String, dynamic>? ?? {}),
        destination:
            Station.fromJson(json['destination'] as Map<String, dynamic>? ?? {}),
        departure: _parse(json['departure']),
        plannedDeparture: _parse(json['plannedDeparture']),
        departureDelay: json['departureDelay'] as int?,
        departurePlatform: json['departurePlatform'] as String?,
        plannedDeparturePlatform: json['plannedDeparturePlatform'] as String?,
        arrival: _parse(json['arrival']),
        plannedArrival: _parse(json['plannedArrival']),
        arrivalDelay: json['arrivalDelay'] as int?,
        arrivalPlatform: json['arrivalPlatform'] as String?,
        plannedArrivalPlatform: json['plannedArrivalPlatform'] as String?,
        line: json['line'] is Map<String, dynamic>
            ? TransitLine.fromJson(json['line'] as Map<String, dynamic>)
            : null,
        direction: json['direction'] as String?,
        isWalking: json['walking'] as bool? ?? false,
        walkingDistance: json['distance'] as int?,
        walkingDuration: _seconds(json['walkingSeconds']),
        transferAvailable: _seconds(json['transferAvailableSeconds']),
        samePlatformTransfer: json['samePlatformTransfer'] as bool? ?? false,
        cancelled: json['cancelled'] as bool? ?? false,
        stopovers: (json['stopovers'] as List<dynamic>? ?? [])
            .whereType<Map<String, dynamic>>()
            .map(LegStopover.fromJson)
            .toList(),
        occupancy: json['occupancy'] is String
            ? OccupancyInfo(level: _levelByName(json['occupancy'] as String))
            : null,
        disruptions: (json['disruptions'] as List<dynamic>? ?? [])
            .whereType<String>()
            .toList(),
        replacementDestination:
            json['replacementDestination'] is Map<String, dynamic>
                ? Station.fromJson(
                    json['replacementDestination'] as Map<String, dynamic>)
                : null,
        replacementArrival: _parse(json['replacementArrival']),
        replacementArrivalPlatform:
            json['replacementArrivalPlatform'] as String?,
      );
}

class LegStopover {
  final Station stop;
  final DateTime? arrival;
  final DateTime? departure;
  final int? arrivalDelay;
  final int? departureDelay;

  /// This intermediate stop is dropped from the run (DB "Halt entfällt" /
  /// `ersatzhaltNotiz.typ == GECANCELT`). Boarding/alighting here is impossible.
  final bool cancelled;

  /// The train stops but won't let you on ("Hält nur zum Aussteigen") or off
  /// ("Hält nur zum Einsteigen") — vendo `serviceNotiz`, whose `key` carries
  /// the meaning (`…stop.entry.disabled` / `…stop.exit.disabled`). Without
  /// this such a stop looks exactly like any other, and someone planning to
  /// change trains there simply can't.
  final bool noBoarding;
  final bool noAlighting;

  /// DB's own wording for the above, ready to show.
  final String? serviceNote;

  const LegStopover({
    required this.stop,
    this.arrival,
    this.departure,
    this.arrivalDelay,
    this.departureDelay,
    this.cancelled = false,
    this.noBoarding = false,
    this.noAlighting = false,
    this.serviceNote,
  });

  factory LegStopover.fromHafas(Map<String, dynamic> json) {
    final stopJson = json['stop'] as Map<String, dynamic>? ?? {};
    return LegStopover(
      stop: Station.fromHafas(stopJson),
      arrival: _parse(json['arrival']),
      departure: _parse(json['departure']),
      arrivalDelay: json['arrivalDelay'] as int?,
      departureDelay: json['departureDelay'] as int?,
      cancelled: json['cancelled'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() => {
        'stop': stop.toJson(),
        'arrival': arrival?.toIso8601String(),
        'departure': departure?.toIso8601String(),
        'arrivalDelay': arrivalDelay,
        'departureDelay': departureDelay,
        'cancelled': cancelled,
        'noBoarding': noBoarding,
        'noAlighting': noAlighting,
        'serviceNote': serviceNote,
      };

  factory LegStopover.fromJson(Map<String, dynamic> json) => LegStopover(
        stop: Station.fromJson(json['stop'] as Map<String, dynamic>? ?? {}),
        arrival: _parse(json['arrival']),
        departure: _parse(json['departure']),
        arrivalDelay: json['arrivalDelay'] as int?,
        departureDelay: json['departureDelay'] as int?,
        cancelled: json['cancelled'] as bool? ?? false,
        noBoarding: json['noBoarding'] as bool? ?? false,
        noAlighting: json['noAlighting'] as bool? ?? false,
        serviceNote: json['serviceNote'] as String?,
      );
}

class JourneyPrice {
  final double amount;
  final String currency;

  const JourneyPrice({required this.amount, this.currency = 'EUR'});

  factory JourneyPrice.fromJson(Map<String, dynamic> json) {
    return JourneyPrice(
      amount: (json['amount'] as num?)?.toDouble() ?? 0,
      currency: json['currency'] as String? ?? 'EUR',
    );
  }

  Map<String, dynamic> toJson() => {'amount': amount, 'currency': currency};

  String get formatted => '${amount.toStringAsFixed(2)} €';
}

class OccupancyInfo {
  final OccupancyLevel level;

  const OccupancyInfo({required this.level});
}

enum OccupancyLevel {
  unknown,
  low,
  medium,
  high,
  veryHigh;

  String get label {
    switch (this) {
      case OccupancyLevel.unknown:
        return 'Keine Daten';
      case OccupancyLevel.low:
        return 'Gering';
      case OccupancyLevel.medium:
        return 'Mittel';
      case OccupancyLevel.high:
        return 'Hoch';
      case OccupancyLevel.veryHigh:
        return 'Sehr hoch';
    }
  }

  /// Full sentence as DB phrases it, e.g. "Geringe Auslastung erwartet".
  String get expectedLabel {
    switch (this) {
      case OccupancyLevel.unknown:
        return '';
      case OccupancyLevel.low:
        return 'Geringe Auslastung erwartet';
      case OccupancyLevel.medium:
        return 'Mittlere Auslastung erwartet';
      case OccupancyLevel.high:
        return 'Hohe Auslastung erwartet';
      case OccupancyLevel.veryHigh:
        return 'Sehr hohe Auslastung erwartet';
    }
  }
}

/// Round-trips [OccupancyLevel] through its enum name.
OccupancyLevel _levelByName(String name) => OccupancyLevel.values.firstWhere(
      (l) => l.name == name,
      orElse: () => OccupancyLevel.unknown,
    );

OccupancyLevel _parseLoadFactor(String factor) {
  switch (factor) {
    case 'low-to-medium':
      return OccupancyLevel.low;
    case 'high':
      return OccupancyLevel.high;
    case 'very-high':
      return OccupancyLevel.veryHigh;
    case 'exceptionally-high':
      return OccupancyLevel.veryHigh;
    default:
      return OccupancyLevel.unknown;
  }
}

DateTime? _parse(dynamic value) {
  if (value is String) return DateTime.tryParse(value);
  return null;
}

Duration? _seconds(dynamic value) =>
    value is num ? Duration(seconds: value.toInt()) : null;
