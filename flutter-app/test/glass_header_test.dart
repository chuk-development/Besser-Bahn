import 'package:besser_bahn/models/journey.dart';
import 'package:besser_bahn/models/journey_prediction.dart';
import 'package:besser_bahn/models/station.dart';
import 'package:besser_bahn/providers/journey_search_provider.dart';
import 'package:besser_bahn/providers/service_providers.dart';
import 'package:besser_bahn/screens/connection_search/connection_search_screen.dart';
import 'package:besser_bahn/services/hafas_service.dart';
import 'package:besser_bahn/services/prediction_service.dart';
import 'package:besser_bahn/theme/app_theme.dart';
import 'package:besser_bahn/vendor/chuk_ui/chuk_glass.dart';
import 'package:besser_bahn/widgets/glass_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The Suche tab's chrome floats over the connections instead of sitting above
/// them: the search form, the saved routes and the Verkehrsmittel filter are
/// glass, and the list runs the full height of the body behind them.
///
/// What that buys has to be paid for in padding — these are the tests for the
/// bill.

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

/// Enough connections to make the list genuinely longer than the viewport —
/// otherwise "scrolls behind the glass" has nothing to scroll.
JourneyResult _results() => JourneyResult(
      journeys: [
        for (var i = 1; i <= 8; i++)
          _journey(DateTime.now().add(Duration(hours: i))),
      ],
    );

class _NoPredictions extends PredictionService {
  @override
  Future<JourneyPrediction?> predict(Journey journey) async => null;
}

/// The station dropdown, canned: the overlay it opens is the thing under test,
/// not where its rows come from.
class _OneStation extends HafasService {
  @override
  Future<List<Station>> searchStations(String query) async => const [
        Station(id: '8000105', name: 'Frankfurt (Main) Hbf'),
      ];
}

class _FakeSearch extends JourneySearchNotifier {
  _FakeSearch(this.seed);

  final JourneySearchState seed;

  @override
  JourneySearchState build() => seed;

  @override
  Future<void> search({String? fromText, String? toText}) async {
    state = state.copyWith(
      result: _results(),
      isLoading: false,
      resultSerial: state.resultSerial + 1,
    );
  }
}

