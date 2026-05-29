// Träwelling (traewelling.de) API models.
//
// Field shapes match the upstream Laravel resources verbatim
// (UserResource, StatusResource, TransportResource, StopoverResource,
// DepartureResource, TripResource, StationResource). Parsing is deliberately
// tolerant — every field is nullable-safe — because the API marks several
// fields deprecated/changing and rolls them over on fixed dates.

int? _int(dynamic v) => v is num ? v.toInt() : (v is String ? int.tryParse(v) : null);
double? _dbl(dynamic v) =>
    v is num ? v.toDouble() : (v is String ? double.tryParse(v) : null);
DateTime? _dt(dynamic v) => v is String ? DateTime.tryParse(v) : null;

/// A Träwelling user. Covers both the full `UserResource` and the trimmed
/// `LightUserResource` embedded in statuses — extra fields are just null.
class TrwlUser {
  final int id;
  final String displayName;
  final String username;
  final String? profilePicture;
  final String? bio;
  final double totalDistance; // meters
  final int totalDuration; // minutes
  final int points;
  final String? mastodonUrl;
  final bool privateProfile;
  final bool following;
  final bool followPending;
  final bool followedBy;
  final bool muted;
  final bool blocked;

  const TrwlUser({
    required this.id,
    required this.displayName,
    required this.username,
    this.profilePicture,
    this.bio,
    this.totalDistance = 0,
    this.totalDuration = 0,
    this.points = 0,
    this.mastodonUrl,
    this.privateProfile = false,
    this.following = false,
    this.followPending = false,
    this.followedBy = false,
    this.muted = false,
    this.blocked = false,
  });

  factory TrwlUser.fromJson(Map<String, dynamic> j) => TrwlUser(
        id: _int(j['id']) ?? 0,
        displayName: (j['displayName'] ?? j['username'] ?? '').toString(),
        username: (j['username'] ?? '').toString(),
        profilePicture: j['profilePicture'] as String?,
        bio: j['bio'] as String?,
        totalDistance: _dbl(j['totalDistance']) ?? 0,
        totalDuration: _int(j['totalDuration']) ?? 0,
        points: _int(j['points']) ?? 0,
        mastodonUrl: j['mastodonUrl'] as String?,
        privateProfile: j['privateProfile'] == true,
        following: j['following'] == true,
        followPending: j['followPending'] == true,
        followedBy: j['followedBy'] == true,
        muted: j['muted'] == true,
        blocked: j['blocked'] == true,
      );

  /// Distance in km, one decimal.
  double get distanceKm => totalDistance / 1000;
}

/// One stop on a trip (origin / destination of a check-in, or a stopover).
class TrwlStopover {
  final int stationId;
  final String name;
  final DateTime? arrivalPlanned;
  final DateTime? arrivalReal;
  final DateTime? departurePlanned;
  final DateTime? departureReal;
  final String? platform;
  final bool isArrivalDelayed;
  final bool isDepartureDelayed;
  final bool cancelled;

  const TrwlStopover({
    required this.stationId,
    required this.name,
    this.arrivalPlanned,
    this.arrivalReal,
    this.departurePlanned,
    this.departureReal,
    this.platform,
    this.isArrivalDelayed = false,
    this.isDepartureDelayed = false,
    this.cancelled = false,
  });

  factory TrwlStopover.fromJson(Map<String, dynamic> j) => TrwlStopover(
        stationId: _int(j['id']) ?? 0,
        name: (j['name'] ?? '').toString(),
        arrivalPlanned: _dt(j['arrivalPlanned']),
        arrivalReal: _dt(j['arrivalReal']),
        departurePlanned: _dt(j['departurePlanned']),
        departureReal: _dt(j['departureReal']),
        platform: (j['departurePlatformReal'] ??
                j['departurePlatformPlanned'] ??
                j['platform']) as String?,
        isArrivalDelayed: j['isArrivalDelayed'] == true,
        isDepartureDelayed: j['isDepartureDelayed'] == true,
        cancelled: j['cancelled'] == true,
      );

  DateTime? get departure => departureReal ?? departurePlanned;
  DateTime? get arrival => arrivalReal ?? arrivalPlanned;
}

/// The transport/check-in block of a status (`checkin` / legacy `train`).
class TrwlTransport {
  final int trip; // internal trip id
  final String hafasId;
  final String lineName;
  final String? journeyNumber;
  final int distance; // meters
  final int points;
  final int duration; // minutes
  final String? routeColor;
  final TrwlStopover? origin;
  final TrwlStopover? destination;

  const TrwlTransport({
    required this.trip,
    required this.hafasId,
    required this.lineName,
    this.journeyNumber,
    this.distance = 0,
    this.points = 0,
    this.duration = 0,
    this.routeColor,
    this.origin,
    this.destination,
  });

