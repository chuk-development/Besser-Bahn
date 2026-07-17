import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../models/library_models.dart';
import '../../providers/journey_search_provider.dart';
import '../../providers/library_provider.dart';
import '../../providers/settings_provider.dart';
import '../../vendor/chuk_ui/chuk_squircle.dart';
import '../../widgets/app_nav_bar.dart';
import '../../widgets/glass_panel.dart';
import '../../widgets/station_search_field.dart';
import '../../widgets/app_menu_button.dart';
import '../home/home_screen.dart' show HomeScreen;
import 'best_price_screen.dart' show BestPriceArgs;
import 'widgets/journey_card.dart';
import 'widgets/reisende_sheet.dart';
import 'widgets/search_options_sheet.dart';

class ConnectionSearchScreen extends ConsumerStatefulWidget {
  const ConnectionSearchScreen({super.key});

  @override
  ConsumerState<ConnectionSearchScreen> createState() =>
      _ConnectionSearchScreenState();
}

class _ConnectionSearchScreenState
    extends ConsumerState<ConnectionSearchScreen> {
  final _fromController = TextEditingController();
  final _toController = TextEditingController();

  /// Folded to the one-line summary, handing the freed ~150 px to the results.
  /// Only ever set by [_setCollapsed] — see [_watchResults] for the rules.
  bool _collapsed = false;

  /// What the floating header (form + saved routes + filter) covers, measured
  /// by [_MeasuredHeight]. The results pad themselves by it so the first
  /// connection starts below the glass instead of under it.
  double _headerHeight = 0;

  void _setHeaderHeight(double value) {
    if (!mounted || _headerHeight == value) return;
    setState(() => _headerHeight = value);
  }

  @override
  void dispose() {
    _fromController.dispose();
    _toController.dispose();
    super.dispose();
  }

  void _setCollapsed(bool value) {
    if (_collapsed == value) return;
    // Folding must not leave a keyboard — or the station dropdown that floats
    // above everything — hanging over results whose form is gone.
    if (value) FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _collapsed = value);
  }

  /// Decides when the form gets out of the way. Fires on provider changes
  /// only, never during build.
  void _watchResults(JourneySearchState? prev, JourneySearchState next) {
    // `resultSerial` is bumped by a fresh search alone. Watching `result`
    // instead would also fold the form away the moment the rider pages with
    // "Früher"/"Später" — right after they reopened it on purpose.
    if (prev != null && next.resultSerial != prev.resultSerial) {
      // An empty result is not something to make room for: it means "widen
      // the search", and the form is what does the widening.
      _setCollapsed(next.result?.journeys.isNotEmpty ?? false);
    }
    // Same reasoning for a failed search — the fix lives in the form.
    if (next.error != null) _setCollapsed(false);
  }

  void _search() {
    final notifier = ref.read(journeySearchProvider.notifier);
    notifier.search(fromText: _fromController.text, toText: _toController.text);
  }

  Future<void> _editParty() async {
    final party = ref.read(settingsProvider).searchParty;
    final updated = await showReisendeSheet(context, party);
    if (updated == null || !mounted) return;
    ref.read(settingsProvider.notifier).setSearchParty(updated);
    // Re-run the search so prices reflect the new party immediately.
    if (ref.read(journeySearchProvider).result != null) _search();
  }

  Future<void> _editOptions() async {
    final state = ref.read(journeySearchProvider);
    final updated = await showSearchOptionsSheet(
      context,
      state.options,
      profile: ref.read(settingsProvider).transferProfile,
    );
    if (updated == null || !mounted) return;
    // setOptions re-runs the search itself when results are already showing;
    // before the first search it just records the wish.
    ref.read(journeySearchProvider.notifier).setOptions(updated);
  }

  void _applyRoute(SavedRoute route) {
    final notifier = ref.read(journeySearchProvider.notifier);
    notifier.setFrom(route.from);
    notifier.setTo(route.to);
    _fromController.text = route.from.name;
    _toController.text = route.to.name;
    _search();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(journeySearchProvider);
    final notifier = ref.read(journeySearchProvider.notifier);
    final theme = Theme.of(context);

    ref.listen<JourneySearchState>(journeySearchProvider, _watchResults);

    return Scaffold(
      // Keyboard shouldn't squeeze the form — the station dropdown is an
      // overlay floating above everything, so resizing just makes the layout
      // jump. Form stays anchored under the AppBar.
      resizeToAvoidBottomInset: false,
      appBar: AppBar(
        title: const Text('Verbindungen'),
        actions: [
          const AppMenuButton(),
          if (state.from != null && state.to != null)
            Builder(
              builder: (context) {
                final saved = ref
                    .watch(libraryProvider)
                    .isRouteSaved(state.from!.id, state.to!.id);
                return IconButton(
                  icon: Icon(saved ? Icons.bookmark : Icons.bookmark_border),
                  tooltip: saved ? 'Route entfernen' : 'Route speichern',
                  onPressed: () {
                    ref
                        .read(libraryProvider.notifier)
                        .toggleRoute(state.from!, state.to!);
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        duration: const Duration(seconds: 2),
                        content: Text(
                          saved ? 'Route entfernt' : 'Route gespeichert',
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          // Bestpreis over the whole day (#21) — needs only the route, so it's
          // offered as soon as both stations are set, before any search.
          if (state.from != null && state.to != null)
            IconButton(
              icon: const Icon(Icons.savings_outlined),
              tooltip: 'Bestpreis über den Tag',
              onPressed: () => context.push(
                '/best-price',
                extra: BestPriceArgs(
                  from: state.from!,
                  to: state.to!,
                  date: state.dateTime ?? DateTime.now(),
                ),
              ),
            ),
          if (state.result != null && state.sortedJourneys.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.price_check),
              tooltip: 'Preise vergleichen (Split-Ticket für alle)',
              onPressed: () =>
                  context.push('/split-compare', extra: state.sortedJourneys),
            ),
          // D-Ticket-Optimierer: same comparison, ordered by what each
          // connection costs ON TOP of the Deutschlandticket (#28). Pointless
          // without one, so it follows the setting — like "Nur D-Ticket".
          if (state.result != null &&
              state.sortedJourneys.isNotEmpty &&
              ref.watch(settingsProvider).hasDeutschlandTicket)
            IconButton(
              icon: const Icon(Icons.confirmation_number_outlined),
              tooltip: 'D-Ticket-Optimierer (nach Zuzahlung)',
              onPressed: () => context.push(
                '/split-compare?dticket=1',
                extra: state.sortedJourneys,
              ),
            ),
          if (state.result != null)
            PopupMenuButton<JourneySortMode>(
              icon: const Icon(Icons.sort),
              tooltip: 'Sortierung',
              onSelected: notifier.setSortMode,
              itemBuilder: (_) => [
                _sortItem(JourneySortMode.departure, 'Abfahrt', state.sortMode),
                _sortItem(JourneySortMode.arrival, 'Ankunft', state.sortMode),
                _sortItem(JourneySortMode.duration, 'Dauer', state.sortMode),
                _sortItem(
                  JourneySortMode.transfers,
                  'Umstiege',
                  state.sortMode,
                ),
                _sortItem(
                  JourneySortMode.reliability,
                  'Zuverlässigkeit',
                  state.sortMode,
                ),
              ],
            ),
        ],
      ),
      // The header floats *over* the results rather than sitting above them in
      // a Column: the connections run the full height of the body and scroll
      // behind the glass, the same way a tab's content scrolls behind the
      // bottom nav bar's pill (`AppNavBar`).
      body: Stack(
        children: [
          Positioned.fill(child: _buildResults(context, state, notifier)),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: _MeasuredHeight(
              onHeight: _setHeaderHeight,
              child: _header(context, state, notifier, theme),
            ),
          ),
        ],
      ),
    );
  }

  /// Everything that floats above the connections: the search form (or its
  /// folded summary), the saved-route chips, the transport filter and the
  /// notices about the search.
  ///
  /// Laid out top-anchored and free of the results' layout, so the fold
  /// animation moves only this column — the list underneath keeps its own
  /// height and simply re-pads (see [_MeasuredHeight]).
  Widget _header(
    BuildContext context,
    JourneySearchState state,
    JourneySearchNotifier notifier,
    ThemeData theme,
  ) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Search form — folds to a one-line summary once results are in, so
        // the connections get the space instead of a form nobody is filling
        // in any more.
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
          child: GlassPanel(
            child: AnimatedCrossFade(
              // Same 260 ms / easeOutCubic as the tab slide: one app, one
              // movement.
              duration: HomeScreen.slideDuration,
              firstCurve: HomeScreen.slideCurve,
              secondCurve: HomeScreen.slideCurve,
              sizeCurve: HomeScreen.slideCurve,
              crossFadeState: _collapsed
                  ? CrossFadeState.showSecond
                  : CrossFadeState.showFirst,
              // Both children stay mounted, so folding cannot disturb the text
              // fields, their controllers or the focus — and the widget's own
              // ClipRect means the shrinking box can never overflow while the
              // height animates.
              firstChild: _searchForm(context, state, notifier, theme),
              secondChild: _collapsedSummary(context, state, theme),
            ),
          ),
        ),

        _buildSavedRoutes(context),

        // The filter and the notices belong to a result, so they arrive with
        // one. Kept in the header rather than in the list: they are chrome for
        // the connections below, and scrolling them away would hide why the
        // list looks the way it does.
        if (state.result != null) ...[
          _productFilterBar(context, state, notifier),
          if (state.transferProfileRelaxed) _relaxedNotice(context),
          if (state.sortMode == JourneySortMode.reliability)
            _reliabilityNotice(context),
        ],
      ],
    );
  }

  /// The full form: Von/Nach, Reisende & Klasse, date/time, Ab/An, search.
  Widget _searchForm(
    BuildContext context,
    JourneySearchState state,
    JourneySearchNotifier notifier,
    ThemeData theme,
  ) {
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Column(
        children: [
          // From/To stacked tight together (fields share a divider gap
          // of just 4px) with the swap button vertically centred right.
          Row(
            children: [
              Expanded(
                child: Column(
                  children: [
                    StationSearchField(
                      hint: 'Von',
                      prefixIcon: Icons.trip_origin,
                      initialStation: state.from,
                      controller: _fromController,
                      onSelected: notifier.setFrom,
                      dense: true,
                    ),
                    const SizedBox(height: 4),
                    StationSearchField(
                      hint: 'Nach',
                      prefixIcon: Icons.location_on,
                      initialStation: state.to,
                      controller: _toController,
                      onSelected: notifier.setTo,
                      dense: true,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              // A bit bigger than before — and since the fields are
              // Expanded, growing it nudges Von/Nach slightly narrower
              // (left-anchored), which is the look we want.
              IconButton.filledTonal(
                icon: const Icon(Icons.swap_vert, size: 24),
                iconSize: 24,
                tooltip: 'Tauschen',
                onPressed: () {
                  notifier.swapStations();
                  final tmp = _fromController.text;
                  _fromController.text = _toController.text;
                  _toController.text = tmp;
                },
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              // Reisende & Klasse — opens the party sheet (passengers,
              // ages, bike/dog, class, BahnCards,
              // Schwerbehindertenausweis).
              Expanded(
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    alignment: Alignment.centerLeft,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  icon: const Icon(Icons.people_outline, size: 20),
                  label: Row(
                    children: [
                      Expanded(
                        child: Text(
                          ref
                              .watch(
                                settingsProvider.select(
                                  (s) => s.searchParty,
                                ),
                              )
                              .summary,
                          style: theme.textTheme.bodyMedium,
                        ),
                      ),
                      const Icon(Icons.expand_more, size: 18),
                    ],
                  ),
                  onPressed: _editParty,
                ),
              ),
              const SizedBox(width: 6),
              _optionsButton(context, state),
            ],
          ),
          const SizedBox(height: 6),
          // IntrinsicHeight + stretch: time field, Ab/An toggle and
          // search button all render at one shared height (the buttons'
          // tap-target height) instead of each picking its own — mobile
          // showed them mismatched before.
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: InkWell(
                    onTap: () => _pickDateTime(context, ref),
                    borderRadius: BorderRadius.circular(12),
                    child: InputDecorator(
                      decoration: const InputDecoration(
                        isDense: true,
                        prefixIcon: Icon(Icons.access_time, size: 18),
                        prefixIconConstraints: BoxConstraints(
                          minWidth: 34,
                          minHeight: 34,
                        ),
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 8,
                        ),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              state.dateTime != null
                                  ? DateFormat(
                                      'dd.MM. HH:mm',
                                    ).format(state.dateTime!)
                                  : 'Jetzt',
                              style: theme.textTheme.bodyMedium,
                            ),
                          ),
                          // Once a time is picked, offer a quick way
                          // back to "Jetzt" (which also drops An→Ab).
                          if (state.dateTime != null)
                            InkWell(
                              onTap: notifier.resetToNow,
                              borderRadius: BorderRadius.circular(12),
                              child: const Padding(
                                padding: EdgeInsets.all(2),
                                child: Icon(Icons.close, size: 18),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                // Custom Ab/An toggle instead of SegmentedButton: the
                // latter paints the selected segment's fill as a
                // top-anchored rectangle shorter than the outline,
                // leaving an unfilled strip at the bottom in this row.
                // Here the selected segment is a Container that stretches
                // to the full pill height, so the fill can never gap.
                _AbAnToggle(
                  useArrival: state.useArrival,
                  arrivalEnabled: state.dateTime != null,
                  onChanged: notifier.setIsArrival,
                ),
                const SizedBox(width: 4),
                FilledButton(
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    // Give it real width so it reads as a proper button,
                    // not a squeezed icon chip.
                    minimumSize: const Size(64, 0),
                    // Match the time field's rounding instead of the
                    // default stadium pill, which looked oddly clipped
                    // squeezed into this stretched row.
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: state.isLoading ? null : _search,
                  child: state.isLoading
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.search, size: 24),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// The folded form: everything needed to recognise the search you are
  /// looking at — route, when, party/class, plus a marker when search options
  /// are narrowing the result (they live in the form and would otherwise
  /// vanish without a trace). Tapping anywhere unfolds it again.
  ///
  /// Two tight lines rather than one long string: on a 320 px screen
  /// "Kiel Hbf → München Hbf · Heute 20:37 · 1 Reisende·r · 2. Kl." cannot fit
  /// on one line, and ellipsising it would eat exactly the time and party the
  /// summary exists to show. Every line clips instead of wrapping, so long
  /// station names shorten and never overflow.
  Widget _collapsedSummary(
    BuildContext context,
    JourneySearchState state,
    ThemeData theme,
  ) {
    final party = ref.watch(settingsProvider.select((s) => s.searchParty));
    final activeOptions = state.options.activeCount;
    final scheme = theme.colorScheme;

    return Tooltip(
      message: 'Suche ändern',
      child: InkWell(
        onTap: () => _setCollapsed(false),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
          child: Row(
            children: [
              Icon(Icons.search, size: 18, color: scheme.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${state.from?.name ?? '—'} → ${state.to?.name ?? '—'}',
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    Text(
                      '${_whenLabel(state)} · ${party.summary}',
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              if (activeOptions > 0) ...[
                const SizedBox(width: 8),
                Icon(Icons.tune, size: 16, color: scheme.primary),
                const SizedBox(width: 2),
                Text(
                  '$activeOptions',
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: scheme.primary),
                ),
              ],
              const SizedBox(width: 4),
              Icon(Icons.expand_more, size: 20, color: scheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }

  /// When the search is for, as the folded line says it: "Jetzt", or
  /// "Ab/An Heute 14:05". The Ab/An prefix carries the arrival toggle, which
  /// is otherwise invisible while folded.
  String _whenLabel(JourneySearchState state) {
    final dt = state.dateTime;
    if (dt == null) return 'Jetzt';
    final now = DateTime.now();
    final days = DateTime(dt.year, dt.month, dt.day)
        .difference(DateTime(now.year, now.month, now.day))
        .inDays;
    final day = switch (days) {
      0 => 'Heute',
      1 => 'Morgen',
      -1 => 'Gestern',
      _ => DateFormat('dd.MM.').format(dt),
    };
    final prefix = state.useArrival ? 'An' : 'Ab';
    return '$prefix $day ${DateFormat('HH:mm').format(dt)}';
  }

  /// Opens the search-options sheet (#19). Sits next to the party button
  /// rather than in the result filter bar: max. changes / transfer time / via
  /// shape the *query*, so they have to be reachable before the first search,
  /// and the filter bar only exists once there are results.
  Widget _optionsButton(BuildContext context, JourneySearchState state) {
    final count = state.options.activeCount;
    final scheme = Theme.of(context).colorScheme;
    return OutlinedButton(
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        // An active constraint must be visible without opening the sheet —
        // otherwise a search silently missing connections looks like DB's
        // fault.
        foregroundColor: count > 0 ? scheme.onPrimaryContainer : null,
        backgroundColor: count > 0 ? scheme.primaryContainer : null,
      ),
      onPressed: _editOptions,
      child: Badge(
        isLabelVisible: count > 0,
        label: Text('$count'),
        child: const Icon(Icons.tune, size: 20),
      ),
    );
  }

  Widget _buildSavedRoutes(BuildContext context) {
    final routes = ref.watch(libraryProvider).routes;
    if (routes.isEmpty) return const SizedBox.shrink();
    return _glassStrip(
      children: [
        for (final route in routes)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 3),
            child: ActionChip(
              avatar: const Icon(Icons.bookmark, size: 16),
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              label: Text(
                '${route.from.name} → ${route.to.name}',
                overflow: TextOverflow.ellipsis,
              ),
              onPressed: () => _applyRoute(route),
            ),
          ),
      ],
    );
  }

  /// A floating pill of glass holding one horizontally scrolling row of chips —
  /// the shape the bottom nav bar wears, so the filter and the saved routes
  /// read as the same furniture.
  ///
  /// A [SingleChildScrollView] + [Row] rather than the horizontal [ListView]
  /// these rows used to be: a horizontal list has no intrinsic height, so it
  /// forces one to be hardcoded here and forces every chip to exactly that —
  /// which is precisely how a chip that grew a few px (a longer label, a larger
  /// system text scale) becomes the next "3 px overflow". The Row takes the
  /// chips' own height instead, and since the header is *measured*
  /// ([_MeasuredHeight]) the results re-pad themselves to whatever that is. No
  /// number to get wrong.
  ///
  /// Both rows are short (≤ 7 chips) and the lists they replace passed
  /// `children:`, so they were built eagerly already — nothing is lost.
  Widget _glassStrip({required List<Widget> children}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
      child: GlassPanel(
        radius: GlassPanel.pillRadius,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.all(4),
          child: Row(children: children),
        ),
      ),
    );
  }

  Widget _buildResults(
    BuildContext context,
    JourneySearchState state,
    JourneySearchNotifier notifier,
  ) {
    // Anything that does not scroll has to *start* below the floating header,
    // so it gets the header's footprint as plain padding around it.
    Widget below(Widget child) => Padding(
          padding: EdgeInsets.only(top: _headerHeight),
          child: Center(child: child),
        );

    if (state.error != null) {
      return below(
        Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.error_outline,
                size: 40,
                color: Theme.of(context).colorScheme.error,
              ),
              const SizedBox(height: 12),
              Text(
                state.error!,
                textAlign: TextAlign.center,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ),
        ),
      );
    }

    if (state.result == null) {
      return below(
        const Padding(
          padding: EdgeInsets.all(32),
          child: Text(
            'Start und Ziel eingeben, um Verbindungen zu suchen.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    // Same list as state.sortedJourneys, except in reliability mode where the
    // prediction model re-orders it as scores arrive.
    final journeys = ref.watch(reliabilitySortedJourneysProvider);
    if (journeys.isEmpty) {
      return below(
        Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            state.options.isDefault
                ? 'Keine Verbindungen — ggf. einen '
                      'Verkehrsmittel-Filter lockern.'
                : 'Keine Verbindung passt zu deinen Suchoptionen '
                      '— tippe oben auf Optionen und lockere sie.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return ListView.builder(
      // Clear both pieces of floating glass: the header above and the nav bar
      // below. Inside the scroll view, not around it — padding *inside* is what
      // lets the cards run on under the glass and keeps the viewport the full
      // height of the body, so scrolling reveals them behind it rather than
      // stopping at its edge.
      padding: EdgeInsets.only(
        top: _headerHeight,
        bottom: 32 + AppNavBar.insetOf(context),
      ),
      itemCount: journeys.length + 2,
      itemBuilder: (context, index) {
        if (index == 0) {
          return _paginationButton(
            context,
            'Früher',
            Icons.keyboard_arrow_up,
            state.result?.earlierRef != null ? notifier.loadEarlier : null,
          );
        }
        if (index == journeys.length + 1) {
          return _paginationButton(
            context,
            'Später',
            Icons.keyboard_arrow_down,
            state.result?.laterRef != null ? notifier.loadLater : null,
          );
        }
        return JourneyCard(
          journey: journeys[index - 1],
          fromResults: true,
        );
      },
    );
  }

  /// Explains what "Zuverlässigkeit" ranks by. Without it the order looks
  /// arbitrary — it's neither departure nor duration, and the number driving
  /// it lives in the per-connection badges further down.
  Widget _reliabilityNotice(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return _noticeCard(
      color: scheme.surfaceContainerHighest,
      children: [
        Icon(Icons.shield_outlined, size: 14, color: scheme.primary),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            'Sortiert nach Prognose: Anschluss erreicht & pünktlich an. '
            'Ohne Prognose stehen unten.',
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }

  /// A notice riding along in the floating header: inset and squircled like the
  /// glass around it, but *opaque*. These two carry a warning each — that the
  /// list is not what was asked for — and a colour is how they say so. Blurring
  /// the connections through them would trade the one thing they are for a
  /// texture.
  Widget _noticeCard({required Color color, required List<Widget> children}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
        decoration: ShapeDecoration(
          color: color,
          shape: const SquircleBorder(radius: 14),
        ),
        child: Row(children: children),
      ),
    );
  }

  /// The transfer profile asked DB for connections with enough slack and got
  /// none, so the list below is the unconstrained one (#19). Saying so beats
  /// both alternatives: an empty list hides connections that exist, and
  /// silently showing 5-minute changes to someone who set "Barrierearm" is the
  /// bug the profile was supposed to fix.
  Widget _relaxedNotice(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final profile = ref.watch(settingsProvider).transferProfile;
    return _noticeCard(
      color: scheme.tertiaryContainer,
      children: [
        Icon(Icons.info_outline, size: 14, color: scheme.onTertiaryContainer),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            'Keine Verbindung mit ${profile.minTransferMinutes} min '
            'Umstiegszeit (${profile.label}) — hier sind die knapperen.',
            style: TextStyle(fontSize: 11, color: scheme.onTertiaryContainer),
          ),
        ),
      ],
    );
  }

  /// Horizontal multimodal filter: one chip per transport category. The search
  /// already returns all modes; tapping a chip hides/shows that mode locally.
  Widget _productFilterBar(
    BuildContext context,
    JourneySearchState state,
    JourneySearchNotifier notifier,
  ) {
    return _glassStrip(
      children: [
        // Only meaningful for someone who holds the ticket, so it follows
        // the Deutschlandticket setting rather than sitting there dead.
        if (ref.watch(settingsProvider).hasDeutschlandTicket)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 3),
            child: FilterChip(
              label: const Text('Nur D-Ticket'),
              selected: state.onlyDeutschlandTicket,
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              onSelected: (_) => notifier.toggleOnlyDeutschlandTicket(),
            ),
          ),
        for (final cat in ProductCategory.values)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 3),
            child: FilterChip(
              label: Text(cat.label),
              selected: state.products.contains(cat),
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              onSelected: (_) => notifier.toggleProduct(cat),
            ),
          ),
      ],
    );
  }

  Widget _paginationButton(
    BuildContext context,
    String label,
    IconData icon,
    VoidCallback? onPressed,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 1),
      child: OutlinedButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, size: 18),
        label: Text(label),
        style: OutlinedButton.styleFrom(
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          minimumSize: const Size(0, 32),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ),
    );
  }

  PopupMenuEntry<JourneySortMode> _sortItem(
    JourneySortMode mode,
    String label,
    JourneySortMode current,
  ) {
    return PopupMenuItem(
      value: mode,
      child: Row(
        children: [
          if (mode == current)
            const Icon(Icons.check, size: 18)
          else
            const SizedBox(width: 18),
          const SizedBox(width: 8),
          Text(label),
        ],
      ),
    );
  }

  Future<void> _pickDateTime(BuildContext context, WidgetRef ref) async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: now,
      firstDate: now.subtract(const Duration(days: 1)),
      lastDate: now.add(const Duration(days: 90)),
    );
    if (date == null || !context.mounted) return;

    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(now),
    );
    if (time == null) return;

    final dt = DateTime(
      date.year,
      date.month,
      date.day,
      time.hour,
      time.minute,
    );
    ref.read(journeySearchProvider.notifier).setDateTime(dt);
  }
}

