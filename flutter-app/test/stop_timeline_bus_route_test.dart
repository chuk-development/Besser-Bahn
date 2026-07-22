import 'package:besser_bahn/models/station.dart';
import 'package:besser_bahn/models/trip.dart';
import 'package:besser_bahn/screens/train_lookup/widgets/stop_timeline.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Stopover _stop(String name, String id, DateTime at) => Stopover(
      stop: Station(id: id, name: name),
      plannedArrival: at,
      arrival: at,
      plannedDeparture: at,
      departure: at,
    );

List<Stopover> _run(List<(String, String)> names) {
  final t = DateTime(2026, 8, 1, 10);
  return [
    for (var i = 0; i < names.length; i++)
      _stop(names[i].$1, names[i].$2, t.add(Duration(minutes: i * 2))),
  ];
}

/// A city bus that loops: it serves "Gravelottestraße" twice, near the start of
/// the run and again on the way back.
List<Stopover> _loopRun() => _run(const [
      ('Roskilder Weg', '1'),
      ('Gravelottestraße', '2'),
      ('Wilhelmplatz', '3'),
      ('Exerzierplatz', '4'),
      ('Kiel Hbf', '5'),
      ('Gravelottestraße', '2'),
    ]);

Future<void> _pump(
  WidgetTester tester,
  List<Stopover> stops, {
  String? board,
  String? alight,
}) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: StopTimeline(
          stopovers: stops,
          boardingId: board,
          alightingId: alight,
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  group('#56 — a bus leg never collapses to a single stop', () {
    testWidgets('on a loop line the exit is the stop AFTER boarding',
        (tester) async {
      // Ride the loop from Gravelottestraße back to Gravelottestraße. Matching
      // the exit from the top of the list found the boarding stop itself, and
      // the timeline rendered that one row with the whole route hidden behind
      // two collapse headers.
      await _pump(tester, _loopRun(), board: '2', alight: '2');
      expect(find.text('Gravelottestraße'), findsNWidgets(2),
          reason: 'both ends of the ride are the same stop, served twice');
      expect(find.textContaining('Zwischenhalte'), findsOneWidget,
          reason: 'the stops in between are a real ridden segment');
    });

    testWidgets('a segment that still collapses shows the whole route instead',
        (tester) async {
      // The run we got back ends at the boarding stop (a short or mismatched
      // run, e.g. a bus whose exit isn't in the returned halte): board ==
      // alight, which used to render one lonely row.
      await _pump(
        tester,
        _run(const [
          ('Roskilder Weg', '1'),
          ('Wilhelmplatz', '3'),
          ('Exerzierplatz', '4'),
          ('Kiel Hbf', '5'),
        ]),
        board: '5',
        alight: '9999',
      );
      for (final name in [
        'Roskilder Weg',
        'Wilhelmplatz',
        'Exerzierplatz',
        'Kiel Hbf',
      ]) {
        expect(find.text(name), findsWidgets,
            reason: '$name belongs to the route the rider is looking at');
      }
      expect(find.textContaining('Halte vorher'), findsNothing,
          reason: 'nothing left to hide once the whole run is shown');
    });

    testWidgets('a one-stop run still renders that stop', (tester) async {
      await _pump(tester, _run(const [('Wilhelmplatz', '3')]),
          board: '3', alight: '3');
      expect(find.text('Wilhelmplatz'), findsOneWidget);
    });
  });
}
