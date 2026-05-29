class CoachSequence {
  final String journeyId;
  final String departurePlatform;
  final String? scheduledPlatform;
  final String sequenceStatus;
  final Platform platform;
  final List<CoachGroup> groups;

  const CoachSequence({
    required this.journeyId,
    required this.departurePlatform,
    this.scheduledPlatform,
    required this.sequenceStatus,
    required this.platform,
    required this.groups,
  });

  factory CoachSequence.fromJson(Map<String, dynamic> json) {
    final platformJson = json['platform'] as Map<String, dynamic>? ?? {};
    final groupsJson = json['groups'] as List<dynamic>? ?? [];

    return CoachSequence(
      journeyId: json['journeyID'] as String? ?? '',
      departurePlatform: json['departurePlatform'] as String? ?? '',
      scheduledPlatform: json['departurePlatformSchedule'] as String?,
      sequenceStatus: json['sequenceStatus'] as String? ?? '',
      platform: Platform.fromJson(platformJson),
      groups: groupsJson
          .whereType<Map<String, dynamic>>()
          .map(CoachGroup.fromJson)
          .toList(),
    );
  }

  List<Coach> get allCoaches =>
      groups.expand((g) => g.coaches).toList()
        ..sort((a, b) =>
            (a.platformPosition?.start ?? 0)
                .compareTo(b.platformPosition?.start ?? 0));

  bool get hasPlatformChange =>
      scheduledPlatform != null &&
      departurePlatform != scheduledPlatform;

  /// On a splitting train (a Flügelzug, ≥2 groups), the portion bound for
  /// [destinationName] — matched on a normalised station name. Null when the
  /// train doesn't split or no portion matches.
  CoachGroup? portionTo(String destinationName) {
    if (groups.length < 2) return null;
    final nb = _normStation(destinationName);
    if (nb.isEmpty) return null;
    for (final g in groups) {
      final na = _normStation(g.transport.destination ?? '');
      if (na.isNotEmpty && (na == nb || na.contains(nb) || nb.contains(na))) {
        return g;
      }
    }
    return null;
  }
}

String _normStation(String s) => s
    .toLowerCase()
    .replaceAll('hauptbahnhof', 'hbf')
    .replaceAll(RegExp(r'[^a-zäöüß0-9]'), '');

class Platform {
  final String name;
  final double start;
  final double end;
  final List<PlatformSector> sectors;

  const Platform({
    required this.name,
    required this.start,
    required this.end,
    required this.sectors,
  });

  factory Platform.fromJson(Map<String, dynamic> json) {
    final sectorsJson = json['sectors'] as List<dynamic>? ?? [];
    return Platform(
      name: json['name'] as String? ?? '',
      start: (json['start'] as num?)?.toDouble() ?? 0,
      end: (json['end'] as num?)?.toDouble() ?? 0,
      sectors: sectorsJson
          .whereType<Map<String, dynamic>>()
          .map(PlatformSector.fromJson)
          .toList(),
    );
  }

  double get length => end - start;
}

class PlatformSector {
  final String name;
  final double start;
  final double end;

  const PlatformSector({
    required this.name,
    required this.start,
    required this.end,
  });

  factory PlatformSector.fromJson(Map<String, dynamic> json) {
    return PlatformSector(
      name: json['name'] as String? ?? '',
      start: (json['start'] as num?)?.toDouble() ?? 0,
      end: (json['end'] as num?)?.toDouble() ?? 0,
    );
  }
}

class CoachGroup {
  final String name;
  final CoachTransport transport;
  final List<Coach> coaches;

  const CoachGroup({
    required this.name,
    required this.transport,
    required this.coaches,
  });

  factory CoachGroup.fromJson(Map<String, dynamic> json) {
    final transportJson = json['transport'] as Map<String, dynamic>? ?? {};
    final vehiclesJson = json['vehicles'] as List<dynamic>? ?? [];
    return CoachGroup(
      name: json['name'] as String? ?? '',
      transport: CoachTransport.fromJson(transportJson),
      coaches: vehiclesJson
          .whereType<Map<String, dynamic>>()
          .map(Coach.fromJson)
          .toList(),
    );
  }

  /// Distinct platform sections this portion occupies, in letter order
  /// (e.g. ["I"] or ["G", "H", "I"]).
  List<String> get sectors {
    final s = <String>{};
    for (final c in coaches) {
      final sec = c.platformPosition?.sector;
      if (sec != null && sec.trim().isNotEmpty) s.add(sec.trim());
    }
    return s.toList()..sort();
  }

  /// The portion's section span as (first, last), e.g. ("G", "I"). Null when no
  /// coach carries a section.
  ({String start, String end})? get sectorRange {
    final s = sectors;
    if (s.isEmpty) return null;
    return (start: s.first, end: s.last);
  }
}

