import '../models/split_ticket.dart';

/// What one connection costs ON TOP of a Deutschlandticket the rider already
/// holds — the only number that matters once the ticket is paid for (#28).
///
/// Deliberately NOT a second pricing engine: [SplitEngine] already prices a
/// D-Ticket run by zeroing every covered segment and DP-ing the cheapest
/// combination of the rest, then clamping it to the through fare (you can
/// always just buy the direct ticket). That clamped total IS the surcharge, so
/// this only reads the analysis and decides whether the number can be vouched
/// for. Re-deriving prices here is exactly what broke #13/#22.
class DTicketQuote {
  /// Euro to pay on top of the Deutschlandticket. 0 = the ticket alone does it.
  final double surcharge;

  /// Every ticket of the cheapest combination is covered — nothing to buy.
  final bool fullyCovered;

  /// The plain through fare for the same connection, when the search knew one.
  /// null when the backend quoted no price: then there is nothing to compare
  /// the surcharge against, and no saving may be claimed.
  final double? directPrice;

  const DTicketQuote({
    required this.surcharge,
    required this.fullyCovered,
    this.directPrice,
  });

  /// What holding the D-Ticket (plus splitting) saves against buying the
  /// connection through. null when the through fare is unknown.
  double? get saving =>
      directPrice == null ? null : directPrice! - surcharge;

  /// The D-Ticket genuinely takes money off this connection (beyond a cent of
  /// rounding). False for a pure long-distance run, where the ticket is worth
  /// nothing and the rider should be told so rather than shown a fake win.
  bool get savesMoney {
    final s = saving;
    return s != null && s > 0.01;
  }

  String get surchargeFormatted => '${surcharge.toStringAsFixed(2)} €';
}

/// Read the surcharge out of a finished [result].
///
/// [deutschlandTicket] must say whether the analysis behind [result] actually
/// ran with the D-Ticket switched on — the flag is not recoverable from the
/// result, and a run without it prices covered segments at their full fare, so
/// its `splitPrice` is a total, never a surcharge.
///
/// Returns null when the surcharge cannot be established, and the caller must
/// then label it as unknown rather than guess. Three ways that happens:
///
///  * no result / not analysed with a D-Ticket — nothing to read,
///  * a non-finite total — no priceable combination was found,
///  * "free" without coverage — the engine falls back to the direct fare when a
///    split doesn't beat it, so a 0,00 € total on a route the D-Ticket does NOT
///    cover means the search quoted no fare at all. Reporting that as a free
///    trip would put the biggest lie at the top of a list sorted by price.
DTicketQuote? dTicketQuoteFrom(
  TicketAnalysisResult? result, {
  required bool deutschlandTicket,
}) {
  if (!deutschlandTicket || result == null) return null;

  final surcharge = result.splitPrice;
  if (surcharge.isNaN || surcharge.isInfinite || surcharge < 0) return null;

  final fullyCovered = result.tickets.isNotEmpty &&
      result.tickets.every((t) => t.coveredByDeutschlandTicket);
  if (surcharge < 0.005 && !fullyCovered) return null;

  return DTicketQuote(
    surcharge: surcharge,
    fullyCovered: fullyCovered,
    // A through fare of 0 is "unknown", not "free" — the search leaves it at 0
    // when the backend quotes nothing.
    directPrice: result.directPrice > 0 ? result.directPrice : null,
  );
}

/// Order [items] by what they cost on top of the Deutschlandticket, cheapest
/// first — the whole point of #28: a mostly-regional connection costs next to
/// nothing with a D-Ticket but sits far down a list sorted by total price.
///
/// Ties are broken by travel time (of two connections that both cost nothing,
/// the faster one is the better trip), then by the original order, so the sort
/// is stable — `List.sort` is not, and rows that reshuffle on every progress
/// tick while the analysis streams in are unusable.
///
/// Items with no established surcharge sort last, never first: an unknown price
/// must not masquerade as the best deal.
List<T> sortByDTicketSurcharge<T>(
  Iterable<T> items, {
  required DTicketQuote? Function(T item) quoteOf,
  required Duration Function(T item) durationOf,
}) {
  final list = items.toList();
  final indexed = [for (var i = 0; i < list.length; i++) (i, list[i])];

  indexed.sort((a, b) {
    final qa = quoteOf(a.$2);
    final qb = quoteOf(b.$2);
    if (qa == null || qb == null) {
      if (qa == null && qb == null) return a.$1.compareTo(b.$1);
      return qa == null ? 1 : -1;
    }
    // Compare in cents: fares are money, and 12.00 vs 12.004 is the same price
    // — letting the duration decide there beats an arbitrary float order.
    final byPrice = (qa.surcharge * 100).round().compareTo(
          (qb.surcharge * 100).round(),
        );
    if (byPrice != 0) return byPrice;
    final byDuration = durationOf(a.$2).compareTo(durationOf(b.$2));
    if (byDuration != 0) return byDuration;
    return a.$1.compareTo(b.$1);
  });

  return [for (final e in indexed) e.$2];
}
