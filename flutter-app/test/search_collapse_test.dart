import 'package:besser_bahn/models/journey.dart';
import 'package:besser_bahn/models/journey_prediction.dart';
import 'package:besser_bahn/models/search_options.dart';
import 'package:besser_bahn/models/station.dart';
import 'package:besser_bahn/providers/journey_search_provider.dart';
import 'package:besser_bahn/providers/service_providers.dart';
import 'package:besser_bahn/screens/connection_search/connection_search_screen.dart';
import 'package:besser_bahn/services/hafas_service.dart';
import 'package:besser_bahn/services/prediction_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _kiel =
    Station(id: '8000199', name: 'Kiel Hbf', locationId: 'A=1@L=8000199@');
const _muenchen =
    Station(id: '8000261', name: 'München Hbf', locationId: 'A=1@L=8000261@');

Journey _journey(DateTime departure) => Journey(
      legs: [
        JourneyLeg(
          origin: _kiel,
          destination: _muenchen,
          departure: departure,
          plannedDeparture: departure,
          arrival: departure.add(const Duration(hours: 9)),
          plannedArrival: departure.add(const Duration(hours: 9)),
        ),
      ],
    );

JourneyResult _results() => JourneyResult(
      journeys: [_journey(DateTime.now().add(const Duration(hours: 1)))],
    );

/// The screen is under test, not the delay model — no call to bahn.chuk.dev.
class _NoPredictions extends PredictionService {
  @override
  Future<JourneyPrediction?> predict(Journey journey) async => null;
}

/// The station dropdown must not reach for the network if a field is touched.
class _NoStations extends HafasService {
  @override
  Future<List<Station>> searchStations(String query) async => [];
}

/// Lands a canned result exactly the way the real notifier does — serial
/// bumped, loading off — so the form's fold rule is exercised through the real
/// state transition rather than by poking a bool.
class _FakeSearch extends JourneySearchNotifier {
  _FakeSearch(this.seed, {this.landing, this.failure});

  final JourneySearchState seed;
  final JourneyResult? landing;
  final String? failure;

  @override
  JourneySearchState build() => seed;

  @override
  Future<void> search({String? fromText, String? toText}) async {
    if (failure != null) {
      state = state.copyWith(error: failure, isLoading: false);
      return;
    }
    state = state.copyWith(
      result: landing ?? _results(),
      isLoading: false,
      resultSerial: state.resultSerial + 1,
    );
  }

  /// The spinning-button half of a search, without ever finishing it.
  void pretendLoading({bool loading = true}) {
    state = state.copyWith(isLoading: loading);
  }

  /// Appending a page replaces `result` but must NOT bump the serial — this is
  /// the case that separates "a search landed" from "the list grew".
  Future<void> pretendPaging() async {
    state = state.copyWith(
      result: JourneyResult(journeys: [
        ...?state.result?.journeys,
        _journey(DateTime.now().add(const Duration(hours: 3))),
      ]),
    );
  }
}

JourneySearchState _seed({
  JourneyResult? result,
  DateTime? dateTime,
  SearchOptions options = const SearchOptions(),
}) =>
    JourneySearchState(
      from: _kiel,
      to: _muenchen,
      result: result,
      dateTime: dateTime,
      options: options,
    );

Future<_FakeSearch> _pump(
  WidgetTester tester,
  JourneySearchState seed, {
  JourneyResult? landing,
  String? failure,
  Size size = const Size(400, 800),
}) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final notifier = _FakeSearch(seed, landing: landing, failure: failure);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        journeySearchProvider.overrideWith(() => notifier),
        predictionServiceProvider.overrideWithValue(_NoPredictions()),
        hafasServiceProvider.overrideWithValue(_NoStations()),
      ],
      child: const MaterialApp(home: ConnectionSearchScreen()),
    ),
  );
  await tester.pumpAndSettle();
  return notifier;
}

/// Whether the form is folded. Read off the widget that drives the animation —
/// finders can't tell: [AnimatedCrossFade] keeps BOTH children mounted, which
/// is precisely how the text fields survive the fold.
CrossFadeState _fold(WidgetTester tester) =>
    tester.widget<AnimatedCrossFade>(find.byType(AnimatedCrossFade))
        .crossFadeState;

/// What the rider actually gets: the height the form occupies on screen.
double _formHeight(WidgetTester tester) =>
    tester.getSize(find.byType(AnimatedCrossFade)).height;

/// The Von/Nach field contents, straight from the controllers behind them.
List<String> _fieldTexts(WidgetTester tester) => tester
    .widgetList<EditableText>(find.byType(EditableText))
    .map((e) => e.controller.text)
    .toList();

Future<void> _tapSearch(WidgetTester tester) async {
  await tester.tap(find.byType(FilledButton));
  await tester.pumpAndSettle();
}

