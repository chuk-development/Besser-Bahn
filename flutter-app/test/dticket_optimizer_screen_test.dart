import 'package:besser_bahn/models/journey.dart';
import 'package:besser_bahn/models/split_ticket.dart';
import 'package:besser_bahn/models/station.dart';
import 'package:besser_bahn/providers/bulk_split_provider.dart';
import 'package:besser_bahn/screens/split_ticket/bulk_split_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Holds a finished comparison and prices nothing — the screen is under test,
/// not the engine.
class _FakeBulk extends BulkSplitNotifier {
  _FakeBulk(this.seed);
  final BulkSplitState seed;

  @override
  BulkSplitState build() => seed;

  @override
  Future<void> compare(List<Journey> journeys) async {}
}

SplitTicket _t(double price, {bool covered = false}) => SplitTicket(
      from: 'A',
      to: 'B',
      price: price,
      fromId: 'a',
      toId: 'b',
      departureIso: '2026-07-17T10:00:00',
      coveredByDeutschlandTicket: covered,
    );

BulkSplitRow _row(
  String label, {
  required double directPrice,
  required double splitPrice,
  required List<SplitTicket> tickets,
  Duration duration = const Duration(hours: 2),
}) =>
    BulkSplitRow(
      journey: Journey(legs: [
        JourneyLeg(
          origin: const Station(id: 'a', name: 'A'),
          destination: const Station(id: 'b', name: 'B'),
        ),
      ]),
      label: label,
      duration: duration,
      transfers: 1,
      trains: 'RE + ICE',
      directPrice: directPrice,
      splitPrice: splitPrice,
      status: BulkRowStatus.done,
      result: TicketAnalysisResult(
        directPrice: directPrice,
        splitPrice: splitPrice,
        tickets: tickets,
      ),
    );

/// The dearest connection by total price (71 €) — and the cheapest by
/// surcharge (12.90 €). The case #28 exists for.
final _mostlyRegional = _row(
  '08:00 – 12:00',
  directPrice: 71.0,
  splitPrice: 12.9,
  tickets: [_t(0, covered: true), _t(12.9), _t(0, covered: true)],
  duration: const Duration(hours: 4),
);

/// Cheapest total (59.90 €), dearest surcharge — the D-Ticket buys nothing.
final _pureIce = _row(
  '09:00 – 11:00',
  directPrice: 59.9,
  splitPrice: 59.9,
  tickets: [_t(59.9)],
);

BulkSplitState _state({required bool deutschlandTicket}) => BulkSplitState(
      total: 2,
      doneCount: 2,
      rows: [_pureIce, _mostlyRegional],
      deutschlandTicket: deutschlandTicket,
    );

Future<void> _pump(
  WidgetTester tester,
  BulkSplitState state, {
  bool dTicketMode = true,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [bulkSplitProvider.overrideWith(() => _FakeBulk(state))],
      child: MaterialApp(
        home: BulkSplitScreen(journeys: const [], dTicketMode: dTicketMode),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// A bare row label ("08:00 – 12:00"). Anchored, so the headline card — which
/// reads "08:00 – 12:00  ·  12.90 €" — can't be mistaken for a row.
final _rowLabel = RegExp(r'^\d{2}:\d{2} – \d{2}:\d{2}$');

/// Which departure is drawn first — the ordering is the feature.
String _firstLabel(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text))
    .map((t) => t.data)
    .whereType<String>()
    .firstWhere(_rowLabel.hasMatch);

void main() {
  group('D-Ticket-Optimierer surfaces the surcharge (#28)', () {
    testWidgets('the mostly-regional connection is put first, ahead of the ICE',
        (tester) async {
      await _pump(tester, _state(deutschlandTicket: true));

      expect(find.text('D-Ticket-Optimierer'), findsOneWidget);
      // 12.90 € surcharge beats 59.90 € — even though its TOTAL (71 €) is the
      // dearest of the two and normal price sorting buries it.
      expect(_firstLabel(tester), '08:00 – 12:00');
      expect(find.text('+12.90 €'), findsOneWidget);
      expect(find.text('D-Ticket spart −58.10 €'), findsOneWidget);
    });

    testWidgets('a pure ICE run is told it gains nothing, not sold a saving',
        (tester) async {
      await _pump(tester, _state(deutschlandTicket: true));

      expect(find.text('+59.90 €'), findsOneWidget);
      expect(find.text('D-Ticket bringt hier nichts'), findsOneWidget);
    });

    testWidgets('switching to Gesamtpreis restores total-price ordering',
        (tester) async {
      await _pump(tester, _state(deutschlandTicket: true));
      await tester.tap(find.text('Gesamtpreis'));
      await tester.pumpAndSettle();

      expect(find.text('Preisvergleich'), findsOneWidget);
      // Back to the search's own order, and back to totals.
      expect(_firstLabel(tester), '09:00 – 11:00');
      expect(find.text('+12.90 €'), findsNothing);
    });

    testWidgets(
        'without a D-Ticket the mode is neither offered nor silently applied',
        (tester) async {
      // Same rows, but the run priced WITHOUT a D-Ticket: its splitPrice is a
      // total, so nothing here may be labelled a surcharge (#28, point 5).
      await _pump(tester, _state(deutschlandTicket: false));

      expect(find.text('Zuzahlung'), findsNothing);
      expect(find.text('D-Ticket-Optimierer'), findsNothing);
      expect(find.text('Preisvergleich'), findsOneWidget);
      expect(find.text('+12.90 €'), findsNothing);
      expect(_firstLabel(tester), '09:00 – 11:00');
    });
  });
}