class CoachTransport {
  final String category; // ICE, IC, etc.
  final int number;
  final String type; // HIGH_SPEED_TRAIN, etc.
  final String? destination;

  const CoachTransport({
    required this.category,
    required this.number,
    required this.type,
    this.destination,
  });

  factory CoachTransport.fromJson(Map<String, dynamic> json) {
    final dest = json['destination'] as Map<String, dynamic>?;
    return CoachTransport(
      category: json['category'] as String? ?? '',
      number: json['number'] as int? ?? 0,
      type: json['type'] as String? ?? '',
      destination: dest?['name'] as String?,
    );
  }
}

class Coach {
  final int wagonNumber;
  final String vehicleId;
  final String orientation; // FORWARDS, BACKWARDS
  final String status; // OPEN, CLOSED
  final CoachType type;
  final CoachPosition? platformPosition;
  final List<CoachAmenity> amenities;

  const Coach({
    required this.wagonNumber,
    required this.vehicleId,
    required this.orientation,
    required this.status,
    required this.type,
    this.platformPosition,
    required this.amenities,
  });

  factory Coach.fromJson(Map<String, dynamic> json) {
    final typeJson = json['type'] as Map<String, dynamic>? ?? {};
    final posJson = json['platformPosition'] as Map<String, dynamic>?;
    final amenitiesJson = json['amenities'] as List<dynamic>? ?? [];

    return Coach(
      wagonNumber: json['wagonIdentificationNumber'] as int? ?? 0,
      vehicleId: json['vehicleID'] as String? ?? '',
      orientation: json['orientation'] as String? ?? '',
      status: json['status'] as String? ?? 'OPEN',
      type: CoachType.fromJson(typeJson),
      platformPosition:
          posJson != null ? CoachPosition.fromJson(posJson) : null,
      amenities: amenitiesJson
          .whereType<Map<String, dynamic>>()
          .map(CoachAmenity.fromJson)
          .toList(),
    );
  }

  bool get isOpen => status == 'OPEN';
  bool get isFirstClass => type.hasFirstClass && !type.hasEconomyClass;
  bool get isSecondClass => type.hasEconomyClass && !type.hasFirstClass;
  bool get isMixed => type.hasFirstClass && type.hasEconomyClass;
  bool get isRestaurant => type.category.contains('DINING') ||
      type.category.contains('RESTAURANT');
  bool get isLocomotive => type.category == 'POWERCAR' ||
      type.category == 'LOCOMOTIVE';

  bool hasAmenity(String amenityType) =>
      amenities.any((a) => a.type == amenityType);

  bool get hasBikeSpace => hasAmenity('BIKE_SPACE');
  bool get hasQuietZone => hasAmenity('ZONE_QUIET');
  bool get hasFamilyZone => hasAmenity('ZONE_FAMILY');
  bool get hasWheelchairSpace => hasAmenity('WHEELCHAIR_SPACE');
}

class CoachType {
  final String category;
  final String constructionType;
  final bool hasFirstClass;
  final bool hasEconomyClass;

  const CoachType({
    required this.category,
    required this.constructionType,
    required this.hasFirstClass,
    required this.hasEconomyClass,
  });

  factory CoachType.fromJson(Map<String, dynamic> json) {
    return CoachType(
      category: json['category'] as String? ?? '',
      constructionType: json['constructionType'] as String? ?? '',
      hasFirstClass: json['hasFirstClass'] as bool? ?? false,
      hasEconomyClass: json['hasEconomyClass'] as bool? ?? false,
    );
  }
}

class CoachPosition {
  final double start;
  final double end;
  final String sector;

  const CoachPosition({
    required this.start,
    required this.end,
    required this.sector,
  });

  factory CoachPosition.fromJson(Map<String, dynamic> json) {
    return CoachPosition(
      start: (json['start'] as num?)?.toDouble() ?? 0,
      end: (json['end'] as num?)?.toDouble() ?? 0,
      sector: json['sector'] as String? ?? '',
    );
  }

  double get length => end - start;
  double get center => (start + end) / 2;
}

class CoachAmenity {
  final String type;
  final int amount;
  final String status;

  const CoachAmenity({
    required this.type,
    required this.amount,
    required this.status,
  });

  factory CoachAmenity.fromJson(Map<String, dynamic> json) {
    return CoachAmenity(
      type: json['type'] as String? ?? '',
      amount: json['amount'] as int? ?? 0,
      status: json['status'] as String? ?? 'UNDEFINED',
    );
  }

  bool get isAvailable => status == 'AVAILABLE';
}
