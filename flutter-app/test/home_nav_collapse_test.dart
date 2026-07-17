import 'package:besser_bahn/providers/connectivity_provider.dart';
import 'package:besser_bahn/router/tab_pager.dart';
import 'package:besser_bahn/screens/home/home_screen.dart';
import 'package:besser_bahn/theme/app_theme.dart';
import 'package:besser_bahn/widgets/app_nav_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

/// The shell collapses its nav bar from whatever the *tab* is scrolling, via a
/// single listener around the body — so these tests drive the real HomeScreen
/// with stand-in tabs. Nothing here mentions the app's actual screens on
/// purpose: the contract is that a tab needs to know nothing about the bar.

/// A tab with somewhere to scroll to.
Widget _longTab() => ListView.builder(
  itemCount: 40,
  itemBuilder: (_, i) => SizedBox(height: 80, child: Text('Zeile $i')),
);

/// A tab that is pullable but has nothing to scroll — the RefreshIndicator
/// shape the Reisen tab uses, and the trap in requirement: it accepts the drag
/// and reports it, but must never lose its labels over it.
Widget _shortTab() => ListView(
  physics: const AlwaysScrollableScrollPhysics(),
  children: const [SizedBox(height: 40, child: Text('Nichts hier'))],
);

/// The shell's four branch paths, in nav-bar order — the shell always has all
/// four (the bar can reach any of them), so a test only names the ones it cares
/// about and the rest stand in as an empty page.
const _paths = ['/search', '/journeys', '/nearby', '/profile'];

/// Boots the real shell — nav bar, pager and all — over the given tab bodies,
/// keyed by route.
Widget _app(Map<String, Widget> tabs) {
  final router = GoRouter(
    initialLocation: _paths.first,
    routes: [
      StatefulShellRoute(
        builder: (_, _, shell) => HomeScreen(navigationShell: shell),
        navigatorContainerBuilder: (_, shell, children) =>
            TabPager(navigationShell: shell, children: children),
        branches: [
          for (final path in _paths)
            StatefulShellBranch(
              preload: true,
              routes: [
                GoRoute(
                  path: path,
                  builder: (_, _) =>
                      tabs[path] ?? const SizedBox.expand(child: Text('leer')),
                ),
              ],
            ),
        ],
      ),
    ],
  );
  return ProviderScope(
    overrides: [
      // Keep the offline strip out of it: the real one waits on a platform
      // channel that a widget test has no answer for.
      connectivityProvider.overrideWith((ref) => Stream.value(true)),
    ],
    child: MaterialApp.router(theme: AppTheme.light(), routerConfig: router),
  );
}

/// The nav labels, matched inside the bar only — a tab's own content must never
/// be able to answer for them.
Finder _navLabel(String label) =>
    find.descendant(of: find.byType(AppNavBar), matching: find.text(label));

void main() {
  group('HomeScreen nav collapse', () {
    testWidgets('scrolling down hides the labels, scrolling up returns them', (
      tester,
    ) async {
      await tester.pumpWidget(_app({'/search': _longTab()}));
      await tester.pumpAndSettle();
      expect(_navLabel('Suche'), findsOneWidget);

      // Reading further down the page → the bar gets out of the way.
      await tester.drag(find.byType(ListView), const Offset(0, -300));
      await tester.pumpAndSettle();
      expect(_navLabel('Suche'), findsNothing);
      expect(_navLabel('Profil'), findsNothing);

      // Back up → the labels come straight back, without having to reach the
      // top first.
      await tester.drag(find.byType(ListView), const Offset(0, 100));
      await tester.pumpAndSettle();
      expect(_navLabel('Suche'), findsOneWidget);
    });

    testWidgets('the page top always shows the full bar', (tester) async {
      await tester.pumpWidget(_app({'/search': _longTab()}));
      await tester.pumpAndSettle();

      await tester.drag(find.byType(ListView), const Offset(0, -300));
      await tester.pumpAndSettle();
      expect(_navLabel('Suche'), findsNothing);

      // All the way back to the start of the page.
      await tester.drag(find.byType(ListView), const Offset(0, 600));
      await tester.pumpAndSettle();
      expect(_navLabel('Suche'), findsOneWidget);
    });

    testWidgets('a page with nothing to scroll never loses its labels', (
      tester,
    ) async {
      await tester.pumpWidget(_app({'/search': _shortTab()}));
      await tester.pumpAndSettle();

      // The drag is accepted (AlwaysScrollableScrollPhysics) and reported as a
      // downward user scroll, but there is no content to read: collapsing here
      // would leave the bar stuck small with nothing that could ever reopen it.
      await tester.drag(find.byType(ListView), const Offset(0, -300));
      await tester.pumpAndSettle();
      expect(_navLabel('Suche'), findsOneWidget);
    });

    testWidgets('switching tabs opens the bar again', (tester) async {
      await tester.pumpWidget(
        _app({'/search': _longTab(), '/nearby': _shortTab()}),
      );
      await tester.pumpAndSettle();

      await tester.drag(find.byType(ListView), const Offset(0, -300));
      await tester.pumpAndSettle();
      expect(_navLabel('Bahnhof'), findsNothing);

      // Collapsed = no labels to tap, so go by icon like the user would.
      await tester.tap(find.byIcon(Icons.train_outlined));
      await tester.pumpAndSettle();

      // The tab change used to clash GlobalKeys here; the tabs are now separate
      // branch Navigators on one strip, so it must throw nothing at all.
      expect(tester.takeException(), isNull);

      // The new tab starts at its own top and cannot scroll — it will never
      // send a notification, so the shell has to reset with the slide.
      expect(_navLabel('Bahnhof'), findsOneWidget);
      expect(_navLabel('Suche'), findsOneWidget);
    });

    testWidgets('collapsing does not move the inset the tab pads by', (
      tester,
    ) async {
      // The feedback loop this design exists to prevent: inset → list padding →
      // maxScrollExtent → scroll metrics → collapsed → inset. Recording every
      // value the tab is handed proves the chain is cut at the first link.
      final insets = <double>[];
      await tester.pumpWidget(
        _app({
          '/search': Builder(
            builder: (context) {
              insets.add(AppNavBar.insetOf(context));
              return ListView.builder(
                padding: EdgeInsets.only(bottom: AppNavBar.insetOf(context)),
                itemCount: 40,
                itemBuilder: (_, i) => SizedBox(height: 80, child: Text('$i')),
              );
            },
          ),
        }),
      );
      await tester.pumpAndSettle();

      final baseline = insets.last;
      insets.clear();

      await tester.drag(find.byType(ListView), const Offset(0, -300));
      await tester.pumpAndSettle();

      expect(_navLabel('Suche'), findsNothing, reason: 'it must have collapsed');
      // The tab only rebuilds here if its MediaQuery padding actually moved, so
      // an empty list is the pass — and any value that did arrive must be the
      // same number as before.
      expect(
        insets,
        everyElement(equals(baseline)),
        reason: 'the bar shrank inside a footprint that must not move',
      );
    });
  });
}
