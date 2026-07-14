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

  /// One number to rank connections by, 0..100 — "how likely is this trip to
  /// work out" (#11, „Zuverlässigste Verbindung").
  ///
  /// The two scores answer different questions (do I catch my transfers / do I
  /// arrive roughly on time), and a trip needs BOTH to go right. They're not
  /// independent, so multiplying them would invent a precision the model
  /// doesn't have — the weakest link is the honest summary, and it can't rank
  /// a connection above its own worst risk. A direct train has no transfer
  /// score, so punctuality alone decides.
  double? get reliabilityScore {
    final scores = [verbindungsscore, puenktlichkeit].whereType<double>();
    if (scores.isEmpty) return null;
    return scores.reduce((a, b) => a < b ? a : b);
  }
}
