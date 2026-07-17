import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../widgets/app_nav_bar.dart';

/// The four tabs, really lying side by side on one strip.
///
/// This is the container for [StatefulShellRoute]'s branch Navigators: a
/// [PageView] over all four of them, so the tabs are not four pages taking
/// turns on one spot but one horizontal strip the app pans along. Two things
/// fall out of that, and both are the point:
///
///  * **The finger works.** Drag sideways and the next tab comes with it,
///    tracking the drag, and the route follows where you let go.
///  * **A jump travels the distance.** Tapping Profil from Suche pans across
///    Reisen and Bahnhof instead of teleporting one screen-width — you see how
///    far you went, which is what tells you where you are.
///
/// Each branch keeps its own Navigator, so each tab keeps its own stack, scroll
/// offset and state while it is parked off-screen; go_router wraps every branch
/// in an `AutomaticKeepAliveClientMixin` proxy for exactly this kind of sliver
/// container, so the PageView cannot throw a tab away by scrolling it out.
///
/// Replaces the old `tab_slide.dart`, which faked this with a per-page
/// [CustomTransitionPage]: one page in, one page out, always exactly one
/// screen-width no matter how far the jump, and nothing to grab.
class TabPager extends StatefulWidget {
  const TabPager({
    super.key,
    required this.navigationShell,
    required this.children,
  });

  /// The shell — tells us which branch is current and takes us to another one.
  final StatefulNavigationShell navigationShell;

  /// The branch Navigators, in branch order. All four are handed to the
  /// [PageView] on every build; it only mounts the ones its viewport reaches.
  final List<Widget> children;

  /// Same motion the nav bar's highlight glides with, so the bar and the strip
  /// are one movement instead of two things happening at once.
  static const duration = AppNavBar.motionDuration;
  static const curve = AppNavBar.motionCurve;

  /// Tabs whose page may not be left by a sideways drag.
  ///
  /// Nested horizontal gestures have exactly one winner, and it is the
  /// innermost one — Flutter hands a drag to the deepest recognizer that wants
  /// the same axis, and there is no "the child is at its edge, pass it up" for
  /// scrollables. Index 2 (Bahnhof) is a `TabBarView` of Zug / Abfahrten /
  /// Karte, and its Karte page is a `FlutterMap` that swallows horizontal drags
  /// whole. So on that tab a sideways drag was never going to reach this strip
  /// from the body anyway — but it *would* have reached it from the AppBar and
  /// the TabBar above, which is worse than not working: a swipe that depends on
  /// where your thumb landed. We take the choice instead of letting the arena
  /// take it: on Bahnhof the sideways drag belongs to the inner tabs, full
  /// stop, and the nav bar is how you leave. Everywhere else the strip is
  /// yours.
  static const swipeBlocked = <int>{2};

  @override
  State<TabPager> createState() => _TabPagerState();
}

class _TabPagerState extends State<TabPager> {
  late final PageController _controller;

  /// The page the strip last reported being on, kept in step with
  /// [PageView.onPageChanged].
  ///
  /// This is what tells the two ways a tab change reaches us apart, and it is
  /// the whole reason tap and swipe don't chase each other in a circle:
  ///
  ///  * the route moved *first* (nav bar tap, deep link) — the strip is still
  ///    parked somewhere else, so pan it over there;
  ///  * the route moved *because* the strip did (a swipe reported its landing
  ///    and we pushed the branch) — the route is only catching up, and panning
  ///    to where we already are would snatch the page out from under a finger
  ///    that is still on it.
  ///
  /// Seeded in [initState], and it has to be: as a `late` field with an
  /// initializer it would be evaluated on first *read* instead, and the first
  /// read is [didUpdateWidget] — where `widget` is already the new one. It
  /// would have initialised itself to the tab we are being asked to pan *to*,
  /// concluded we were already there, and never panned at all.
  late int _reportedPage;

  /// A pan we've scheduled for after this frame but not started yet — so a
  /// second rebuild in the same frame doesn't queue the same trip twice.
  int? _pendingPan;

  /// Set while [_panTo] is driving the strip.
  ///
  /// A pan from Suche to Profil crosses Reisen and Bahnhof, and the PageView
  /// dutifully reports each one it passes. Pushing a branch for a tab we are
  /// merely flying over would rewrite history to junk and — because that push
  /// comes back as a route change — turn the pan around mid-air.
  bool _panning = false;

  /// Guards the flag against overtaking pans: tap Profil, then tap Suche before
  /// the first pan lands, and the first `animateToPage`'s future still
  /// completes. Only the newest trip owns [_panning].
  int _panToken = 0;

  @override
  void initState() {
    super.initState();
    _reportedPage = widget.navigationShell.currentIndex;
    // Start where the route already is — a deep link into Profil must open on
    // Profil, not pan there from Suche while the app is still starting up.
    _controller = PageController(initialPage: _reportedPage);
  }

  @override
  void didUpdateWidget(covariant TabPager oldWidget) {
    super.didUpdateWidget(oldWidget);
    final target = widget.navigationShell.currentIndex;
    // Already there, heading there, or the strip is the one that put us there.
    if (target == _reportedPage || target == _pendingPan) return;
    _pendingPan = target;
    // Next frame, not this one. The PageView below is about to be rebuilt with
    // this same tab change, and if it crosses [TabPager.swipeBlocked] its
    // physics swap makes Scrollable throw its ScrollPosition away and build a
    // fresh one — an animation started on the old position would be driving a
    // corpse. After the frame the strip is laid out and settled.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _pendingPan = null;
      _panTo(target);
    });
  }

  Future<void> _panTo(int index) async {
    if (!_controller.hasClients) return;
    final token = ++_panToken;
    _panning = true;
    await _controller.animateToPage(
      index,
      duration: TabPager.duration,
      curve: TabPager.curve,
    );
    if (token == _panToken) _panning = false;
  }

  void _onPageChanged(int index) {
    _reportedPage = index;
    // A tab we are panning over, not one we are going to.
    if (_panning) return;
    if (index == widget.navigationShell.currentIndex) return;
    // A swipe: the finger has decided, so move the route to match. The rebuild
    // that comes back finds target == _reportedPage and leaves the strip alone.
    widget.navigationShell.goBranch(index);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final current = widget.navigationShell.currentIndex;
    return PageView(
      controller: _controller,
      onPageChanged: _onPageChanged,
      // Note this never blocks [_panTo]: NeverScrollableScrollPhysics only
      // refuses the *user's* offsets, an animateToPage still runs. So the nav
      // bar keeps working on Bahnhof — only the drag is off there.
      physics: TabPager.swipeBlocked.contains(current)
          ? const NeverScrollableScrollPhysics()
          : null,
      children: [
        for (final (index, child) in widget.children.indexed)
          NotificationListener<ScrollNotification>(
            // All four tabs are alive in here at once, and a parked one can
            // still report a scroll it never made — a viewport resize, a
            // restored offset, a list that finished loading. The shell above
            // collapses its nav bar from what "the page" is doing, and it has
            // no way to tell whose page that was. So only the tab the user is
            // looking at gets to speak: everyone else is stopped right here
            // (returning true = handled, don't bubble).
            onNotification: (_) => index != current,
            child: child,
          ),
      ],
    );
  }
}
