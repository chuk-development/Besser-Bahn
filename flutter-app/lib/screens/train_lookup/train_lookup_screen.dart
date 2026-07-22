import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../models/library_models.dart';
import '../../models/station.dart';
import '../../providers/library_provider.dart';
import '../../providers/station_map_provider.dart';
import '../../providers/train_lookup_provider.dart';
import '../../services/hafas_service.dart';
import '../../core/extensions.dart';
import '../../core/auto_refresh.dart';
import '../../widgets/bahnhof_search_bar.dart';
import '../../widgets/app_menu_button.dart';
import '../../widgets/app_nav_bar.dart';
import '../../widgets/station_search_field.dart';
import '../../widgets/traewelling_logo.dart';
import '../../widgets/trwl_checkin_sheet.dart';
import 'widgets/train_detail_view.dart';

class TrainLookupScreen extends ConsumerStatefulWidget {
  /// When embedded inside the combined "Bahnhof" screen, drop our own AppBar —
  /// the parent screen's floating switcher is the chrome there.
  final bool embedded;

  const TrainLookupScreen({super.key, this.embedded = false});

  @override
  ConsumerState<TrainLookupScreen> createState() => _TrainLookupScreenState();
}

class _TrainLookupScreenState extends ConsumerState<TrainLookupScreen>
    with AutoRefreshMixin {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  Station? _fromStation;
  bool _showStationField = false;

  /// Pending auto-search — see [_debounceDelay].
  Timer? _debounce;

  /// The query the last auto-search actually spent a lookup on. Stops a
  /// rebuild-triggered [_onQueryChanged] (the location toggle, a station pick)
  /// from sweeping the same text twice.
  String? _searchedQuery;

  /// How long the typed train number has to sit still before we look it up.
  ///
  /// The Bahnhof field looks up as you type, so this one does too (see
  /// [_onQueryChanged]) — but what the station field can take for granted and
  /// this one cannot is the network. `findTrainsByNumber` with no stop given
  /// sweeps FIVE major departure boards at once, and the /mob backend rate-
  /// limits per client for minutes once it has had enough. So: only a settled
  /// query, only one sweep per distinct query, and only a query that could name
  /// a train at all ([_looksLikeTrain]).
  static const _debounceDelay = Duration(milliseconds: 600);

  // Silently re-fetch the open train's live delays/platforms while the screen
  // is visible; keeps the current trip if a fetch fails (offline).
  @override
  Future<void> onAutoRefresh() =>
      ref.read(trainLookupProvider.notifier).refreshSilent();

  /// Whether [query] is worth a lookup: `findTrainsByNumber` throws away every
  /// non-digit and gives up on an empty number, so "ICE" is five requests for a
  /// guaranteed empty answer — exactly what a per-keystroke search must not do.
  static bool _looksLikeTrain(String query) =>
      query.length >= 2 && RegExp(r'\d').hasMatch(query);

  /// Typing: the field searches for itself, no button to press. Empties clear
  /// the result, so backspacing out of a train leaves the welcome screen rather
  /// than a stale one.
  void _onQueryChanged(String value) {
    _debounce?.cancel();
    final query = value.trim();
    if (query.isEmpty) {
      _searchedQuery = null;
      ref.read(trainLookupProvider.notifier).clear();
      return;
    }
    if (!_looksLikeTrain(query) || query == _searchedQuery) return;
    _debounce = Timer(_debounceDelay, () => _search(unfocus: false));
  }

  /// Look the typed train up now. [unfocus] closes the keyboard — right for a
  /// submit or a station pick, wrong for the debounce, which fires *while* the
  /// rider is still in the field.
  void _search({bool unfocus = true}) {
    _debounce?.cancel();
    final query = _controller.text.trim();
    if (query.isEmpty) return;
    _searchedQuery = query;
    if (unfocus) _focusNode.unfocus();
    ref.read(trainLookupProvider.notifier).lookupTrain(
          query,
          fromStationId: _fromStation?.id,
        );
  }

  SavedTrain _savedTrainFor(TrainLookupState state) {
    final trip = state.trip!;
    final typed = _controller.text.trim();
    final query = typed.isNotEmpty ? typed : trip.line.displayName;
    return SavedTrain(
      query: query,
      label: '${trip.line.displayName} → ${trip.destination.name}',
      fromStationId: _fromStation?.id,
    );
  }

  void _lookupSaved(SavedTrain train) {
    _debounce?.cancel();
    _controller.text = train.query;
    _searchedQuery = train.query;
    _focusNode.unfocus();
    ref.read(trainLookupProvider.notifier).lookupTrain(
          train.query,
          fromStationId: train.fromStationId,
        );
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(trainLookupProvider);
    final theme = Theme.of(context);

    // What this screen can do with the train it has open. They ride in the
    // search row (below) rather than in an AppBar or a strip of their own: this
    // screen is one field and one train, and the field's row is where the
    // rider's eye already is.
    final actions = <Widget>[
      if (state.trip != null)
        Builder(builder: (context) {
          final train = _savedTrainFor(state);
          final saved = ref.watch(libraryProvider).hasTrain(train.key);
          return IconButton(
            visualDensity: VisualDensity.compact,
            icon: Icon(saved ? Icons.star : Icons.star_border,
                color: saved ? Colors.amber.shade700 : null),
            tooltip: saved ? 'Zug entfernen' : 'Zug speichern',
            onPressed: () {
              ref.read(libraryProvider.notifier).toggleTrain(train);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  duration: const Duration(seconds: 2),
                  content: Text(saved ? 'Zug entfernt' : 'Zug gespeichert'),
                ),
              );
            },
          );
        }),
      if (state.trip != null)
        IconButton(
          visualDensity: VisualDensity.compact,
          icon: const TraewellingLogo(size: 22),
          tooltip: 'In Träwelling einchecken',
          onPressed: () => startTrwlCheckin(context, ref, state.trip!),
        ),
      if (state.trip != null)
        IconButton(
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.refresh),
          tooltip: 'Aktualisieren',
          onPressed: () => ref.read(trainLookupProvider.notifier).refresh(),
        ),
    ];

    return Scaffold(
      appBar: widget.embedded
          ? null
          : AppBar(
              title: const Text('Zugnummer'),
              actions: const [AppMenuButton()],
            ),
      body: Column(
        children: [
          // Search bar — the shared Bahnhof search bar (same on Abfahrten/Karte).
          BahnhofSearchBar(
            trailing: actions,
            child: TextField(
              controller: _controller,
              focusNode: _focusNode,
              style: const TextStyle(fontSize: 14),
              decoration: InputDecoration(
                isDense: true,
                filled: false,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                hintText: 'z.B. ICE 148, RE 70, Bus 310',
                prefixIcon: const Icon(Icons.train, size: 18),
                prefixIconConstraints:
                    const BoxConstraints(minWidth: 36, minHeight: 36),
                // Keep the suffix inside the dense field's height (an
                // unconstrained IconButton is 48 px and taller than the field,
                // which made the Zug search bar bigger than the other two).
                suffixIconConstraints:
                    const BoxConstraints(minWidth: 36, minHeight: 36),
                // The spinner takes the suffix while a lookup runs — with no
                // search button left, this is the only place the field itself
                // can say it is working.
                suffixIcon: state.isLoading
                    ? const Padding(
                        padding: EdgeInsets.all(9),
                        child: SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : IconButton(
                        visualDensity: VisualDensity.compact,
                        icon: Icon(
                          _showStationField
                              ? Icons.location_off
                              : Icons.location_on_outlined,
                          size: 18,
                        ),
                        tooltip: 'Haltestelle angeben (für Busse)',
                        onPressed: () {
                          setState(() {
                            _showStationField = !_showStationField;
                            if (!_showStationField) {
                              _fromStation = null;
                            }
                          });
                        },
                      ),
              ),
                textInputAction: TextInputAction.search,
                onChanged: _onQueryChanged,
                // Still honoured, and it beats the debounce: a rider who
                // hits Enter has said they are done typing.
                onSubmitted: (_) => _search(),
              ),
            ),
          // Optional station field for buses/trams
          if (_showStationField)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Column(
                children: [
                  StationSearchField(
                    hint: 'Ab Haltestelle (für Busse/Tram)',
                    prefixIcon: Icons.location_on,
                    initialStation: _fromStation,
                    dense: true,
                    onSelected: (station) {
                      setState(() => _fromStation = station);
                      // The stop is half the query — re-run it, the same way
                      // picking a station re-runs the Abfahrten board. Cheap:
                      // with a stop given the lookup reads one board, not five.
                      if (_controller.text.trim().isNotEmpty) _search();
                    },
                  ),
                  if (_fromStation != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Row(
                        children: [
                          Icon(Icons.check_circle, size: 14,
                              color: theme.colorScheme.primary),
                          const SizedBox(width: 4),
                          Text(
                            _fromStation!.name,
                            style: TextStyle(
                              fontSize: 12,
                              color: theme.colorScheme.primary,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),

          _buildSavedTrains(context),

          const SizedBox(height: 8),

          // Content
          Expanded(
            child: _buildContent(context, state, theme),
          ),
        ],
      ),
    );
  }

  Widget _buildSavedTrains(BuildContext context) {
    final trains = ref.watch(libraryProvider).trains;
    if (trains.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        itemCount: trains.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final train = trains[index];
          return ActionChip(
            avatar: const Icon(Icons.star, size: 16),
            label: Text(train.label, overflow: TextOverflow.ellipsis),
            onPressed: () => _lookupSaved(train),
          );
        },
      ),
    );
  }

  Widget _buildContent(
      BuildContext context, TrainLookupState state, ThemeData theme) {
    if (state.isLoading) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Suche läuft...'),
          ],
        ),
      );
    }

    if (state.error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.search_off, size: 48,
                  color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(height: 16),
              Text(state.error!,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyLarge),
              if (_fromStation == null) ...[
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: () {
                    setState(() => _showStationField = true);
                  },
                  icon: const Icon(Icons.location_on_outlined, size: 18),
                  label: const Text('Haltestelle angeben'),
                ),
              ],
            ],
          ),
        ),
      );
    }

    // Multiple results - show picker
    if (state.searchResults.isNotEmpty) {
      return _buildSearchResults(context, state.searchResults, theme);
    }

    // No trip loaded yet - show welcome
    if (state.trip == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.train, size: 64,
                  color: theme.colorScheme.onSurfaceVariant.withAlpha(80)),
              const SizedBox(height: 16),
              Text(
                'Zugnummer eingeben',
                style: theme.textTheme.titleMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 8),
              Text(
                'Live-Position, Verspätungen, Gleiswechsel\nund Wagenreihung auf einen Blick.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 16),
              Text(
                'Tipp: Für Busse & Tram tippe auf 📍 um eine Haltestelle anzugeben.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      );
    }

    final trip = state.trip!;

    return RefreshIndicator(
      onRefresh: () => ref.read(trainLookupProvider.notifier).refresh(),
      child: ListView(
        // Clear the floating nav bar — it hovers over this list.
        padding: EdgeInsets.only(bottom: 32 + AppNavBar.insetOf(context)),
        children: [
          TrainDetailView(
            trip: trip,
            coach: state.coachSequence,
            onStopTap: (stop) {
              if (stop.stop.name.isEmpty) return;
              ref.read(dedicatedStationMapProvider.notifier).loadForStation(
                    stop.stop,
                    highlightGleis: stop.platform,
                    role: stop.isTerminus
                        ? GleisRole.alight
                        : stop.isOrigin
                            ? GleisRole.board
                            : GleisRole.none,
                    // The map fetches this train's Wagenreihung for this stop,
                    // so the to-scale train shows at every stop.
                    coachRef: trip.line.fahrtNr.isNotEmpty
                        ? (
                            category: trip.line.productName,
                            trainNumber: trip.line.fahrtNr,
                            // Scheduled — keyed by service date (#32).
                            time: stop.sequenceTime,
                          )
                        : null,
                    trainLabel: trip.line.displayName,
                    primaryTypes:
                        primaryPoiTypesForProduct(trip.line.product),
                  );
              // push (not go) → full-screen with a back button + swipe-back.
              context.push('/station-map');
            },
          ),
        ],
      ),
    );
  }

  Widget _buildSearchResults(BuildContext context,
      List<TrainSearchResult> results, ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Text(
            '${results.length} Ergebnisse – bitte auswählen:',
            style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: results.length,
            itemBuilder: (context, index) {
              final result = results[index];
              return Card(
                margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 3),
                child: ListTile(
                  leading: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      result.product.isNotEmpty
                          ? result.product
                          : result.lineName,
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                        color: theme.colorScheme.onPrimaryContainer,
                      ),
                    ),
                  ),
                  title: Text(result.lineName,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text('→ ${result.direction}'),
                  trailing: result.plannedWhen != null
                      ? Text(
                          result.plannedWhen!.hhmm,
                          style: theme.textTheme.bodyLarge
                              ?.copyWith(fontWeight: FontWeight.w500),
                        )
                      : null,
                  onTap: () {
                    ref
                        .read(trainLookupProvider.notifier)
                        .selectSearchResult(result);
                  },
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
