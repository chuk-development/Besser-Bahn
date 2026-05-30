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
import '../../widgets/app_menu_button.dart';
import '../../widgets/embedded_action_bar.dart';
import '../../widgets/station_search_field.dart';
import '../../widgets/traewelling_logo.dart';
import '../../widgets/trwl_checkin_sheet.dart';
import 'widgets/train_detail_view.dart';

class TrainLookupScreen extends ConsumerStatefulWidget {
  /// When embedded inside the combined "Bahnhof" screen, drop our own AppBar
  /// (the parent provides one + the tab bar) and surface the AppBar actions as
  /// a slim row at the top of the body instead.
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

  // Silently re-fetch the open train's live delays/platforms while the screen
  // is visible; keeps the current trip if a fetch fails (offline).
  @override
  Future<void> onAutoRefresh() =>
      ref.read(trainLookupProvider.notifier).refreshSilent();

  void _search() {
    final query = _controller.text.trim();
    if (query.isEmpty) return;
    _focusNode.unfocus();
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
    _controller.text = train.query;
    _focusNode.unfocus();
    ref.read(trainLookupProvider.notifier).lookupTrain(
          train.query,
          fromStationId: train.fromStationId,
        );
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(trainLookupProvider);
    final theme = Theme.of(context);

    // AppBar actions, reused inline when embedded in the combined screen.
    final actions = <Widget>[
      if (state.trip != null)
        Builder(builder: (context) {
          final train = _savedTrainFor(state);
          final saved = ref.watch(libraryProvider).hasTrain(train.key);
          return IconButton(
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
          icon: const TraewellingLogo(size: 22),
          tooltip: 'In Träwelling einchecken',
          onPressed: () => startTrwlCheckin(context, ref, state.trip!),
        ),
      if (state.trip != null)
        IconButton(
          icon: const Icon(Icons.refresh),
          onPressed: () => ref.read(trainLookupProvider.notifier).refresh(),
        ),
    ];

    return Scaffold(
      appBar: widget.embedded
          ? null
          : AppBar(
              title: const Text('Zugnummer'),
              actions: [const AppMenuButton(), ...actions],
            ),
      body: Column(
        children: [
          if (widget.embedded && actions.isNotEmpty)
            EmbeddedActionBar(actions: actions),
          // Search bar
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _controller,
                        focusNode: _focusNode,
                        decoration: InputDecoration(
                          hintText: 'z.B. ICE 148, RE 70, S3, Bus 310...',
                          prefixIcon: const Icon(Icons.train),
                          suffixIcon: IconButton(
                            icon: Icon(
                              _showStationField
                                  ? Icons.location_off
                                  : Icons.location_on_outlined,
                              size: 20,
                            ),
                            tooltip: 'Haltestelle angeben (für Busse)',
                            onPressed: () {
                              setState(() {
                                _showStationField = !_showStationField;
                                if (!_showStationField) _fromStation = null;
                              });
                            },
                          ),
                        ),
                        textInputAction: TextInputAction.search,
                        onSubmitted: (_) => _search(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: state.isLoading ? null : _search,
                      child: state.isLoading
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white),
                            )
                          : const Icon(Icons.search),
                    ),
                  ],
                ),
                // Optional station field for buses/trams
                if (_showStationField) ...[
                  const SizedBox(height: 8),
                  StationSearchField(
                    hint: 'Ab Haltestelle (für Busse/Tram)',
                    prefixIcon: Icons.location_on,
                    initialStation: _fromStation,
                    onSelected: (station) {
                      setState(() => _fromStation = station);
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
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          TrainDetailView(
            trip: trip,
            coach: state.coachSequence,
            onStopTap: (stop) {
              if (stop.stop.name.isEmpty) return;
              // The Wagenreihung is fetched for the train's current/next stop —
              // only draw the to-scale train on the map of THAT stop.
              final cs = state.coachSequence;
              final seqStop = trip.currentStop ?? trip.stopovers.firstOrNull;
              final atSeqStop = cs != null &&
                  seqStop != null &&
                  stop.stop.id.isNotEmpty &&
                  stop.stop.id == seqStop.stop.id;
              ref.read(stationMapProvider.notifier).loadForStation(
                    stop.stop,
                    highlightGleis: stop.platform,
                    role: stop.isTerminus
                        ? GleisRole.alight
                        : stop.isOrigin
                            ? GleisRole.board
                            : GleisRole.none,
                    coachSequence: atSeqStop ? cs : null,
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
