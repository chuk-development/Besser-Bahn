// The four tabs lie side by side on one strip, and the app pans along it.
//
// They are StatefulShellRoute branches in a PageView, so the strip is real: you
// can drag it, and a jump travels the whole distance instead of cutting one
// screen-width. What that costs is nested horizontal gestures — the Bahnhof tab
// is a TabBarView with a map in it — so the strip deliberately refuses the
// finger there; that refusal is pinned below, because the honest limitation is
// the feature, and a later "fix" that half-restores the swipe would be worse
// than not having it.
//
// REGRESSION: the tab change was once an AnimatedSwitcher in the shell, holding
// the outgoing child for 260 ms. go_router hands a plain ShellRoute the same
// GlobalKey'd child every build, so that put one key in the tree twice on EVERY
// tab switch. Branch Navigators are separate trees and cannot clash that way —
// the `takeException` checks stay to keep it that way.
import 'package:besser_bahn/providers/connectivity_provider.dart';
import 'package:besser_bahn/router/tab_pager.dart';
import 'package:besser_bahn/screens/home/home_screen.dart';
import 'package:besser_bahn/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

const _paths = ['/search', '/journeys', '/nearby', '/profile'];
const _labels = ['SUCHE', 'REISEN', 'BAHNHOF', 'PROFIL'];

/// A stand-in tab. Nothing here names a real screen on purpose: the strip must
/// not know or care what a tab puts on it.
class _Page extends StatelessWidget {
  final String label;
  const _Page(this.label);

  @override
  Widget build(BuildContext context) => SizedBox.expand(
    key: ValueKey('page-$label'),
    child: Center(child: Text(label)),
  );
}

/// The Bahnhof tab's shape: an inner tab bar with a swipeable TabBarView — a
/// second horizontal gesture living *inside* the strip.
class _InnerTabsPage extends StatelessWidget {
  const _InnerTabsPage();

  @override
  Widget build(BuildContext context) => SizedBox.expand(
    key: const ValueKey('page-BAHNHOF'),
    child: DefaultTabController(
      length: 3,
      child: Column(
        children: const [
          TabBar(tabs: [Tab(text: 'Zug'), Tab(text: 'Abf'), Tab(text: 'Kt')]),
          Expanded(
            child: TabBarView(
              children: [_Page('ZUG'), _Page('ABFAHRTEN'), _Page('KARTE')],
            ),
          ),
        ],
      ),
    ),
  );
}

/// Boots the real shell — HomeScreen, the nav bar and TabPager — over stand-in
/// tabs. [nearby] replaces the Bahnhof tab for the nested-gesture tests.
({Widget app, GoRouter router}) _app({Widget? nearby}) {
  final router = GoRouter(
    initialLocation: _paths.first,
    routes: [
      StatefulShellRoute(
        builder: (_, _, shell) => HomeScreen(navigationShell: shell),
        navigatorContainerBuilder: (_, shell, children) =>
            TabPager(navigationShell: shell, children: children),
        branches: [
          for (final (i, path) in _paths.indexed)
            StatefulShellBranch(
              // As in the app: without it the tabs we pan *over* would have no
              // Navigator yet and pan past as blank boxes.
              preload: true,
              routes: [
                GoRoute(
                  path: path,
                  builder: (_, _) =>
                      i == 2 && nearby != null ? nearby : _Page(_labels[i]),
                ),
              ],
            ),
        ],
      ),
    ],
  );
  return (
    app: ProviderScope(
      overrides: [
        // The offline strip waits on a platform channel a widget test has no
        // answer for.
        connectivityProvider.overrideWith((ref) => Stream.value(true)),
      ],
      child: MaterialApp.router(theme: AppTheme.light(), routerConfig: router),
    ),
    router: router,
  );
}

/// Where the tab for [label] sits on screen, or null if the strip has it parked
/// out of view.
///
/// `find`'s default `skipOffstage: true` is doing real work here, and it is the
/// only reason this can be a one-liner. All four tabs stay *mounted* — that is
/// exactly what branch Navigators buy: each keeps its stack, its scroll offset
/// and its state while parked — so "is it in the tree" is the wrong question
/// and would answer yes for all four at once. A sliver reports only the
/// children it actually laid out into view as onstage, so a hit here means you
/// can genuinely see that tab.
Rect? _pageRect(WidgetTester tester, String label) {
  final finder = find.byKey(ValueKey('page-$label'));
  return finder.evaluate().isEmpty ? null : tester.getRect(finder);
}

/// Every tab you can see right now.
Set<String> _onScreen(WidgetTester tester) =>
    {for (final l in _labels) if (_pageRect(tester, l) != null) l};

