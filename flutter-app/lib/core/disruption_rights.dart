// "Was darf ich jetzt?" — what a rider may do when their train is cancelled or
// late, by ticket type. Pure rules, no UI, so every answer is unit-tested.
//
// Sources (checked 2026-11-13):
// - bahn.de/faq/zugausfall-verspaetung: from an expected 20 min delay at the
//   destination you may continue "auf der gleichen Strecke oder über eine
//   andere Strecke" and take another train that needs no reservation. With a
//   Nahverkehr ticket a higher-class train needs the extra fare paid first,
//   refunded afterwards — not for "stark ermäßigte Fahrkarten (z. B.
//   Schönes-Wochenende-Ticket, Länder-Tickets)".
// - bahn.de/faq/gk/angebot/zeitkarten/deutschland-ticket/fahrgastrechte: with
//   the Deutschland-Ticket a long-distance train always needs its own ticket
//   and is not refunded — except when the day's last connection (arrival by
//   24:00) is affected, or ≥60 min delay with planned arrival 0–5 h; then
//   ICE/IC or taxi, refunded up to 120 €.

/// What the rider travels on, as far as the rules care.
enum RightsTicket {
  /// Flexpreis or any other long-distance fare without a train binding.
  fernverkehrFlex,

  /// Sparpreis / Super Sparpreis: train-bound, the binding lifts at ≥20 min.
  fernverkehrSpar,

  /// A normal Nahverkehr single/day ticket (RE/RB/S-Bahn).
  nahverkehr,

  /// Deutschland-Ticket.
  deutschlandTicket,

  /// Länder-Ticket, Schönes-Wochenende-Ticket and other "stark ermäßigt".
  laenderTicket,

  /// Not known — answer for every type.
  unbekannt,
}

class RightsAnswer {
  final String title;
  final String text;
  final bool allowed;
  const RightsAnswer(this.title, this.text, {required this.allowed});
}

class DisruptionRights {
  static const generalUrl = 'https://www.bahn.de/faq/zugausfall-verspaetung';
  static const dticketUrl =
      'https://www.bahn.de/faq/gk/angebot/zeitkarten/deutschland-ticket/fahrgastrechte';

  /// The rider's ticket from a DB order's offer name ("Flexpreis Young",
  /// "Super Sparpreis" …) and the app's Deutschland-Ticket setting.
  static RightsTicket ticketFrom({
    String? angebotsname,
    bool hasDeutschlandTicket = false,
  }) {
    final a = (angebotsname ?? '').toLowerCase();
    if (a.contains('sparpreis')) return RightsTicket.fernverkehrSpar;
    if (a.contains('flexpreis')) return RightsTicket.fernverkehrFlex;
    if (a.contains('deutschland')) return RightsTicket.deutschlandTicket;
    if (a.contains('länder') || a.contains('-ticket')) {
      return RightsTicket.laenderTicket;
    }
    if (hasDeutschlandTicket) return RightsTicket.deutschlandTicket;
    return RightsTicket.unbekannt;
  }

  /// Answers for a trip whose expected delay at the destination is
  /// [delayMinutes] (or that has a cancelled train: [cancelled]).
  /// [lastOfDay]: the cancelled/late connection is the day's last one that
  /// arrives by midnight. [plannedArrival] decides the 0–5 h night rule.
  static List<RightsAnswer> answers({
    required RightsTicket ticket,
    required int delayMinutes,
    required bool cancelled,
    bool lastOfDay = false,
    DateTime? plannedArrival,
  }) {
    final disrupted = cancelled || delayMinutes >= 20;
    if (!disrupted) return const [];
    final night =
        plannedArrival != null && plannedArrival.hour < 5 && delayMinutes >= 60;
    final taxiCase = lastOfDay || night;
    final out = <RightsAnswer>[];

    bool show(RightsTicket t) =>
        ticket == t || ticket == RightsTicket.unbekannt;

    if (show(RightsTicket.fernverkehrFlex) ||
        show(RightsTicket.fernverkehrSpar)) {
      out.add(
        RightsAnswer(
          ticket == RightsTicket.fernverkehrSpar
              ? 'Sparpreis: Zugbindung aufgehoben'
              : 'Fernverkehrs-Ticket: anderer Zug, auch andere Strecke',
          'Du darfst den nächsten Zug nehmen, auch ICE/IC und über eine andere '
          'Strecke. Nur reservierungspflichtige Züge (z. B. Nachtzüge) sind '
          'ausgenommen. Kein Aufpreis.',
          allowed: true,
        ),
      );
    }
    if (show(RightsTicket.nahverkehr)) {
      out.add(
        const RightsAnswer(
          'Nahverkehrs-Ticket: ICE/IC mit Erstattung',
          'Du darfst einen ICE/IC nehmen, musst aber vorher die Fahrkarte oder '
              'den Aufpreis kaufen. Das Geld holst du dir über das '
              'Fahrgastrechte-Formular zurück.',
          allowed: true,
        ),
      );
    }
    if (show(RightsTicket.deutschlandTicket)) {
      out.add(
        RightsAnswer(
          'Deutschlandticket',
          taxiCase
              ? 'Heute ausnahmsweise erlaubt: ICE/IC oder Taxi. Ticket bzw. '
                    'Taxi erst selbst zahlen, erstattet werden bis 120 €.'
              : 'Kein ICE/IC: dafür brauchst du ein eigenes Ticket, das nicht '
                    'erstattet wird. Nimm den nächsten Nahverkehrszug.',
          allowed: taxiCase,
        ),
      );
    }
    if (show(RightsTicket.laenderTicket)) {
      out.add(
        const RightsAnswer(
          'Länder-Ticket / Schönes-Wochenende-Ticket',
          'Kein ICE/IC mit Erstattung, diese Tickets sind „stark ermäßigt“. '
              'Nimm den nächsten Nahverkehrszug.',
          allowed: false,
        ),
      );
    }
    out.add(
      RightsAnswer(
        'Taxi',
        taxiCase
            ? 'Bis 120 € werden erstattet: ${lastOfDay ? 'die letzte Verbindung des Tages ist betroffen' : 'planmäßige Ankunft zwischen 0 und 5 Uhr, ≥60 Min Verspätung'}. Quittung aufheben.'
            : 'Wird nicht erstattet, solange heute noch ein Zug fährt. '
                  'Erst bei der letzten Verbindung des Tages oder Ankunft '
                  'zwischen 0 und 5 Uhr mit ≥60 Min Verspätung.',
        allowed: taxiCase,
      ),
    );
    return out;
  }
}
