import '../models/journey.dart';

/// The role a connection plays in a result list — the honest answer to "which
/// one should I take?", which is rarely just "the fastest" (#11, point 9).
enum JourneyHighlight {
  fastest('Schnellste', '⚡'),
  cheapest('Günstigste', '💶'),
  safest('Sicherste', '🛡️'),
  balanced('Bester Kompromiss', '⭐');

  const JourneyHighlight(this.label, this.emoji);
  final String label;
  final String emoji;
}

/// Pick the standout connections from [journeys].
///
/// [scoreOf] returns the reliability prediction (0..100) or null while it's
/// still loading — the caller owns those requests, so this stays pure and
/// testable.
///
/// Only labels what it can defend:
///  * a category is dropped when the data for it is missing (no prices → no
///    "Günstigste"), rather than labelling an arbitrary connection.
///  * a category is dropped when it doesn't *distinguish* anything — if every
///    connection costs the same, "Günstigste" is noise, not information.
///  * `balanced` only appears when it's a genuinely different pick from the
///    three extremes; a badge that duplicates "Schnellste" tells you nothing.
Map<JourneyHighlight, Journey> journeyHighlights(
  List<Journey> journeys,
  double? Function(Journey) scoreOf,
) {
  if (journeys.length < 2) return const {};
  final out = <JourneyHighlight, Journey>{};

  Duration? dur(Journey j) => j.duration;
  double? price(Journey j) => j.price?.amount;

  final withDuration = journeys.where((j) => dur(j) != null).toList();
  final withPrice = journeys.where((j) => (price(j) ?? 0) > 0).toList();
  final withScore = journeys.where((j) => scoreOf(j) != null).toList();

  // "Cheapest" only means something if fares actually differ.
  bool varies<T extends Comparable>(List<Journey> list, T? Function(Journey) f) {
    final vals = list.map(f).whereType<T>().toSet();
    return vals.length > 1;
  }

  if (withDuration.length > 1 && varies(withDuration, (j) => dur(j))) {
    out[JourneyHighlight.fastest] =
        withDuration.reduce((a, b) => dur(a)! <= dur(b)! ? a : b);
  }
  if (withPrice.length > 1 && varies(withPrice, (j) => price(j))) {
    out[JourneyHighlight.cheapest] =
        withPrice.reduce((a, b) => price(a)! <= price(b)! ? a : b);
  }
  if (withScore.length > 1 && varies(withScore, (j) => scoreOf(j))) {
    out[JourneyHighlight.safest] =
        withScore.reduce((a, b) => scoreOf(a)! >= scoreOf(b)! ? a : b);
  }

  // The compromise: normalise each axis to 0..1 (best = 1) and take the best
  // total. Needs at least two axes, or it's just a rename of an extreme.
  final axes = [
    if (out.containsKey(JourneyHighlight.fastest)) 'd',
    if (out.containsKey(JourneyHighlight.cheapest)) 'p',
    if (out.containsKey(JourneyHighlight.safest)) 's',
  ];
  if (axes.length < 2) return out;

  final candidates = journeys
      .where((j) =>
          (!axes.contains('d') || dur(j) != null) &&
          (!axes.contains('p') || (price(j) ?? 0) > 0) &&
          (!axes.contains('s') || scoreOf(j) != null))
      .toList();
  if (candidates.length < 3) return out;

  double norm(double v, double lo, double hi, {required bool lowerIsBetter}) {
    if (hi == lo) return 1;
    final t = (v - lo) / (hi - lo);
    return lowerIsBetter ? 1 - t : t;
  }

  final durs = candidates.map((j) => dur(j)!.inSeconds.toDouble()).toList();
  final prices = axes.contains('p')
      ? candidates.map((j) => price(j)!).toList()
      : <double>[];
  final scores = axes.contains('s')
      ? candidates.map((j) => scoreOf(j)!).toList()
      : <double>[];

  double best = -1;
  Journey? winner;
  for (final j in candidates) {
    var total = 0.0;
    if (axes.contains('d')) {
      total += norm(dur(j)!.inSeconds.toDouble(), durs.reduce((a, b) => a < b ? a : b),
          durs.reduce((a, b) => a > b ? a : b), lowerIsBetter: true);
    }
    if (axes.contains('p')) {
      total += norm(price(j)!, prices.reduce((a, b) => a < b ? a : b),
          prices.reduce((a, b) => a > b ? a : b), lowerIsBetter: true);
    }
    if (axes.contains('s')) {
      total += norm(scoreOf(j)!, scores.reduce((a, b) => a < b ? a : b),
          scores.reduce((a, b) => a > b ? a : b), lowerIsBetter: false);
    }
    if (total > best) {
      best = total;
      winner = j;
    }
  }

  // Only badge it if it isn't already one of the extremes.
  if (winner != null && !out.values.any((j) => identical(j, winner))) {
    out[JourneyHighlight.balanced] = winner;
  }
  return out;
}
