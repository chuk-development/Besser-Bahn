import 'package:besser_bahn/models/coach_sequence.dart';
import 'package:besser_bahn/screens/train_lookup/widgets/platform_track_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// #100 — a car the train carries but does not open stays invisible.
///
/// The DB Navigator draws such a car with a red ✗ and lists "Nicht verfügbarer
/// Wagen" in its legend. We only greyed it out — and our grey sits right next
/// to the graphite Triebkopf grey, so the rider read the defective car as the
/// locomotive and learned nothing. The payload already says `status: CLOSED`;
/// the gap was purely in what we drew.
CoachSequence _sequence({required List<bool> open}) {
  const carLen = 26.8;
  final vehicles = <Map<String, dynamic>>[];
  for (var i = 0; i < open.length; i++) {
    final start = i * carLen;
    vehicles.add({
      'wagonIdentificationNumber': i + 1,
      'vehicleID': 'v$i',
      'orientation': 'FORWARDS',
      'status': open[i] ? 'OPEN' : 'CLOSED',
      'type': {
        'category': 'PASSENGER_CARRIAGE',
        'constructionType': 'B',
        'hasFirstClass': false,
        'hasEconomyClass': true,
      },
      'platformPosition': {
        'start': start,
        'end': start + carLen,
        'sector': 'A',
      },
      'amenities': const [],
    });
  }
  return CoachSequence.fromJson({
    'journeyID': 'j1',
    'departurePlatform': '7',
    'departurePlatformSchedule': '7',
    'sequenceStatus': 'PLANNED',
    'platform': {
      'name': '7',
      'start': 0,
      'end': open.length * carLen,
      'sectors': [
        {'name': 'A', 'start': 0, 'end': open.length * carLen},
      ],
    },
    'groups': [
      {
        'name': 'G1',
        'transport': {
          'category': 'RE',
          'number': 1,
          'type': 'REGIONAL_TRAIN',
          'destination': {'name': 'Rostock Hbf'},
        },
        'vehicles': vehicles,
      },
    ],
  });
}

Widget _host(CoachSequence seq) => MaterialApp(
  home: Scaffold(
    body: SizedBox(
      width: 900,
      child: PlatformTrackView(sequence: seq, carHeight: 64),
    ),
  ),
);

void main() {
  testWidgets('a closed car carries the red ✗, an open one does not', (
    tester,
  ) async {
    await tester.pumpWidget(_host(_sequence(open: [true, false, true])));

    expect(
      find.byIcon(Icons.close_rounded),
      findsOneWidget,
      reason: 'exactly the one closed car is marked',
    );
  });

  testWidgets('a train with every car open stays unmarked', (tester) async {
    await tester.pumpWidget(_host(_sequence(open: [true, true, true])));

    expect(find.byIcon(Icons.close_rounded), findsNothing);
  });

  testWidgets('the closed car says why in its tooltip', (tester) async {
    await tester.pumpWidget(_host(_sequence(open: [true, false, true])));

    final tips = tester
        .widgetList<Tooltip>(find.byType(Tooltip))
        .map((t) => t.message ?? '')
        .toList();
    expect(
      tips.where((m) => m.contains('Nicht verfügbar')),
      hasLength(1),
      reason: 'the wording matches DB\'s "Nicht verfügbarer Wagen"',
    );
  });
}
