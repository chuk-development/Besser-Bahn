import 'package:latlong2/latlong.dart';

import '../models/journey.dart';

/// Per-trip metrics derived purely from a [Journey] — distance and the arrival
/// delay at the final stop. Used by the lifetime travel-stats accumulator and
/// anywhere a single trip's numbers are shown.
///
/// Distance is the great-circle sum of each transit leg's origin→destination,
/// scaled by [_railDetourFactor] because tracks curve and detour around terrain
/// — a straight line undercounts real rail kilometres by ~15-25 %. It's an
/// honest estimate, not the billed tariff distance (which needs DB's route
/// graph / login). Legs missing coordinates are skipped, so the result is a
/// lower bound rather than wrong.
class TripMetrics {
  /// "On time" cut-off (DB counts < 6 min late as pünktlich).
  static const int onTimeThresholdMinutes = 6;

  static const double _railDetourFactor = 1.2;
  static const Distance _geo = Distance();

  /// Estimated travelled distance for [journey], in kilometres.
  static double distanceKm(Journey journey) {
    var metres = 0.0;
    for (final leg in journey.legs) {
      if (leg.isWalking) continue;
      final a = leg.origin, b = leg.destination;
      if (!a.hasLocation || !b.hasLocation) continue;
      metres += _geo.as(
        LengthUnit.Meter,
        LatLng(a.latitude!, a.longitude!),
        LatLng(b.latitude!, b.longitude!),
      );
    }
    return metres / 1000.0 * _railDetourFactor;
  }

  /// Arrival delay at the final destination in minutes (0 if early/unknown).
  static int finalArrivalDelayMinutes(Journey journey) {
    final last =
        journey.legs.where((l) => !l.isWalking).toList().lastOrNull;
    final d = last?.arrivalDelayMinutes ?? 0;
    return d > 0 ? d : 0;
  }
}
