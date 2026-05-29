/// Connection-reliability prediction for a [Journey], from our self-hosted
/// bahnvorhersage model (`bahn.chuk.dev/v1/journey-scores`).
class JourneyPrediction {
  /// P(all transfers caught), 0..100. `null` for a direct connection.
  final double? verbindungsscore;

  /// P(final arrival ≤ 10 min late), 0..100.
  final double? puenktlichkeit;

  const JourneyPrediction({this.verbindungsscore, this.puenktlichkeit});

  factory JourneyPrediction.fromJson(Map<String, dynamic> json) =>
      JourneyPrediction(
        verbindungsscore: (json['verbindungsscore'] as num?)?.toDouble(),
        puenktlichkeit: (json['puenktlichkeit'] as num?)?.toDouble(),
      );

  bool get hasAny => verbindungsscore != null || puenktlichkeit != null;
}