  factory TrwlTransport.fromJson(Map<String, dynamic> j) => TrwlTransport(
        trip: _int(j['trip']) ?? 0,
        hafasId: (j['hafasId'] ?? '').toString(),
        lineName: (j['lineName'] ?? '').toString(),
        journeyNumber:
            (j['manualJourneyNumber'] ?? j['journeyNumber'])?.toString(),
        distance: _int(j['distance']) ?? 0,
        points: _int(j['points']) ?? 0,
        duration: _int(j['duration']) ?? 0,
        routeColor: j['routeColor'] as String?,
        origin: j['origin'] is Map<String, dynamic>
            ? TrwlStopover.fromJson(j['origin'])
            : null,
        destination: j['destination'] is Map<String, dynamic>
            ? TrwlStopover.fromJson(j['destination'])
            : null,
      );

  double get distanceKm => distance / 1000;
}

/// A check-in / status in a feed.
class TrwlStatus {
  final int id;
  final String body;
  final int likes;
  final bool liked;
  final bool isLikable;
  final int visibility;
  final DateTime? createdAt;
  final TrwlUser? user;
  final TrwlTransport? transport;

  const TrwlStatus({
    required this.id,
    required this.body,
    this.likes = 0,
    this.liked = false,
    this.isLikable = false,
    this.visibility = 0,
    this.createdAt,
    this.user,
    this.transport,
  });

  factory TrwlStatus.fromJson(Map<String, dynamic> j) {
    final t = j['checkin'] ?? j['train']; // 'train' is the legacy alias
    final u = j['user'] ?? j['userDetails'];
    return TrwlStatus(
      id: _int(j['id']) ?? 0,
      body: (j['body'] ?? '').toString(),
      likes: _int(j['likes']) ?? 0,
      liked: j['liked'] == true,
      isLikable: j['isLikable'] == true,
      visibility: _int(j['visibility']) ?? 0,
      createdAt: _dt(j['createdAt']),
      user: u is Map<String, dynamic> ? TrwlUser.fromJson(u) : null,
      transport:
          t is Map<String, dynamic> ? TrwlTransport.fromJson(t) : null,
    );
  }
}

/// A Träwelling station (autocomplete / trip origin-destination).
class TrwlStation {
  final int id;
  final String name;
  final double? latitude;
  final double? longitude;

  const TrwlStation({
    required this.id,
    required this.name,
    this.latitude,
    this.longitude,
  });

  factory TrwlStation.fromJson(Map<String, dynamic> j) => TrwlStation(
        id: _int(j['id']) ?? 0,
        name: (j['name'] ?? '').toString(),
        latitude: _dbl(j['latitude']),
        longitude: _dbl(j['longitude']),
      );
}

/// A departure from a station's board — the entry point for a check-in.
class TrwlDeparture {
  final String tripId; // hafasTripId
  final String lineName;
  final String? direction;
  final DateTime? when; // real
  final DateTime? plannedWhen;
  final String? platform;
  final String? routeColor;

  const TrwlDeparture({
    required this.tripId,
    required this.lineName,
    this.direction,
    this.when,
    this.plannedWhen,
    this.platform,
    this.routeColor,
  });

  factory TrwlDeparture.fromJson(Map<String, dynamic> j) {
    final line = j['line'] as Map<String, dynamic>?;
    return TrwlDeparture(
      tripId: (j['tripId'] ?? '').toString(),
      lineName: (line?['name'] ?? line?['id'] ?? '').toString(),
      direction: j['direction'] as String?,
      when: _dt(j['when']),
      plannedWhen: _dt(j['plannedWhen']),
      platform: (j['platform'] ?? j['plannedPlatform']) as String?,
      routeColor: line?['color'] as String?,
    );
  }

  DateTime? get departure => when ?? plannedWhen;
  bool get isDelayed =>
      when != null && plannedWhen != null && when!.isAfter(plannedWhen!);
}

/// Full trip with stopovers, fetched after picking a departure. Used to choose
/// the destination stop for a check-in.
class TrwlTrip {
  final int id;
  final String tripId; // hafasTripId
  final String lineName;
  final String? direction;
  final List<TrwlStopover> stopovers;

  const TrwlTrip({
    required this.id,
    required this.tripId,
    required this.lineName,
    this.direction,
    this.stopovers = const [],
  });

  factory TrwlTrip.fromJson(Map<String, dynamic> j) {
    final stops = (j['stopovers'] as List<dynamic>? ?? [])
        .whereType<Map<String, dynamic>>()
        .map(TrwlStopover.fromJson)
        .toList();
    return TrwlTrip(
      id: _int(j['id']) ?? 0,
      tripId: (j['tripId'] ?? '').toString(),
      lineName: (j['lineName'] ?? '').toString(),
      direction: (j['destination'] is Map<String, dynamic>)
          ? j['destination']['name'] as String?
          : null,
      stopovers: stops,
    );
  }
}

/// Status visibility levels (Träwelling `StatusVisibility` enum).
enum TrwlVisibility {
  public(0, 'Öffentlich'),
  unlisted(1, 'Nicht gelistet'),
  followers(2, 'Nur Follower'),
  private(3, 'Privat'),
  authenticated(4, 'Angemeldete');

  final int value;
  final String label;
  const TrwlVisibility(this.value, this.label);
}
