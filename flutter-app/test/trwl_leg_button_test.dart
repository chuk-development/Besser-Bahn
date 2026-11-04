import 'package:besser_bahn/models/coach_sequence.dart';
import 'package:besser_bahn/models/departure.dart';
import 'package:besser_bahn/models/journey.dart';
import 'package:besser_bahn/models/station.dart';
import 'package:besser_bahn/models/trip.dart';
import 'package:besser_bahn/providers/service_providers.dart';
import 'package:besser_bahn/screens/connection_search/connection_detail_screen.dart';
import 'package:besser_bahn/services/coach_sequence_service.dart';
import 'package:besser_bahn/services/hafas_service.dart';
import 'package:besser_bahn/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// #108: after a Träwelling login the check-in symbol has to sit on the train
/// in the connection view. Saving the journey is a different path and only
/// checks in when that setting is on.

class _StubHafas extends HafasService {
  @override
  Future<Trip> getTrip(String tripId) async {
    final hamburg = Station(id: '8002549', name: 'Hamburg Hbf');
    final berlin = Station(id: '8011160', name: 'Berlin Hbf');
    final when = DateTime(2026, 7, 16, 10);
    return Trip(
      id: tripId,
      line: const TransitLine(
        name: 'ICE 599',
        fahrtNr: '599',
        productName: 'ICE',
        product: 'nationalExpress',
      ),
      direction: 'Berlin Hbf',
      origin: hamburg,
      destination: berlin,
      stopovers: [
        Stopover(stop: hamburg, departure: when, plannedDeparture: when),
        Stopover(
          stop: berlin,
          arrival: when.add(const Duration(hours: 2)),
          plannedArrival: when.add(const Duration(hours: 2)),
        ),
      ],
    );
  }
}

class _NoCoach extends CoachSequenceService {
  @override
  Future<CoachSequence?> getCoachSequenceForDeparture({
    required String category,
    required String trainNumber,
    required String stationEva,
    required DateTime? departureTime,
  }) async => null;
}

Journey _journey() {
  final hamburg = Station(id: '8002549', name: 'Hamburg Hbf');
  final berlin = Station(id: '8011160', name: 'Berlin Hbf');
  final dep = DateTime(2026, 7, 16, 10);
  final arr = dep.add(const Duration(hours: 2));
  return Journey(
    legs: [
      JourneyLeg(
        tripId: 'trip-108',
        origin: hamburg,
        destination: berlin,
        departure: dep,
        plannedDeparture: dep,
        arrival: arr,
        plannedArrival: arr,
        line: const TransitLine(
          name: 'ICE 599',
          fahrtNr: '599',
          productName: 'ICE',
          product: 'nationalExpress',
        ),
        stopovers: [
          LegStopover(stop: hamburg, departure: dep),
          LegStopover(stop: berlin, arrival: arr),
        ],
      ),
    ],
  );
}

void main() {
  testWidgets('connection view shows the Träwelling symbol on the train', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          hafasServiceProvider.overrideWithValue(_StubHafas()),
          coachSequenceServiceProvider.overrideWithValue(_NoCoach()),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: ConnectionDetailScreen(journey: _journey(), fromSearch: true),
        ),
      ),
    );
    // getTrip completes on the next frame. No pumpAndSettle: the leg keeps a
    // refresh timer while it is on screen.
    await tester.pump();
    await tester.pump();

    final symbol = find.byTooltip('In Träwelling einchecken');
    await tester.scrollUntilVisible(symbol, 300);
    expect(symbol, findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
}
