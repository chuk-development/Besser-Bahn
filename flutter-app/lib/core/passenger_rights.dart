import '../models/journey.dart';

/// EU rail passenger-rights (Fahrgastrechte) eligibility, derived purely from a
/// journey's final arrival delay. German long-distance rules:
///  - from 60 min late: 25 % of the fare back,
///  - from 120 min late: 50 %.
/// (Plus possible care/onward-travel rights we don't quantify here.)
///
/// This is detection + form prefill help, not legal advice — the actual claim
/// goes through DB's Fahrgastrechte form.
class PassengerRights {
  /// Official DB Fahrgastrechte information & online-claim entry point.
  static const formUrl = 'https://www.bahn.de/fahrgastrechte';

  final int delayMinutes;
  final int percent; // 0, 25 or 50
  const PassengerRights._(this.delayMinutes, this.percent);

  bool get isEligible => percent > 0;

  /// Evaluate [journey] from its final arrival delay. Returns a result with
  /// [isEligible] false when under the 60-minute threshold.
  factory PassengerRights.evaluate(Journey journey) {
    final last = journey.legs.where((l) => !l.isWalking).toList();
    final delay = last.isEmpty ? 0 : (last.last.arrivalDelayMinutes);
    final pct = delay >= 120 ? 50 : (delay >= 60 ? 25 : 0);
    return PassengerRights._(delay > 0 ? delay : 0, pct);
  }

  /// Refund amount for a known [fareEuros], or null if the fare is unknown.
  double? refundEuros(double? fareEuros) =>
      (fareEuros == null || percent == 0) ? null : fareEuros * percent / 100;

  /// Copy-ready summary the user can paste into the DB form (or keep as proof):
  /// route, date, trains, scheduled vs actual arrival and the delay.
  String prefillText(Journey journey) {
    String hhmm(DateTime? t) {
      final l = t?.toLocal();
      return l == null
          ? '—'
          : '${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}';
    }

    final transit = journey.legs.where((l) => !l.isWalking).toList();
    final o = journey.origin?.name ?? '';
    final d = journey.destination?.name ?? '';
    final dep = (journey.plannedDeparture ?? journey.departure)?.toLocal();
    final last = transit.isEmpty ? null : transit.last;
    final planAn = last?.plannedArrival ?? last?.arrival;
    final realAn = last?.arrival ?? last?.plannedArrival;

    final b = StringBuffer()
      ..writeln('Fahrgastrechte – Verspätung')
      ..writeln('$o → $d');
    if (dep != null) {
      b.writeln('Datum: ${dep.day.toString().padLeft(2, '0')}.'
          '${dep.month.toString().padLeft(2, '0')}.${dep.year}');
    }
    final trains = transit
        .map((l) => l.line?.displayName ?? '')
        .where((s) => s.isNotEmpty)
        .join(', ');
    if (trains.isNotEmpty) b.writeln('Züge: $trains');
    b
      ..writeln('Planmäßige Ankunft: ${hhmm(planAn)}')
      ..writeln('Tatsächliche Ankunft: ${hhmm(realAn)}')
      ..writeln('Verspätung: $delayMinutes Min')
      ..writeln('Anspruch: $percent % Entschädigung');
    return b.toString();
  }
}
