import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../models/library_models.dart';
import '../../providers/journey_search_provider.dart';
import '../../providers/library_provider.dart';
import '../../widgets/station_search_field.dart';
import '../../widgets/app_menu_button.dart';
import 'widgets/journey_card.dart';

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

  @override
  void dispose() {
    _fromController.dispose();
    _toController.dispose();
    super.dispose();
  }

  void _search() {
    final notifier = ref.read(journeySearchProvider.notifier);
    notifier.search(
      fromText: _fromController.text,
      toText: _toController.text,
    );
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
            Builder(builder: (context) {
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
                      content: Text(saved
                          ? 'Route entfernt'
                          : 'Route gespeichert'),
                    ),
                  );
                },
              );
            }),
          if (state.result != null)
            PopupMenuButton<JourneySortMode>(
              icon: const Icon(Icons.sort),
              tooltip: 'Sortierung',
              onSelected: notifier.setSortMode,
              itemBuilder: (_) => [
                _sortItem(
                    JourneySortMode.departure, 'Abfahrt', state.sortMode),
                _sortItem(JourneySortMode.arrival, 'Ankunft', state.sortMode),
                _sortItem(JourneySortMode.duration, 'Dauer', state.sortMode),
                _sortItem(
                    JourneySortMode.transfers, 'Umstiege', state.sortMode),
              ],
            ),
        ],
      ),
      body: Column(
        children: [
          // Search form
          Card(
            margin: const EdgeInsets.fromLTRB(12, 6, 12, 0),
            child: Padding(
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
                                    minWidth: 34, minHeight: 34),
                                contentPadding: EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 8),
                              ),
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: Text(
                                  state.dateTime != null
                                      ? DateFormat('dd.MM. HH:mm')
                                          .format(state.dateTime!)
                                      : 'Jetzt',
                                  style: theme.textTheme.bodyMedium,
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 4),
                        SegmentedButton<bool>(
                          style: SegmentedButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            padding: const EdgeInsets.symmetric(horizontal: 6),
                            tapTargetSize:
                                MaterialTapTargetSize.shrinkWrap,
                          ),
                          segments: const [
                            ButtonSegment(value: false, label: Text('Ab')),
                            ButtonSegment(value: true, label: Text('An')),
                          ],
                          selected: {state.isArrival},
                          onSelectionChanged: (v) =>
                              notifier.setIsArrival(v.first),
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
                                borderRadius: BorderRadius.circular(12)),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          onPressed: state.isLoading ? null : _search,
                          child: state.isLoading
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2, color: Colors.white),
                                )
                              : const Icon(Icons.search, size: 24),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),

          _buildSavedRoutes(context),

          // Results
          Expanded(child: _buildResults(context, state, notifier)),
        ],
      ),
    );
  }

  Widget _buildSavedRoutes(BuildContext context) {
    final routes = ref.watch(libraryProvider).routes;
    if (routes.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        itemCount: routes.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final route = routes[index];
          return ActionChip(
            avatar: const Icon(Icons.bookmark, size: 16),
            label: Text(
              '${route.from.name} → ${route.to.name}',
              overflow: TextOverflow.ellipsis,
            ),
            onPressed: () => _applyRoute(route),
          );
        },
      ),
    );
  }

  Widget _buildResults(BuildContext context, JourneySearchState state,
      JourneySearchNotifier notifier) {
    if (state.error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, size: 40,
                  color: Theme.of(context).colorScheme.error),
              const SizedBox(height: 12),
              Text(state.error!,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: Theme.of(context).colorScheme.error)),
            ],
          ),
        ),
      );
    }

    if (state.result == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text('Start und Ziel eingeben, um Verbindungen zu suchen.',
              textAlign: TextAlign.center),
        ),
      );
    }

    final journeys = state.sortedJourneys;
    if (journeys.isEmpty) {
      return const Center(child: Text('Keine Verbindungen gefunden.'));
    }

    return ListView.builder(
      padding: const EdgeInsets.only(top: 8, bottom: 32),
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
        return JourneyCard(journey: journeys[index - 1]);
      },
    );
  }

  Widget _paginationButton(BuildContext context, String label, IconData icon,
      VoidCallback? onPressed) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: OutlinedButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, size: 18),
        label: Text(label),
      ),
    );
  }

  PopupMenuEntry<JourneySortMode> _sortItem(
      JourneySortMode mode, String label, JourneySortMode current) {
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

    final dt =
        DateTime(date.year, date.month, date.day, time.hour, time.minute);
    ref.read(journeySearchProvider.notifier).setDateTime(dt);
  }
}