/// Reports its own laid-out height to [onHeight] whenever it changes.
///
/// This is what the results pad themselves by, so the floating header covers
/// nothing the rider needs to reach.
///
/// **Why measuring is safe here, when `AppNavBar.insetOf` may not.** The nav
/// bar deliberately reserves a *constant* footprint: its pill shrinks while the
/// rider scrolls, so a measured footprint would shorten every list, which moves
/// `maxScrollExtent`, which moves the scroll position, which decides whether
/// the pill shrinks — a layout driving its own input, and at the margin a
/// twitch. Nothing closes that loop here. This header's height depends on the
/// fold state, the saved routes, the filter chips and the text scale; the
/// results' padding cannot reach a single one of them (the fold is driven by
/// `resultSerial`, never by scrolling — see [_watchResults]). So the measure is
/// strictly one-way: it settles one frame after the header changes size and
/// stays settled, and in exchange no height has to be hardcoded and kept in
/// sync — which is what a fixed number would eventually fail to be.
class _MeasuredHeight extends SingleChildRenderObjectWidget {
  const _MeasuredHeight({required this.onHeight, required Widget super.child});

  final ValueChanged<double> onHeight;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderMeasuredHeight(onHeight);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderMeasuredHeight renderObject,
  ) {
    renderObject.onHeight = onHeight;
  }
}

