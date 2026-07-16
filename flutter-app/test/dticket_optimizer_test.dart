import 'package:besser_bahn/models/split_ticket.dart';
import 'package:besser_bahn/utils/dticket_optimizer.dart';
import 'package:flutter_test/flutter_test.dart';

SplitTicket _t(double price, {bool covered = false}) => SplitTicket(
      from: 'A',
      to: 'B',
      price: price,
      fromId: 'a',
      toId: 'b',
      departureIso: '2026-07-17T10:00:00',
      coveredByDeutschlandTicket: covered,
    );

/// A finished analysis, as SplitEngine hands it over.
TicketAnalysisResult _res({
  required double directPrice,
  required double splitPrice,
  required List<SplitTicket> tickets,
}) =>
    TicketAnalysisResult(
      directPrice: directPrice,
      splitPrice: splitPrice,
      tickets: tickets,
    );

/// A mostly-regional run: D-Ticket to the ICE, buy only the long-distance bit.
final _mostlyRegional = _res(
  directPrice: 71.0,
  splitPrice: 12.9,
  tickets: [_t(0, covered: true), _t(12.9), _t(0, covered: true)],
);

/// Pure ICE — the D-Ticket buys nothing, the through fare stands.
final _pureIce = _res(
  directPrice: 59.9,
  splitPrice: 59.9,
  tickets: [_t(59.9)],
);

/// All regional: no ticket to buy at all.
final _allCovered = _res(
  directPrice: 28.4,
  splitPrice: 0.0,
  tickets: [_t(0, covered: true)],
);

void main() {
  group('the surcharge is read off the engine, never re-derived (#28)', () {
    test('a mostly-regional run costs only its long-distance leg', () {
      final q = dTicketQuoteFrom(_mostlyRegional, deutschlandTicket: true)!;

      expect(q.surcharge, 12.9);
      expect(q.fullyCovered, isFalse);
      expect(q.saving, closeTo(58.1, 0.001));
      expect(q.savesMoney, isTrue,
          reason: 'this is exactly the case #28 exists for');
    });

    test('an all-regional run needs no ticket at all', () {
      final q = dTicketQuoteFrom(_allCovered, deutschlandTicket: true)!;

      expect(q.surcharge, 0);
      expect(q.fullyCovered, isTrue);
      expect(q.savesMoney, isTrue);
    });

    test('a pure ICE run is quoted, but promises no saving', () {
      final q = dTicketQuoteFrom(_pureIce, deutschlandTicket: true)!;

      expect(q.surcharge, 59.9);
      expect(q.fullyCovered, isFalse);
      expect(q.savesMoney, isFalse,
          reason: 'the D-Ticket is worth nothing here and must not claim to be');
    });
  });

  group('what is NOT labelled (#28)', () {
    test('a run priced without a D-Ticket yields no surcharge', () {
      // Its splitPrice is a TOTAL — covered segments were charged in full.
      // Reading it as a surcharge would understate every long-distance fare.
      expect(dTicketQuoteFrom(_mostlyRegional, deutschlandTicket: false),
          isNull);
    });

    test('nothing analysed yet, nothing to say', () {
      expect(dTicketQuoteFrom(null, deutschlandTicket: true), isNull);
    });

    test('REGRESSION: free-but-not-covered is a missing price, not a bargain',
        () {
      // The engine falls back to the direct fare when no split wins; a search
      // that quoted no fare leaves that at 0. Labelling this "0,00 €" would
      // sort the one connection we know least about straight to the top.
      final noPrice = _res(
        directPrice: 0,
        splitPrice: 0,
        tickets: [_t(0)],
      );

      expect(dTicketQuoteFrom(noPrice, deutschlandTicket: true), isNull);
    });

    test('an unpriceable combination is not a surcharge', () {
      final broken = _res(
        directPrice: 0,
        splitPrice: double.infinity,
        tickets: [_t(0)],
      );

      expect(dTicketQuoteFrom(broken, deutschlandTicket: true), isNull);
    });

    test('a through fare of 0 means "unknown", so no saving is claimed', () {
      final covered = _res(
        directPrice: 0, // backend quoted nothing
        splitPrice: 0,
        tickets: [_t(0, covered: true)],
      );
      final q = dTicketQuoteFrom(covered, deutschlandTicket: true)!;

      expect(q.surcharge, 0);
      expect(q.fullyCovered, isTrue,
          reason: 'coverage is decided from the trains, not from a fare');
      expect(q.directPrice, isNull);
      expect(q.saving, isNull);
      expect(q.savesMoney, isFalse);
    });
  });

  group('ordering by surcharge instead of total price (#28)', () {
    // The point of the issue: the mostly-regional connection is the DEAREST by
    // total price (71 €) and the cheapest by surcharge (12.90 €).
    final rows = [
      (name: 'ice', quote: dTicketQuoteFrom(_pureIce, deutschlandTicket: true), dur: const Duration(hours: 2)),
      (name: 'regional', quote: dTicketQuoteFrom(_mostlyRegional, deutschlandTicket: true), dur: const Duration(hours: 4)),
      (name: 'covered', quote: dTicketQuoteFrom(_allCovered, deutschlandTicket: true), dur: const Duration(hours: 5)),
    ];

    List<String> order(List<dynamic> items) => [
          for (final r in sortByDTicketSurcharge(
            items,
            quoteOf: (r) => r.quote as DTicketQuote?,
            durationOf: (r) => r.dur as Duration,
          ))
            r.name as String
        ];

    test('the connection the D-Ticket carries comes first, the ICE last', () {
      expect(order(rows), ['covered', 'regional', 'ice']);
    });

    test('a slow, mostly-regional trip beats a fast ICE on surcharge', () {
      // 4 h for 12.90 € ranks above 2 h for 59.90 € — sorting by price, not
      // by time, is the whole request.
      expect(order(rows).indexOf('regional'), lessThan(order(rows).indexOf('ice')));
    });

    test('rows with no established surcharge sort last, never first', () {
      final withUnknown = [
        (name: 'unknown', quote: null, dur: const Duration(hours: 1)),
        ...rows,
      ];

      expect(order(withUnknown).last, 'unknown');
    });

    test('equal surcharges are broken by travel time', () {
      final tie = [
        (name: 'slow', quote: dTicketQuoteFrom(_allCovered, deutschlandTicket: true), dur: const Duration(hours: 5)),
        (name: 'fast', quote: dTicketQuoteFrom(_allCovered, deutschlandTicket: true), dur: const Duration(hours: 2)),
      ];

      expect(order(tie), ['fast', 'slow'],
          reason: 'of two free trips the quicker one is the better one');
    });

    test('the sort is stable, so streaming rows do not reshuffle', () {
      // Same surcharge AND same duration: original order must survive, or the
      // list jumps around while the analyses land one by one.
      final same = [
        for (final n in ['a', 'b', 'c', 'd'])
          (name: n, quote: dTicketQuoteFrom(_allCovered, deutschlandTicket: true), dur: const Duration(hours: 2)),
      ];

      expect(order(same), ['a', 'b', 'c', 'd']);
    });

    test('an empty list stays empty', () {
      expect(order([]), isEmpty);
    });
  });
}