Future<void> _pump(
  WidgetTester tester, {
  JourneyResult? result,
  Size size = const Size(400, 800),
  Brightness brightness = Brightness.dark,
}) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        journeySearchProvider.overrideWith(
          () => _FakeSearch(
            JourneySearchState(from: _kiel, to: _muenchen, result: result),
          ),
        ),
        predictionServiceProvider.overrideWithValue(_NoPredictions()),
        hafasServiceProvider.overrideWithValue(_OneStation()),
      ],
      child: MaterialApp(
        theme: brightness == Brightness.light ? AppTheme.light() : null,
        darkTheme: AppTheme.dark(),
        themeMode:
            brightness == Brightness.light ? ThemeMode.light : ThemeMode.dark,
        home: const ConnectionSearchScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// The results list. The only *vertical* list on the screen — the filter and
/// the saved routes scroll sideways.
Finder get _resultsList => find.byWidgetPredicate(
      (w) => w is ListView && w.scrollDirection == Axis.vertical,
    );

EdgeInsets _resultsPadding(WidgetTester tester) =>
    tester.widget<ListView>(_resultsList).padding! as EdgeInsets;

/// The bottom edge of the lowest piece of floating glass — everything the
/// header covers ends at or above this.
double _glassBottom(WidgetTester tester) =>
    tester.getRect(find.byType(GlassPanel).last).bottom;

Future<void> _search(WidgetTester tester) async {
  await tester.tap(find.byType(FilledButton));
  await tester.pumpAndSettle();
}

void main() {
  group('the header floats and the results run behind it', () {
    testWidgets('the list is full-height but starts below the glass',
        (tester) async {
      await _pump(tester, result: _results());

      // The form, the filter — both are glass, both are the same furniture as
      // the nav bar's pill.
      expect(find.byType(GlassPanel), findsNWidgets(2));

      final list = tester.getRect(_resultsList);
      final glassBottom = _glassBottom(tester);

      // The viewport really does reach up under the glass: if it stopped at the
      // header the cards could never appear behind it.
      expect(
        list.top,
        lessThan(glassBottom),
        reason: 'the list must run behind the header, not start after it',
      );
      // …and the first row still lands in the clear.
      expect(
        tester.getRect(find.text('Früher')).top,
        greaterThanOrEqualTo(glassBottom),
        reason: 'the first row may not sit under the glass',
      );
    });

    testWidgets('the padding is real space, not a guess at the glass',
        (tester) async {
      await _pump(tester, result: _results());

      final top = _resultsPadding(tester).top;
      final listTop = tester.getRect(_resultsList).top;

      expect(top, greaterThan(0));
      // The measured header, to the pixel: padding that only roughly matched
      // would either strand the first connection under the glass or leave a gap.
      expect(top, moreOrLessEquals(_glassBottom(tester) - listTop, epsilon: 8));
    });

    testWidgets('scrolling really does pull cards up behind the glass',
        (tester) async {
      await _pump(tester, result: _results());
      final glassBottom = _glassBottom(tester);

      await tester.drag(_resultsList, const Offset(0, -160));
      await tester.pumpAndSettle();

      // "Früher" is the list's first row. After scrolling it has gone up under
      // the header — it is still laid out (the viewport reaches up there), it is
      // simply behind the glass now.
      expect(tester.getRect(find.text('Früher')).top, lessThan(glassBottom));
      expect(tester.takeException(), isNull);
    });

    testWidgets('the hint before the first search clears the glass too',
        (tester) async {
      await _pump(tester);

      expect(find.byType(GlassPanel), findsOneWidget); // no filter yet
      expect(
        tester
            .getRect(find.text('Start und Ziel eingeben, um Verbindungen zu '
                'suchen.'))
            .top,
        greaterThan(_glassBottom(tester)),
      );
    });
  });

  group('the glass is glass', () {
    testWidgets('every panel is translucent and blurred, in both themes',
        (tester) async {
      for (final brightness in Brightness.values) {
        await _pump(tester, result: _results(), brightness: brightness);

        final panes = tester.widgetList<ChukGlass>(find.byType(ChukGlass));
        expect(panes, hasLength(2));
        for (final pane in panes) {
          // "Man muss durchgucken können": an opaque tint is just a card again.
          expect(pane.fill.a, lessThan(1.0), reason: '$brightness');
          // …but station names and chip labels sit on this, over *moving*
          // content. Thin enough to see through, thick enough to read on.
          expect(pane.fill.a, greaterThan(0.5), reason: '$brightness');
          // Without the blur it is a film, not glass — and the labels lose the
          // one thing that keeps them legible over a busy backdrop.
          expect(pane.blurSigma, greaterThan(0), reason: '$brightness');
        }
      }
    });
  });

  group('both states of the form leave the connections reachable', () {
    testWidgets('folding the form gives the freed space to the list',
        (tester) async {
      // Seeded with a result, so the list is there while the form is still
      // open — the fold only happens on a *fresh* search below.
      await _pump(tester, result: _results());
      final open = _resultsPadding(tester).top;

      await _search(tester);
      final folded = _resultsPadding(tester).top;

      // The fold is only worth anything if the list actually moves up into the
      // space — the padding is how it hears about it.
      expect(folded, lessThan(open));
      expect(
        tester.getRect(find.text('Früher')).top,
        greaterThanOrEqualTo(_glassBottom(tester)),
        reason: 'folded: the first row still has to clear the glass',
      );

      // And back: unfolding must push the list down again, or the form lands on
      // top of the connections.
      await tester.tap(find.text('Kiel Hbf → München Hbf'));
      await tester.pumpAndSettle();
      expect(_resultsPadding(tester).top, moreOrLessEquals(open, epsilon: 1));
      expect(
        tester.getRect(find.text('Früher')).top,
        greaterThanOrEqualTo(_glassBottom(tester)),
        reason: 'unfolded: the form may not cover the first row',
      );
    });

    testWidgets('no overflow while the header height animates', (tester) async {
      await _pump(tester, size: const Size(320, 640));
      await tester.tap(find.byType(FilledButton));

      // Step through the fold rather than settling past it: the header is
      // changing height *and* handing a new number to the list on every frame,
      // which is exactly where a stray 3 px would flash up (see the "stop the
      // 3 px overflow" fix).
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 45));
        expect(tester.takeException(), isNull);
      }
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('the filter chips survive a narrow screen', (tester) async {
      await _pump(tester, size: const Size(320, 640));
      await _search(tester);

      // Seven chips on a 320 px screen: the strip has to scroll, not overflow.
      expect(find.text('Fernverkehr'), findsOneWidget);
      await tester.drag(find.text('Fernverkehr'), const Offset(-120, 0));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  group('the glass does not swallow the inputs', () {
    testWidgets('the station dropdown opens over the header, not under it',
        (tester) async {
      await _pump(tester, result: _results());

      await tester.tap(find.byType(TextField).first);
      await tester.enterText(find.byType(TextField).first, 'Frankf');
      await tester.pumpAndSettle();

      // The dropdown is an OverlayEntry, so it renders above the whole Stack —
      // including the glass it is anchored to. If it ever moved into the panel
      // it would be blurred behind it, or clipped by the squircle.
      final row = find.text('Frankfurt (Main) Hbf');
      expect(row, findsOneWidget);
      expect(
        tester.getRect(row).top,
        greaterThan(0),
        reason: 'the dropdown must be on screen, not clipped away',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('the text fields keep their cursor and their text',
        (tester) async {
      await _pump(tester, result: _results());

      await tester.enterText(find.byType(TextField).first, 'Hamburg Hbf');
      await tester.pumpAndSettle();

      final field = tester.widget<EditableText>(find.byType(EditableText).first);
      expect(field.controller.text, 'Hamburg Hbf');
      // The cursor is painted by the field itself, on top of the glass fill —
      // a blur behind it cannot eat it, but a mis-clipped panel could.
      expect(field.showCursor, isTrue);
      expect(tester.takeException(), isNull);
    });
  });

  group('light mode stays readable', () {
    testWidgets('renders the form and the filter without an overflow',
        (tester) async {
      await _pump(tester, result: _results(), brightness: Brightness.light);

      expect(find.byType(GlassPanel), findsNWidgets(2));
      expect(find.text('Fernverkehr'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