void main() {
  testWidgets('the tabs lie side by side — mid-change you see both', (
    tester,
  ) async {
    final (:app, :router) = _app();
    await tester.pumpWidget(app);
    await tester.pumpAndSettle();
    expect(_onScreen(tester), {'SUCHE'});

    router.go('/journeys');
    await tester.pump(); // the route lands, the pan is scheduled
    await tester.pump(); // the pan's first tick
    await tester.pump(const Duration(milliseconds: 60)); // part way over

    expect(
      tester.takeException(),
      isNull,
      reason: 'the tab we are leaving must survive the pan',
    );
    // Both on screen at once — that is a strip being panned, not a page being
    // swapped. And they are genuinely adjacent: Reisen's left edge sits exactly
    // one screen to the right of Suche's. No gap, no overlap, no stacking.
    final suche = _pageRect(tester, 'SUCHE');
    final reisen = _pageRect(tester, 'REISEN');
    expect(suche, isNotNull);
    expect(reisen, isNotNull);
    expect(reisen!.left, moreOrLessEquals(suche!.right, epsilon: 0.5));
    expect(suche.left, lessThan(0), reason: 'the strip has moved on');

    await tester.pumpAndSettle();
    expect(_onScreen(tester), {'REISEN'});
    expect(_pageRect(tester, 'REISEN')!.left, moreOrLessEquals(0, epsilon: 0.5));
  });

  testWidgets('a jump from Suche to Profil pans across the tabs in between', (
    tester,
  ) async {
    final (:app, :router) = _app();
    await tester.pumpWidget(app);
    await tester.pumpAndSettle();

    // By the nav bar, like the user: the last tab, tapped from the first.
    await tester.tap(find.byIcon(Icons.account_circle_outlined));

    final seen = <String>{};
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 10));
      seen.addAll(_onScreen(tester));
    }
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(
      seen,
      containsAll(['REISEN', 'BAHNHOF']),
      reason: '0 → 3 must travel over 1 and 2, not cut one screen-width',
    );
    expect(router.state.uri.path, '/profile');
    expect(_onScreen(tester), {'PROFIL'});
  });

  testWidgets('swiping sideways changes the tab, and the route follows', (
    tester,
  ) async {
    final (:app, :router) = _app();
    await tester.pumpWidget(app);
    await tester.pumpAndSettle();

    await tester.drag(find.byType(PageView), const Offset(-600, 0));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(_onScreen(tester), {'REISEN'});
    expect(
      router.state.uri.path,
      '/journeys',
      reason: 'the finger moved the strip; the route has to come along',
    );
  });

  testWidgets('a swipe is not panned back by the route change it causes', (
    tester,
  ) async {
    // The feedback loop this design exists to prevent: swipe → onPageChanged →
    // goBranch → the shell rebuilds with a new index → "that index isn't where
    // the strip is, pan there" → the page is yanked out from under the finger.
    final (:app, :router) = _app();
    await tester.pumpWidget(app);
    await tester.pumpAndSettle();

    await tester.drag(find.byType(PageView), const Offset(-600, 0));
    await tester.pump(); // let the goBranch rebuild land mid-settle
    await tester.pumpAndSettle();

    expect(_pageRect(tester, 'REISEN')!.left, moreOrLessEquals(0, epsilon: 0.5));
    expect(router.state.uri.path, '/journeys');

    // And the other way round: the tap-driven pan crosses tabs 2 and 3, but
    // only the tab we actually asked for may end up in the route.
    await tester.tap(find.byIcon(Icons.account_circle_outlined));
    await tester.pumpAndSettle();
    expect(
      router.state.uri.path,
      '/profile',
      reason: 'the tabs we panned over must not push routes of their own',
    );
  });

  testWidgets('the Bahnhof tab keeps the sideways drag for its own tabs', (
    tester,
  ) async {
    // Nested horizontal gestures have one winner and it is the innermost, so
    // the strip gives Bahnhof the axis outright rather than answering some
    // drags and not others depending on where the thumb landed.
    final (:app, :router) = _app(nearby: const _InnerTabsPage());
    await tester.pumpWidget(app);
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.train_outlined));
    await tester.pumpAndSettle();
    expect(router.state.uri.path, '/nearby');

    // On the body: the inner TabBarView takes it — Zug → Abfahrten.
    await tester.drag(find.byType(TabBarView), const Offset(-600, 0));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(
      router.state.uri.path,
      '/nearby',
      reason: 'the inner tabs own this drag, not the strip',
    );
    expect(find.text('ABFAHRTEN'), findsOneWidget);

    // And on the chrome above it, where no inner scrollable would have caught
    // the drag: still nothing. The refusal is the whole tab, not just the parts
    // that happen to have a scrollable under them — otherwise the swipe would
    // work or not work depending on where your thumb landed.
    await tester.drag(find.byType(TabBar), const Offset(-600, 0));
    await tester.pumpAndSettle();
    expect(router.state.uri.path, '/nearby');
    expect(_pageRect(tester, 'BAHNHOF')!.left, moreOrLessEquals(0, epsilon: 0.5));
  });

  testWidgets('the nav bar still leaves the Bahnhof tab', (tester) async {
    // Refusing the drag there is only honest if the bar always works.
    final (:app, :router) = _app(nearby: const _InnerTabsPage());
    await tester.pumpWidget(app);
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.train_outlined));
    await tester.pumpAndSettle();
    expect(router.state.uri.path, '/nearby');

    await tester.tap(find.byIcon(Icons.search_outlined));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(router.state.uri.path, '/search');
    expect(_pageRect(tester, 'SUCHE')!.left, moreOrLessEquals(0, epsilon: 0.5));
  });

  testWidgets('a tab keeps its state while parked off the strip', (
    tester,
  ) async {
    // What branches buy over pages, and the reason the shell is stateful at
    // all: a tab that scrolls off the strip is parked, not thrown away.
    final (:app, :router) = _app();
    await tester.pumpWidget(app);
    await tester.pumpAndSettle();

    router.go('/profile');
    await tester.pumpAndSettle();
    expect(_onScreen(tester), {'PROFIL'});
    // Out of sight, still mounted — the tab is holding its state over there.
    expect(
      find.byKey(const ValueKey('page-SUCHE'), skipOffstage: false),
      findsOneWidget,
    );

    router.go('/search');
    await tester.pumpAndSettle();
    expect(_onScreen(tester), {'SUCHE'});
  });
}
