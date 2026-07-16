import 'package:besser_bahn/models/departure.dart';
import 'package:besser_bahn/models/journey.dart';
import 'package:besser_bahn/models/station.dart';
import 'package:besser_bahn/models/transfer_profile.dart';
import 'package:besser_bahn/utils/earlier_alight.dart';
import 'package:flutter_test/flutter_test.dart';

/// Rescue option B (#26): get off earlier, go another way.
///
/// The scenario throughout: an ICE Hamburg → Frankfurt, planned change in
/// Frankfurt onto a train to Stuttgart. The ICE is late, the change is at
/// risk. Fulda and Kassel are earlier stops it hasn't reached yet.

Station _st(String id, String name) =>
    Station(id: id, name: name, locationId: 'A=1@L=$id@');

DateTime _at(int h, int m) => DateTime(2026, 7, 16, h, m);

JourneyLeg _train({
  required Station from,
  required Station to,
  required DateTime dep,
  required DateTime arr,
  String tripId = 'trip-1',
  String product = 'nationalExpress',
  String name = 'ICE 599',
  List<LegStopover> stops = const [],
}) =>
    JourneyLeg(
      tripId: tripId,
      origin: from,
      destination: to,
      departure: dep,
      plannedDeparture: dep,
      arrival: arr,
      plannedArrival: arr,
      line: TransitLine(
          name: name, fahrtNr: '599', productName: 'ICE', product: product),
      stopovers: stops,
    );

Journey _journeyOf(List<JourneyLeg> legs) => Journey(legs: legs);

