/// How fast *you* actually change trains.
///
/// "8 Minuten Umstieg" is not one fact — it's comfortable with a backpack and
/// impossible with a pram and a lift that's out. DB plans with a single
/// station-wide minimum transfer time; this scales the app's own judgement of
/// a transfer on top of it, so the warnings match the rider (#11, point 7).
///
/// Deliberately a *local* profile: it says something about the user's body and
/// luggage, so it never leaves the device.
enum TransferProfile {
  fast('Schnell', '🚀', 0.6, 'Du kennst die Bahnhöfe und gehst zügig.'),
  normal('Normal', '🚶', 1.0, 'Standard — wie die Bahn plant.'),
  luggage('Mit Gepäck', '🧳', 1.4, 'Koffer, Treppen kosten Zeit.'),
  child('Mit Kind', '👨‍👧', 1.6, 'Kinderwagen, kleine Schritte, Aufzüge.'),
  bike('Mit Fahrrad', '🚲', 1.6, 'Aufzug oder Rampe statt Treppe.'),
  accessible('Barrierearm', '♿', 1.8, 'Nur Aufzüge und Rampen.'),
  slow('Mehr Zeit', '🐢', 2.0, 'Umsteigen darf nicht hetzen.');

  const TransferProfile(this.label, this.emoji, this.factor, this.hint);

  /// Shown in the settings picker.
  final String label;
  final String emoji;
  final String hint;

  /// Multiplies the planned transfer gap's *perceived* tightness. >1 means the
  /// same 8 minutes feel shorter to you than to the timetable.
  final double factor;

  /// The gap in minutes, as this profile experiences it. A 10-minute transfer
  /// with a pram (1.6) is judged like a ~6-minute one.
  ///
  /// Scales the gap rather than the thresholds so every consumer — the risk
  /// banner, the live alert, the reliability sort — gets one comparable number
  /// and can't drift apart.
  int effectiveGap(int plannedGapMinutes) =>
      (plannedGapMinutes / factor).floor();

  static TransferProfile fromName(String? name) =>
      TransferProfile.values.firstWhere((p) => p.name == name,
          orElse: () => TransferProfile.normal);
}
