import 'package:besser_bahn/models/station.dart';
import 'package:besser_bahn/models/trip.dart';
import 'package:besser_bahn/screens/train_lookup/widgets/stop_timeline.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Long enough to wrap on any phone-width timeline.
const _longName = 'Frankfurt (Main) Flughafen Fernbahnhof';
const _shortName = 'Kiel Hbf';

Stopover _stop(String name, DateTime at) => Stopover(
      stop: Station(id: name.hashCode.toString(), name: name),
      plannedArrival: at,
      arrival: at,
      plannedDeparture: at,
      departure: at,
    );

Future<void> _pump(WidgetTester tester, double width) async {
  final t = DateTime(2026, 8, 1, 10);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: width,
        child: SingleChildScrollView(
          child: StopTimeline(
            stopovers: [
              _stop(_shortName, t),
              _stop(_longName, t.add(const Duration(minutes: 30))),
            ],
          ),
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  group('#57 — a stop name that needs two lines is fully rendered', () {
    testWidgets('the row grows instead of clipping the second line',
        (tester) async {
      // A narrow phone: the long name cannot fit on one line.
      tester.view.physicalSize = const Size(360 * 3, 800 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await _pump(tester, 320);

      final short = tester.getSize(find.text(_shortName));
      final long = tester.getSize(find.text(_longName));

      expect(long.height, greaterThan(short.height),
          reason: 'the two-line name must actually get a second line');
      // The name row used to be a hard 26px SizedBox: the second line was laid
      // out and then clipped to a sliver of its first pixel row.
      expect(long.height, greaterThan(26),
          reason: 'a name taller than the old fixed row would be cut off');
    });

    testWidgets('a name that fits keeps the row at its usual height',
        (tester) async {
      await _pump(tester, 700);
      expect(tester.getSize(find.text(_shortName)).height, lessThan(26));
    });
  });
}