class _RenderMeasuredHeight extends RenderProxyBox {
  _RenderMeasuredHeight(this.onHeight);

  ValueChanged<double> onHeight;

  /// The last height handed out — so a relayout that changes nothing (every
  /// scroll frame, for one) doesn't schedule a rebuild of the whole screen.
  double? _reported;

  @override
  void performLayout() {
    super.performLayout();
    if (_reported == size.height) return;
    _reported = size.height;
    // setState during layout is illegal; hand the number to the next frame.
    // That one frame of lag is invisible — while the form folds, the list's
    // padding trails the glass by 16 ms — and it is what keeps this a
    // measurement rather than a layout that rewrites itself mid-pass.
    WidgetsBinding.instance.addPostFrameCallback((_) => onHeight(size.height));
  }
}

/// Compact "Ab"/"An" (departure/arrival) toggle. Rolled by hand instead of
/// [SegmentedButton], whose selected fill renders a hair shorter than the
/// outline here and leaves an unfilled strip at the bottom. The selected
/// segment is a Container that fills the full pill height, so no gap is
/// possible. Sits in an IntrinsicHeight + stretch row, so it matches the
/// height of the time field and search button next to it.
class _AbAnToggle extends StatelessWidget {
  const _AbAnToggle({
    required this.useArrival,
    required this.arrivalEnabled,
    required this.onChanged,
  });

  final bool useArrival;
  final bool arrivalEnabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    Widget segment(String label, bool value, bool enabled) {
      final selected = useArrival == value;
      return InkWell(
        onTap: enabled && !selected ? () => onChanged(value) : null,
        borderRadius: BorderRadius.circular(9),
        child: Container(
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: selected ? cs.secondaryContainer : Colors.transparent,
            borderRadius: BorderRadius.circular(9),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              color: !enabled
                  ? cs.onSurface.withValues(alpha: 0.38)
                  : selected
                  ? cs.onSecondaryContainer
                  : cs.onSurfaceVariant,
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        border: Border.all(color: cs.outline),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          segment('Ab', false, true),
          const SizedBox(width: 2),
          segment('An', true, arrivalEnabled),
        ],
      ),
    );
  }
}
