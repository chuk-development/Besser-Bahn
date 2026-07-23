import '../models/journey.dart';

/// The kind of fare the trip was made on. It decides how the delay compensation
/// is calculated: a percentage of the fare for single/return tickets, a fixed
/// statutory pauschale for time cards (Deutschlandticket & Co.).
enum FareKind {
  /// A single ticket for one direction.
  einzelfahrt,

  /// A return ticket bought as one fare — only the affected direction counts,
  /// so the compensation base is half the price.
  hinUndRueck,

  /// Deutschlandticket (Nahverkehr, 2. Klasse) — fixed pauschale.
  deutschlandTicket,

  /// Any other season ticket / Abo (BahnCard 100, Verbund-Abo, Zeitkarte).
  zeitkarte,

  /// Unknown — we can't pick a calculation, so no amount is shown.
  unbekannt,
}

extension FareKindLabel on FareKind {
  String get label => switch (this) {
        FareKind.einzelfahrt => 'Einzelticket',
        FareKind.hinUndRueck => 'Hin- und Rückfahrt',
        FareKind.deutschlandTicket => 'Deutschlandticket',
        FareKind.zeitkarte => 'Andere Zeitkarte / Abo',
        FareKind.unbekannt => 'Unbekannt',
      };
}

/// The estimated payout for a claim — either a concrete euro amount, a fixed
/// statutory pauschale, or nothing computable. Deliberately non-binding: the
/// real amount is decided by DB when the form is submitted.
class RefundEstimate {
  /// Concrete euro amount, or null when it can't be computed (unknown fare).
  final double? amount;

  /// True when [amount] is a fixed statutory pauschale (time cards), not a
  /// percentage of a fare.
  final bool isPauschale;

  /// True when a percentage was computed but it falls under the €4 minimum
  /// payout — the claim exists on paper but DB does not pay out amounts below
  /// four euro.
  final bool belowMinimum;

  const RefundEstimate({
    this.amount,
    this.isPauschale = false,
    this.belowMinimum = false,
  });

  /// Whether there is actually money to get (a payout at or above the minimum).
  bool get isPayable => amount != null && amount! > 0 && !belowMinimum;
}

/// EU rail passenger-rights (Fahrgastrechte) eligibility, derived purely from a
/// journey's final arrival delay. German rules:
///  - from 60 min late: 25 % of the fare back,
///  - from 120 min late: 50 %.
/// Time cards (Deutschlandticket etc.) get a fixed pauschale instead. Amounts
/// under €4 are not paid out. (Plus care/onward-travel rights we don't
/// quantify here.)
///
/// This is detection + form-prefill help, **not legal advice** — the actual
/// claim, and the binding amount, go through DB's Fahrgastrechte form.
class PassengerRights {
  /// Official DB Fahrgastrechte information & online-claim entry point.
  static const formUrl = 'https://www.bahn.de/fahrgastrechte';

  /// DB does not pay out compensation below this amount.
  static const minPayoutEuros = 4.0;

  /// Statutory Nahverkehr time-card pauschale per delayed trip (≥60 min),
  /// 2. Klasse / 1. Klasse. Deutschlandticket is 2. Klasse only. These are set
  /// by law and can change — shown as an estimate, confirmed in the form.
  static const pauschaleSecondClassEuros = 1.50;
  static const pauschaleFirstClassEuros = 2.25;

  /// Non-binding wording the UI must show verbatim, from the issue.
  static const disclaimer =
      'Nach den gespeicherten Reisedaten könnten Fahrgastrechte bestehen. '
      'Bitte prüfe die Angaben vor dem Einreichen. Dies ist keine '
      'Rechtsberatung.';

  final int delayMinutes;
  final int percent; // 0, 25 or 50
  const PassengerRights._(this.delayMinutes, this.percent);

  bool get isEligible => percent > 0;

  /// Evaluate [journey] from its final arrival delay. Returns a result with
  /// [isEligible] false when under the 60-minute threshold.
  ///
  /// The delay is read from whichever source is larger: the last transit leg's
  /// live `arrivalDelay`, or the plain difference between planned and actual
  /// final arrival. A trip re-planned around a missed connection can land far
  /// later than planned without the last leg carrying a delay of its own, so
  /// the difference is the safety net.
  factory PassengerRights.evaluate(Journey journey) {
    return PassengerRights.fromDelay(delayMinutesOf(journey));
  }

  /// Build directly from a known delay in minutes — used when the rider corrects
  /// the delay by hand (a completed trip's stored data often has no live delay).
  factory PassengerRights.fromDelay(int delayMinutes) {
    final d = delayMinutes < 0 ? 0 : delayMinutes;
    final pct = d >= 120 ? 50 : (d >= 60 ? 25 : 0);
    return PassengerRights._(d, pct);
  }

  /// The final arrival delay of [journey] in minutes, never negative.
  static int delayMinutesOf(Journey journey) {
    final transit = journey.legs.where((l) => !l.isWalking).toList();
    if (transit.isEmpty) return 0;
    final last = transit.last;
    final legDelay = last.arrivalDelayMinutes;
    final planned = last.plannedArrival ?? journey.plannedArrival;
    final actual = last.arrival ?? journey.arrival;
    final diff = (planned != null && actual != null)
        ? actual.difference(planned).inMinutes
        : 0;
    final delay = legDelay > diff ? legDelay : diff;
    return delay > 0 ? delay : 0;
  }

  /// Refund amount for a known [fareEuros], or null if the fare is unknown.
  /// Kept for the compact banner; [estimate] is the full assistant version.
  double? refundEuros(double? fareEuros) =>
      (fareEuros == null || percent == 0) ? null : fareEuros * percent / 100;

  /// The full payout estimate for a [fareKind]. [fareEuros] is the ticket price
  /// (ignored for time cards), [firstClass] only affects the time-card
  /// pauschale.
  RefundEstimate estimate(
    FareKind fareKind, {
    double? fareEuros,
    bool firstClass = false,
  }) {
    if (percent == 0) return const RefundEstimate();
    switch (fareKind) {
      case FareKind.deutschlandTicket:
        // Nahverkehr, 2. Klasse only.
        return const RefundEstimate(
            amount: pauschaleSecondClassEuros, isPauschale: true);
      case FareKind.zeitkarte:
        return RefundEstimate(
          amount:
              firstClass ? pauschaleFirstClassEuros : pauschaleSecondClassEuros,
          isPauschale: true,
        );
      case FareKind.einzelfahrt:
      case FareKind.hinUndRueck:
        if (fareEuros == null) return const RefundEstimate();
        final base =
            fareKind == FareKind.hinUndRueck ? fareEuros / 2 : fareEuros;
        final amount = base * percent / 100;
        return RefundEstimate(
          amount: amount,
          belowMinimum: amount < minPayoutEuros,
        );
      case FareKind.unbekannt:
        return const RefundEstimate();
    }
  }

  /// Special cases the rider must check before claiming — the compensation can
  /// be reduced, refused, or handled by someone other than DB.
  static const caveats = [
    'Bei höherer Gewalt (z. B. Unwetter, Streik) kann die Entschädigung '
        'entfallen.',
    'War die Störung schon vor dem Kauf bekannt, besteht meist kein Anspruch.',
    'Bei Split-Tickets zählt jede Fahrkarte einzeln — pro Ticket prüfen.',
    'Für Verbund- und Ländertickets ist oft nicht die DB zuständig.',
  ];

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
