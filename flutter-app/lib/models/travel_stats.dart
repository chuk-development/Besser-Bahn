/// Lifetime, on-device travel tally — the persisted half of the "Reise­statistik"
/// feature. Saved trips ([SavedJourney]) auto-purge a week after arrival, so we
/// can't derive lifetime totals from them; instead each completed trip is folded
/// into this accumulator exactly once (see TravelStatsNotifier) and kept
/// forever, locally, with no server in the loop.
///
/// CO₂ is intentionally absent: it's not reliably derivable client-side. The
/// official figure lives in the DB-Bonus app and will be fetched once real
/// Deutsche-Bahn login lands — until then the UI shows a placeholder row.
class TravelStats {
  /// Summed leg distance across all counted trips, in kilometres.
  final double totalKm;

  /// Number of completed trips counted.
  final int tripCount;

  /// Summed arrival delay (minutes) at each trip's final destination. Only
  /// positive delays add; an early/on-time arrival contributes 0.
  final int totalDelayMinutes;

  /// Trips that arrived "on time" by the DB definition (under 6 min late).
  final int onTimeCount;

  /// Worst single arrival delay seen, in minutes.
  final int worstDelayMinutes;

  /// Longest single trip, in kilometres.
  final double longestTripKm;

  /// Arrival time of the earliest counted trip — powers "seit Monat Jahr".
  /// 0 when nothing has been counted yet.
  final int firstTripMs;

  const TravelStats({
    this.totalKm = 0,
    this.tripCount = 0,
    this.totalDelayMinutes = 0,
    this.onTimeCount = 0,
    this.worstDelayMinutes = 0,
    this.longestTripKm = 0,
    this.firstTripMs = 0,
  });

  static const empty = TravelStats();

  bool get isEmpty => tripCount == 0;

  /// Share of trips that arrived on time, 0‥1. 0 when no trips counted.
  double get onTimeRate => tripCount == 0 ? 0 : onTimeCount / tripCount;

  /// Average arrival delay per trip, in minutes.
  double get avgDelayMinutes =>
      tripCount == 0 ? 0 : totalDelayMinutes / tripCount;

  TravelStats copyWith({
    double? totalKm,
    int? tripCount,
    int? totalDelayMinutes,
    int? onTimeCount,
    int? worstDelayMinutes,
    double? longestTripKm,
    int? firstTripMs,
  }) {
    return TravelStats(
      totalKm: totalKm ?? this.totalKm,
      tripCount: tripCount ?? this.tripCount,
      totalDelayMinutes: totalDelayMinutes ?? this.totalDelayMinutes,
      onTimeCount: onTimeCount ?? this.onTimeCount,
      worstDelayMinutes: worstDelayMinutes ?? this.worstDelayMinutes,
      longestTripKm: longestTripKm ?? this.longestTripKm,
      firstTripMs: firstTripMs ?? this.firstTripMs,
    );
  }

  Map<String, dynamic> toJson() => {
        'totalKm': totalKm,
        'tripCount': tripCount,
        'totalDelayMinutes': totalDelayMinutes,
        'onTimeCount': onTimeCount,
        'worstDelayMinutes': worstDelayMinutes,
        'longestTripKm': longestTripKm,
        'firstTripMs': firstTripMs,
      };

  factory TravelStats.fromJson(Map<String, dynamic> json) => TravelStats(
        totalKm: (json['totalKm'] as num?)?.toDouble() ?? 0,
        tripCount: json['tripCount'] as int? ?? 0,
        totalDelayMinutes: json['totalDelayMinutes'] as int? ?? 0,
        onTimeCount: json['onTimeCount'] as int? ?? 0,
        worstDelayMinutes: json['worstDelayMinutes'] as int? ?? 0,
        longestTripKm: (json['longestTripKm'] as num?)?.toDouble() ?? 0,
        firstTripMs: json['firstTripMs'] as int? ?? 0,
      );
}
