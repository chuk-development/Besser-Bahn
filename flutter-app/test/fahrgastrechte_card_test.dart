import 'package:besser_bahn/models/journey.dart';
import 'package:besser_bahn/models/station.dart';
import 'package:besser_bahn/widgets/fahrgastrechte_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final _base = DateTime(2026, 8, 1, 8);

Station _st(String n) => Station(id: n, name: n);

Journey _lateJourney({int delayMin = 75, double? price = 40}) => Journey(
      legs: [
        JourneyLeg(
          origin: _st('Kiel Hbf'),
          destination: _st('München Hbf'),
          plannedDeparture: _base,
          departure: _base,
          plannedArrival: _base.add(const Duration(hours: 6)),
          arrival: _base.add(Duration(hours: 6, minutes: delayMin)),
        ),
      ],
      price: price != null ? JourneyPrice(amount: price) : null,
    );

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  testWidgets('no card for an on-time journey', (tester) async {
    await tester.pumpWidget(_wrap(FahrgastrechteCard(journey: _lateJourney(delayMin: 10))));
    expect(find.text('Anspruch auf Entschädigung'), findsNothing);
  });

  testWidgets('an eligible late journey shows the claim and opens the assistant',
      (tester) async {
    await tester.pumpWidget(_wrap(FahrgastrechteCard(journey: _lateJourney())));
    expect(find.text('Anspruch auf Entschädigung'), findsOneWidget);
    expect(find.textContaining('75 Min Verspätung'), findsOneWidget);

    await tester.tap(find.text('Fahrgastrechte-Assistent'));
    await tester.pumpAndSettle();

    // The assistant opened, prefilled with the trip's delay and fare.
    expect(find.text('Verspätung am Ziel (Minuten)'), findsOneWidget);
    expect(find.widgetWithText(TextField, '75'), findsOneWidget);
    // 25 % of 40 € = 10 €, shown in the assistant's result line.
    expect(find.textContaining('Entschädigung: ≈ 10.00 €'), findsOneWidget);
  });

  testWidgets('switching to Deutschlandticket shows the statutory pauschale',
      (tester) async {
    await tester.pumpWidget(_wrap(FahrgastrechteCard(journey: _lateJourney())));
    await tester.tap(find.text('Fahrgastrechte-Assistent'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Ticketart'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Deutschlandticket').last);
    await tester.pumpAndSettle();

    expect(find.textContaining('Pauschale laut Gesetz'), findsOneWidget);
    expect(find.textContaining('1.50 €'), findsOneWidget);
  });
}
