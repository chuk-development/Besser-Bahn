import 'package:besser_bahn/models/journey.dart';
import 'package:besser_bahn/models/split_ticket.dart';
import 'package:besser_bahn/models/station.dart';
import 'package:besser_bahn/providers/bulk_split_provider.dart';
import 'package:besser_bahn/providers/split_ticket_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _result = TicketAnalysisResult(
  directPrice: 71.0,
  splitPrice: 35.99,
  tickets: [
    SplitTicket(
      from: 'Berlin Hbf',
      to: 'Wolfsburg Hbf',
      price: 35.99,
      fromId: '8098160',
      toId: '8006552',
      departureIso: '2026-07-17T19:47:00',
    ),
    SplitTicket(
      from: 'Wolfsburg Hbf',
      to: 'Braunschweig Hbf',
      price: 0.0,
      fromId: '8006552',
      toId: '8000049',
      departureIso: '2026-07-17T20:31:00',
      coveredByDeutschlandTicket: true,
    ),
  ],
);

BulkSplitRow _row() => BulkSplitRow(
      journey: Journey(legs: [
        JourneyLeg(
          origin: const Station(id: '8098160', name: 'Berlin Hbf'),
          destination: const Station(id: '8000049', name: 'Braunschweig Hbf'),
        ),
      ]),
      label: '19:47 – 21:38',
      duration: const Duration(hours: 1, minutes: 51),
      transfers: 1,
      trains: 'ICE 842 + RE50',
      directPrice: 71.0,
    );

void main() {
  group('the price comparison keeps the tickets behind its numbers (#24)', () {
    test('a finished row carries the whole analysis, not just the price', () {
      final row = _row().copyWith(
        directPrice: _result.directPrice,
        splitPrice: _result.splitPrice,
        result: _result,
        status: BulkRowStatus.done,
      );

      expect(row.splitWins, isTrue);
      expect(row.result, isNotNull);
      expect(row.result!.tickets, hasLength(2));
      expect(row.result!.tickets.last.coveredByDeutschlandTicket, isTrue);
    });

    test('the result survives a later copyWith', () {
      final row = _row().copyWith(result: _result, status: BulkRowStatus.done);
      expect(row.copyWith(status: BulkRowStatus.done).result, same(_result));
    });

    test('a pending row has nothing to show yet', () {
      expect(_row().result, isNull);
      expect(_row().status, BulkRowStatus.pending);
    });
  });

  group('showResult hands a finished analysis to the detail screen (#24)', () {
    test('the result shows without re-running anything', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      container.read(splitTicketProvider.notifier).showResult(
            _result,
            routeLabel: 'Berlin Hbf → Braunschweig Hbf',
          );

      final state = container.read(splitTicketProvider);
      expect(state.isLoading, isFalse);
      expect(state.result, same(_result));
      expect(state.routeLabel, 'Berlin Hbf → Braunschweig Hbf');
      // No progress: nothing was priced, the numbers came in finished.
      expect(state.progress, isNull);
    });
  });
}