void main() {
  group('the search form folds away once results are in', () {
    testWidgets('results shrink it to the summary line', (tester) async {
      await _pump(tester, _seed());

      expect(_fold(tester), CrossFadeState.showFirst);
      final expanded = _formHeight(tester);
      expect(expanded, greaterThan(150));

      await _tapSearch(tester);

      expect(_fold(tester), CrossFadeState.showSecond);
      // The point of the whole exercise: the space goes to the results.
      expect(_formHeight(tester), lessThan(expanded / 2));
      expect(find.text('Kiel Hbf → München Hbf'), findsOneWidget);
      expect(find.text('Jetzt · 1 Reisende·r · 2. Kl.'), findsOneWidget);
    });

    testWidgets('tapping the summary opens it again', (tester) async {
      await _pump(tester, _seed());
      await _tapSearch(tester);
      final collapsed = _formHeight(tester);

      await tester.tap(find.text('Kiel Hbf → München Hbf'));
      await tester.pumpAndSettle();

      expect(_fold(tester), CrossFadeState.showFirst);
      expect(_formHeight(tester), greaterThan(collapsed * 2));
    });

    testWidgets('the inputs survive folding and unfolding', (tester) async {
      final when = DateTime.now().add(const Duration(days: 1, hours: 2));
      const options = SearchOptions(maxTransfers: 1);
      await _pump(tester, _seed(dateTime: when, options: options));

      expect(_fieldTexts(tester), ['Kiel Hbf', 'München Hbf']);

      await _tapSearch(tester);
      // Folded: the fields are still mounted and still carry their text — the
      // fold may not quietly reset what the rider typed.
      expect(_fieldTexts(tester), ['Kiel Hbf', 'München Hbf']);
      // The options button only lives in the form, so the folded line has to
      // admit that options are narrowing the result.
      expect(
        find.descendant(
          of: find.byTooltip('Suche ändern'),
          matching: find.byIcon(Icons.tune),
        ),
        findsOneWidget,
      );

      await tester.tap(find.text('Kiel Hbf → München Hbf'));
      await tester.pumpAndSettle();

      expect(_fold(tester), CrossFadeState.showFirst);
      expect(_fieldTexts(tester), ['Kiel Hbf', 'München Hbf']);
      // The date is still the one that was searched with, not reset to "Jetzt".
      expect(
          find.text(DateFormat('dd.MM. HH:mm').format(when)), findsOneWidget);
      expect(find.text('Jetzt'), findsNothing);
    });

    testWidgets('the summary names the day and the arrival search',
        (tester) async {
      final tomorrow = DateTime.now().add(const Duration(days: 1));
      final when =
          DateTime(tomorrow.year, tomorrow.month, tomorrow.day, 20, 37);
      await _pump(
        tester,
        JourneySearchState(
          from: _kiel,
          to: _muenchen,
          dateTime: when,
          isArrival: true,
        ),
      );
      await _tapSearch(tester);

      expect(
        find.text('An Morgen 20:37 · 1 Reisende·r · 2. Kl.'),
        findsOneWidget,
      );
    });
  });

  group('what must NOT fold the form away', () {
    testWidgets('loading alone leaves it open', (tester) async {
      final notifier = await _pump(tester, _seed());

      notifier.pretendLoading();
      // Not pumpAndSettle: the search button's spinner never stops.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(_fold(tester), CrossFadeState.showFirst);
      expect(_formHeight(tester), greaterThan(150));

      notifier.pretendLoading(loading: false);
      await tester.pumpAndSettle();
    });

    testWidgets('an empty result keeps the form there to widen the search',
        (tester) async {
      await _pump(tester, _seed(),
          landing: const JourneyResult(journeys: []));
      await _tapSearch(tester);

      // Folding here would hide the only thing that fixes "keine Verbindungen".
      expect(_fold(tester), CrossFadeState.showFirst);
    });

    testWidgets('a failed search leaves the form there too', (tester) async {
      await _pump(tester, _seed(), failure: 'Fehler: kaputt');
      await _tapSearch(tester);

      expect(_fold(tester), CrossFadeState.showFirst);
    });

    testWidgets('paging the list does not fold a reopened form',
        (tester) async {
      final notifier = await _pump(tester, _seed());
      await _tapSearch(tester);
      expect(_fold(tester), CrossFadeState.showSecond);

      // Rider opens the form on purpose, then hits "Später".
      await tester.tap(find.text('Kiel Hbf → München Hbf'));
      await tester.pumpAndSettle();
      await notifier.pretendPaging();
      await tester.pumpAndSettle();

      expect(_fold(tester), CrossFadeState.showFirst);
    });
  });

  group('the summary line survives narrow screens', () {
    testWidgets('long station names clip instead of overflowing',
        (tester) async {
      await _pump(
        tester,
        JourneySearchState(
          from: const Station(
            id: '1',
            name: 'Berlin Brandenburg Flughafen Terminal 1-2 (BER)',
          ),
          to: const Station(
            id: '2',
            name: 'Frankfurt (Main) Flughafen Regionalbahnhof',
          ),
          dateTime: DateTime.now(),
        ),
        size: const Size(320, 640),
      );
      await _tapSearch(tester);

      expect(_fold(tester), CrossFadeState.showSecond);
      // A RenderFlex overflow throws in tests — 3 px is enough (see the
      // "stop the 3 px overflow" fix).
      expect(tester.takeException(), isNull);
    });

    testWidgets('no overflow while the height is mid-animation',
        (tester) async {
      await _pump(tester, _seed(), size: const Size(320, 640));
      await tester.tap(find.byType(FilledButton));
      // Step through the fold instead of settling past it: the shrinking box
      // is exactly where an overflow would flash up.
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 45));
        expect(tester.takeException(), isNull);
      }
      await tester.pumpAndSettle();
      expect(_fold(tester), CrossFadeState.showSecond);
    });
  });
}