void main() {
  final hamburg = _st('8002549', 'Hamburg Hbf');
  final kassel = _st('8003200', 'Kassel-Wilhelmshöhe');
  final fulda = _st('8000085', 'Fulda');
  final frankfurt = _st('8000105', 'Frankfurt(Main)Hbf');
  final stuttgart = _st('8000096', 'Stuttgart Hbf');

  /// The ridden ICE's stops: boarded Hamburg, change planned in Frankfurt.
  List<AlightStop> ride({DateTime? kasselAt, DateTime? fuldaAt}) => [
        AlightStop(station: hamburg, arrival: _at(9, 0)),
        AlightStop(station: kassel, arrival: kasselAt ?? _at(11, 0)),
        AlightStop(station: fulda, arrival: fuldaAt ?? _at(11, 40)),
        AlightStop(station: frankfurt, arrival: _at(12, 30)),
      ];

  group('pickEarlierAlightStops — which stops are worth a search', () {
    test('drops the boarding stop and the planned change station', () {
      final picked = pickEarlierAlightStops(stops: ride(), now: _at(10, 0));
      expect(picked.map((s) => s.station.name),
          ['Kassel-Wilhelmshöhe', 'Fulda']);
    });

    test('a stop the train already passed is not an option', () {
      // 11:30 — Kassel is behind us, only Fulda is still ahead.
      final picked = pickEarlierAlightStops(stops: ride(), now: _at(11, 30));
      expect(picked.map((s) => s.station.name), ['Fulda']);
    });

    test('no time to react — arriving inside the lead window is dropped', () {
      // Fulda in 2 minutes: you can't read a suggestion, pack and get off.
      final picked = pickEarlierAlightStops(stops: ride(), now: _at(11, 38));
      expect(picked, isEmpty);
    });

    test('judges reachability on the LIVE time, not the plan (#26)', () {
      // The ICE is 90 min down, so its "11:00" Kassel call really happens at
      // 12:30. At 11:30 the timetable says Kassel is gone; realtime says it's
      // still an hour away and perfectly reachable.
      final picked = pickEarlierAlightStops(
        stops: ride(kasselAt: _at(12, 30), fuldaAt: _at(13, 10)),
        now: _at(11, 30),
      );
      expect(picked.map((s) => s.station.name),
          ['Kassel-Wilhelmshöhe', 'Fulda']);
    });

    test("a stop you can't get out at is no rescue", () {
      final stops = [
        AlightStop(station: hamburg, arrival: _at(9, 0)),
        AlightStop(station: kassel, arrival: _at(11, 0), noAlighting: true),
        AlightStop(station: fulda, arrival: _at(11, 40), cancelled: true),
        AlightStop(station: frankfurt, arrival: _at(12, 30)),
      ];
      expect(pickEarlierAlightStops(stops: stops, now: _at(10, 0)), isEmpty);
    });

    test('a stop with no live time is skipped, not guessed', () {
      final stops = [
        AlightStop(station: hamburg, arrival: _at(9, 0)),
        const AlightStop(station: Station(id: '1', name: 'Göttingen')),
        AlightStop(station: fulda, arrival: _at(11, 40)),
        AlightStop(station: frankfurt, arrival: _at(12, 30)),
      ];
      expect(pickEarlierAlightStops(stops: stops, now: _at(10, 0))
          .map((s) => s.station.name),
          ['Fulda']);
    });

    test('the cap keeps the stops nearest the change, and caps the load', () {
      final stops = [
        AlightStop(station: hamburg, arrival: _at(9, 0)),
        for (var i = 0; i < 8; i++)
          AlightStop(station: _st('s$i', 'Halt $i'), arrival: _at(10, i * 5)),
        AlightStop(station: frankfurt, arrival: _at(12, 30)),
      ];
      final picked =
          pickEarlierAlightStops(stops: stops, now: _at(9, 30), cap: 3);
      expect(picked.length, 3);
      expect(picked.map((s) => s.station.name), ['Halt 5', 'Halt 6', 'Halt 7']);
    });

    test('a leg with no intermediate stop offers nothing', () {
      final stops = [
        AlightStop(station: hamburg, arrival: _at(9, 0)),
        AlightStop(station: frankfurt, arrival: _at(12, 30)),
      ];
      expect(pickEarlierAlightStops(stops: stops, now: _at(9, 30)), isEmpty);
    });
  });

  group('pickFallbackJourney — what "doing nothing" costs', () {
    final onward = _train(
        from: frankfurt,
        to: stuttgart,
        dep: _at(12, 35),
        arr: _at(14, 0),
        tripId: 'planned-onward');

    test('the train you were going to miss can never BE the fallback', () {
      // Otherwise the baseline becomes "you caught it after all" and nothing
      // could ever beat it — the exact connection we judged at risk.
      final best = pickFallbackJourney(
        journeys: [
          _journeyOf([onward]),
          _journeyOf([
            _train(
                from: frankfurt,
                to: stuttgart,
                dep: _at(13, 5),
                arr: _at(14, 30),
                tripId: 'next-one')
          ]),
        ],
        readyAt: _at(12, 33),
        plannedOnwardTripId: 'planned-onward',
      );
      expect(best?.arrival, _at(14, 30));
    });

    test('a train that leaves before you are off is not reachable', () {
      final best = pickFallbackJourney(
        journeys: [
          _journeyOf([
            _train(
                from: frankfurt, to: stuttgart, dep: _at(12, 40), arr: _at(14, 5),
                tripId: 'gone')
          ]),
          _journeyOf([
            _train(
                from: frankfurt, to: stuttgart, dep: _at(13, 5), arr: _at(14, 30),
                tripId: 'catchable')
          ]),
        ],
        readyAt: _at(13, 0),
        plannedOnwardTripId: 'planned-onward',
      );
      expect(best?.arrival, _at(14, 30));
    });

    test('nothing reachable → no baseline', () {
      expect(
          pickFallbackJourney(journeys: const [], readyAt: _at(13, 0)), isNull);
    });
  });

  group('evaluateAlightCandidate — is it actually a win?', () {
    final booked = _journeyOf([
      _train(from: hamburg, to: frankfurt, dep: _at(9, 0), arr: _at(12, 30)),
      _train(
          from: frankfurt,
          to: stuttgart,
          dep: _at(12, 35),
          arr: _at(14, 0),
          tripId: 'planned-onward'),
    ]);

    final fuldaStop = AlightStop(station: fulda, arrival: _at(11, 40));

    Journey onwardFromFulda({
      DateTime? dep,
      DateTime? arr,
      String tripId = 'via-wuerzburg',
      String product = 'nationalExpress',
    }) =>
        _journeyOf([
          _train(
              from: fulda,
              to: stuttgart,
              dep: dep ?? _at(11, 55),
              arr: arr ?? _at(13, 45),
              tripId: tripId,
              product: product)
        ]);

    test('the happy path: beats the fallback, so it is offered', () {
      final o = evaluateAlightCandidate(
        stop: fuldaStop,
        onward: onwardFromFulda(),
        original: booked,
        fallbackArrival: _at(14, 30),
        profile: TransferProfile.normal,
        hasDeutschlandTicket: false,
        currentTripId: 'trip-1',
      );
      expect(o, isNotNull);
      expect(o!.gainMinutes, 45); // 14:30 fallback vs 13:45
      expect(o.waitMinutes, 15);
      expect(o.stop.station.name, 'Fulda');
    });

    test('NOT earlier at the destination → never shown (#26)', () {
      // "Nur Vorschläge zeigen, die früher am Ziel sind … sonst ist es kein
      // Gewinn." Same arrival is not a gain either.
      expect(
        evaluateAlightCandidate(
          stop: fuldaStop,
          onward: onwardFromFulda(arr: _at(14, 45)),
          original: booked,
          fallbackArrival: _at(14, 30),
          profile: TransferProfile.normal,
          hasDeutschlandTicket: false,
        ),
        isNull,
      );
      expect(
        evaluateAlightCandidate(
          stop: fuldaStop,
          onward: onwardFromFulda(arr: _at(14, 30)),
          original: booked,
          fallbackArrival: _at(14, 30),
          profile: TransferProfile.normal,
          hasDeutschlandTicket: false,
        ),
        isNull,
      );
    });

    test('"stay on the train you are already on" is not getting off', () {
      expect(
        evaluateAlightCandidate(
          stop: fuldaStop,
          onward: onwardFromFulda(tripId: 'trip-1'),
          original: booked,
          fallbackArrival: _at(14, 30),
          profile: TransferProfile.normal,
          hasDeutschlandTicket: false,
          currentTripId: 'trip-1',
        ),
        isNull,
      );
    });

    test('a connection that leaves before you are off the train is rejected',
        () {
      expect(
        evaluateAlightCandidate(
          stop: fuldaStop,
          onward: onwardFromFulda(dep: _at(11, 35)),
          original: booked,
          fallbackArrival: _at(14, 30),
          profile: TransferProfile.normal,
          hasDeutschlandTicket: false,
        ),
        isNull,
      );
    });

    test('the rescue must be a change THIS rider can make (#11.7)', () {
      // 4 minutes: fine for "Normal", but "Barrierearm" (factor 1.8, floor 15)
      // would be told to sprint across a station it was told the rider can't.
      final tight = onwardFromFulda(dep: _at(11, 44));
      expect(
        evaluateAlightCandidate(
          stop: fuldaStop,
          onward: tight,
          original: booked,
          fallbackArrival: _at(14, 30),
          profile: TransferProfile.normal,
          hasDeutschlandTicket: false,
        ),
        isNotNull,
      );
      expect(
        evaluateAlightCandidate(
          stop: fuldaStop,
          onward: tight,
          original: booked,
          fallbackArrival: _at(14, 30),
          profile: TransferProfile.accessible,
          hasDeutschlandTicket: false,
        ),
        isNull,
      );
    });

    test('a 2-minute change is never offered, even to a fast rider', () {
      expect(
        evaluateAlightCandidate(
          stop: fuldaStop,
          onward: onwardFromFulda(dep: _at(11, 41)),
          original: booked,
          fallbackArrival: _at(14, 30),
          profile: TransferProfile.fast,
          hasDeutschlandTicket: false,
        ),
        isNull,
      );
    });
  });

  group('Zugbindung — the warning that must never be missing (#26)', () {
    final ice = _train(
        from: hamburg, to: frankfurt, dep: _at(9, 0), arr: _at(12, 30));
    final re = _train(
        from: hamburg,
        to: frankfurt,
        dep: _at(9, 0),
        arr: _at(12, 30),
        product: 'regional',
        name: 'RE 1');

    test('unknown fare → say it may be bound, do not stay silent', () {
      expect(
        ticketNoteFor(
          original: _journeyOf([ice]),
          onward: _journeyOf([re]),
          hasDeutschlandTicket: false,
        ),
        AlightTicketNote.mayBeTrainBound,
      );
    });

    test('D-Ticket rider on regional trains, regional rescue → free to do', () {
      expect(
        ticketNoteFor(
          original: _journeyOf([re]),
          onward: _journeyOf([re]),
          hasDeutschlandTicket: true,
        ),
        AlightTicketNote.dTicketCovered,
      );
    });

    test('a D-Ticket does not un-bind the Sparpreis on a booked ICE', () {
      // The pass is real but it isn't the ticket at risk — the separately
      // bought long-distance fare is, and that one IS train-bound.
      expect(
        ticketNoteFor(
          original: _journeyOf([ice]),
          onward: _journeyOf([re]),
          hasDeutschlandTicket: true,
        ),
        AlightTicketNote.mayBeTrainBound,
      );
    });

    test('D-Ticket rider sent onto an ICE needs to buy something', () {
      expect(
        ticketNoteFor(
          original: _journeyOf([re]),
          onward: _journeyOf([ice]),
          hasDeutschlandTicket: true,
        ),
        AlightTicketNote.dTicketNotCovered,
      );
    });

    test('every note carries text a rider can act on', () {
      for (final n in AlightTicketNote.values) {
        expect(n.label, isNotEmpty);
        expect(n.detail, isNotEmpty);
      }
      expect(AlightTicketNote.mayBeTrainBound.detail, contains('Sparpreis'));
    });

    test('an offered option always states its ticket note', () {
      final o = evaluateAlightCandidate(
        stop: AlightStop(station: fulda, arrival: _at(11, 40)),
        onward: _journeyOf([
          _train(
              from: fulda,
              to: stuttgart,
              dep: _at(11, 55),
              arr: _at(13, 45),
              tripId: 'x')
        ]),
        original: _journeyOf([ice]),
        fallbackArrival: _at(14, 30),
        profile: TransferProfile.normal,
        hasDeutschlandTicket: false,
      );
      expect(o!.ticketNote, AlightTicketNote.mayBeTrainBound);
    });
  });

  group('rankEarlierAlightOptions', () {
    EarlierAlightOption opt(DateTime arrival,
            {int transfers = 0, DateTime? alightAt}) =>
        EarlierAlightOption(
          stop: AlightStop(station: fulda, arrival: alightAt ?? _at(11, 40)),
          onward: _journeyOf([
            _train(from: fulda, to: stuttgart, dep: _at(11, 55), arr: arrival),
            if (transfers > 0)
              _train(
                  from: stuttgart,
                  to: stuttgart,
                  dep: arrival,
                  arr: arrival,
                  tripId: 't2'),
          ]),
          alightArrival: alightAt ?? _at(11, 40),
          waitMinutes: 15,
          arrival: arrival,
          gainMinutes: 30,
          ticketNote: AlightTicketNote.mayBeTrainBound,
        );

    test('earliest at the destination wins', () {
      final ranked = rankEarlierAlightOptions(
          [opt(_at(14, 0)), opt(_at(13, 30)), opt(_at(13, 45))]);
      expect(ranked.map((o) => o.arrival),
          [_at(13, 30), _at(13, 45), _at(14, 0)]);
    });

    test('same arrival → fewer changes wins', () {
      final ranked = rankEarlierAlightOptions(
          [opt(_at(13, 30), transfers: 1), opt(_at(13, 30))]);
      expect(ranked.first.onward.transfers, 0);
    });

    test('same arrival and changes → stay on the train longer', () {
      final ranked = rankEarlierAlightOptions([
        opt(_at(13, 30), alightAt: _at(11, 0)),
        opt(_at(13, 30), alightAt: _at(11, 40)),
      ]);
      expect(ranked.first.alightArrival, _at(11, 40));
    });
  });

  group('rerouteViaEarlierAlight — taking the suggestion', () {
    final stops = [
      LegStopover(stop: hamburg, departure: _at(9, 0)),
      LegStopover(stop: kassel, arrival: _at(11, 0), departure: _at(11, 2)),
      LegStopover(stop: fulda, arrival: _at(11, 40), departure: _at(11, 42)),
      LegStopover(stop: frankfurt, arrival: _at(12, 30)),
    ];
    final ridden = _train(
        from: hamburg,
        to: frankfurt,
        dep: _at(9, 0),
        arr: _at(12, 30),
        stops: stops);
    final plannedOnward = _train(
        from: frankfurt,
        to: stuttgart,
        dep: _at(12, 35),
        arr: _at(14, 0),
        tripId: 'planned-onward');
    final rescueLeg = _train(
        from: fulda,
        to: stuttgart,
        dep: _at(11, 55),
        arr: _at(13, 45),
        tripId: 'rescue');

    final option = EarlierAlightOption(
      stop: AlightStop(station: fulda, arrival: _at(11, 40)),
      onward: _journeyOf([rescueLeg]),
      alightArrival: _at(11, 40),
      waitMinutes: 15,
      arrival: _at(13, 45),
      gainMinutes: 45,
      ticketNote: AlightTicketNote.mayBeTrainBound,
    );

    test('cuts the ridden train short and grafts the new route on', () {
      final legs = rerouteViaEarlierAlight(
        legs: [ridden, plannedOnward],
        currentLegIndex: 0,
        option: option,
      );
      expect(legs, isNotNull);
      expect(legs!.length, 2);
      // The ICE now ends in Fulda, at the time we'd really be there.
      expect(legs[0].destination.name, 'Fulda');
      expect(legs[0].arrival, _at(11, 40));
      expect(legs[0].tripId, 'trip-1'); // same physical train
      // Its timeline stops where the rider does — no Frankfurt.
      expect(legs[0].stopovers.map((s) => s.stop.name),
          ['Hamburg Hbf', 'Kassel-Wilhelmshöhe', 'Fulda']);
      // The connection we were going to miss is gone, the rescue took over.
      expect(legs[1].tripId, 'rescue');
      expect(legs[1].destination.name, 'Stuttgart Hbf');
      expect(Journey(legs: legs).arrival, _at(13, 45));
    });

    test('legs before the ridden train are untouched', () {
      final feeder = _train(
          from: kassel,
          to: hamburg,
          dep: _at(8, 0),
          arr: _at(8, 50),
          tripId: 'feeder');
      final legs = rerouteViaEarlierAlight(
        legs: [feeder, ridden, plannedOnward],
        currentLegIndex: 1,
        option: option,
      );
      expect(legs!.first.tripId, 'feeder');
      expect(legs.length, 3);
    });

    test('an exit the train does not call at is refused, not invented', () {
      final bogus = EarlierAlightOption(
        stop: AlightStop(station: _st('9999', 'Hintertupfing'),
            arrival: _at(11, 40)),
        onward: _journeyOf([rescueLeg]),
        alightArrival: _at(11, 40),
        waitMinutes: 15,
        arrival: _at(13, 45),
        gainMinutes: 45,
        ticketNote: AlightTicketNote.mayBeTrainBound,
      );
      expect(
        rerouteViaEarlierAlight(
            legs: [ridden, plannedOnward], currentLegIndex: 0, option: bogus),
        isNull,
      );
    });

    test('an out-of-range leg index is refused', () {
      expect(
        rerouteViaEarlierAlight(
            legs: [ridden], currentLegIndex: 5, option: option),
        isNull,
      );
    });
  });
}
