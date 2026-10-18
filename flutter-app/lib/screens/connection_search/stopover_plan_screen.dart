import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../models/journey.dart';
import '../../models/library_models.dart';
import '../../providers/library_provider.dart';
import '../../providers/stopover_plan_provider.dart';
import '../../utils/stopover_plan.dart';
import 'widgets/journey_card.dart';
import '../../core/extensions.dart';

/// "Ich muss um 09:48 beim Zahnarzt sein — und die Wartezeit vorher ist mir
/// recht."
///
/// One trip, deliberately broken in two at a hub. The second leg is nailed to
/// the appointment (the latest train that still makes it); the first is free to
/// be hours earlier, and the gap in between is the feature, not a cost. DB's own
/// search cannot express this: it chains the legs and minimises exactly the gap
/// this rider wants.
class StopoverPlanScreen extends ConsumerWidget {
  const StopoverPlanScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(stopoverPlanProvider);
    final notifier = ref.read(stopoverPlanProvider.notifier);
    final args = state.args;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Aufenthalt einplanen'),
        actions: [
          if (args != null)
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'Neu suchen',
              onPressed: state.isLoading ? null : notifier.load,
            ),
        ],
      ),
      body: args == null
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  'Kein Zwischenstopp gewählt. Öffne eine Verbindung und tippe '
                  'am Umstieg auf „Aufenthalt einplanen".',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : _PlanBody(state: state, notifier: notifier, args: args),
      bottomNavigationBar: _SaveBar(state: state),
    );
  }
}

class _PlanBody extends StatelessWidget {
  const _PlanBody({
    required this.state,
    required this.notifier,
    required this.args,
  });

  final StopoverPlanState state;
  final StopoverPlanNotifier notifier;
  final StopoverPlanArgs args;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final second = state.secondLeg;

    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        _RouteCard(args: args, notifier: notifier),
        _StayPicker(state: state, notifier: notifier),
        if (state.isLoading)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: LinearProgressIndicator(minHeight: 2),
          ),
        if (state.error != null)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              state.error!,
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ),

        // Etappe 2 first, because it is the fixed one: everything else is
        // planned backwards from the train that has to make the appointment.
        if (second != null) ...[
          _SectionHeader(
            index: 2,
            title: 'Zum Termin',
            subtitle:
                '${args.hub.name} → ${args.to.name} · '
                'spätestens ${DateFormat('HH:mm').format(args.deadline)} da',
          ),
          JourneyCard(
            journey: second,
            // An explicit onTap keeps the card out of "result list" mode: the
            // highlights and the Puffer badge belong to a search, and this is
            // one fixed leg.
            onTap: () => context.push('/connection', extra: second),
          ),
          _StayStrip(state: state, hubName: args.hub.name),
          _SectionHeader(
            index: 1,
            title: 'Hinfahrt zum Zwischenstopp',
            subtitle:
                '${args.from.name} → ${args.hub.name} · '
                'früher fahren = mehr Zeit',
          ),
          ..._firstLegRows(context),
        ],
      ],
    );
  }

  List<Widget> _firstLegRows(BuildContext context) {
    final second = state.secondLeg!;
    if (state.firstOptions.isEmpty) {
      return [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            state.isLoading
                ? 'Suche Hinfahrten …'
                : state.hiddenFirstCount > 0
                ? 'Keine Hinfahrt mit ${state.stayMinutes} min Aufenthalt '
                      '— ${state.hiddenFirstCount} kämen knapper an. '
                      'Kürzeren Aufenthalt wählen.'
                : 'Keine Hinfahrt gefunden.',
          ),
        ),
        if (state.firstEarlierRef != null) _earlierButton(),
      ];
    }
    return [
      // Earlier at the top, where the earliest option already is — one more tap
      // in the same direction the list runs.
      if (state.firstEarlierRef != null) _earlierButton(),
      for (final j in state.firstOptions)
        _FirstLegOption(
          journey: j,
          second: second,
          selected: identical(j, state.firstLeg),
          onSelect: () => notifier.selectFirstLeg(j),
        ),
    ];
  }

  Widget _earlierButton() => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
    child: OutlinedButton.icon(
      onPressed: state.isLoading ? null : notifier.loadEarlierFirstLegs,
      icon: const Icon(Icons.keyboard_arrow_up, size: 18),
      label: const Text('Früher — noch mehr Zeit'),
    ),
  );
}

/// From → hub → to plus the appointment, which is the one number here the rider
/// sets themselves.
class _RouteCard extends StatelessWidget {
  const _RouteCard({required this.args, required this.notifier});

  final StopoverPlanArgs args;
  final StopoverPlanNotifier notifier;

  Future<void> _pickDeadline(BuildContext context) async {
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(args.deadline),
      helpText: 'Wann musst du da sein?',
    );
    if (picked == null) return;
    notifier.setDeadline(
      DateTime(
        args.deadline.year,
        args.deadline.month,
        args.deadline.day,
        picked.hour,
        picked.minute,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _routeLine(theme, Icons.trip_origin, args.from.name),
            _routeLine(
              theme,
              Icons.pause_circle_outline,
              args.hub.name,
              accent: true,
            ),
            _routeLine(theme, Icons.location_on, args.to.name),
            const Divider(height: 16),
            InkWell(
              onTap: () => _pickDeadline(context),
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    Icon(
                      Icons.event_available,
                      size: 18,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Da sein um '
                        '${DateFormat('HH:mm').format(args.deadline)}'
                        ' · ${DateFormat('dd.MM.').format(args.deadline.berlin)}',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const Icon(Icons.edit, size: 16),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _routeLine(
    ThemeData theme,
    IconData icon,
    String name, {
    bool accent = false,
  }) {
    final color = accent
        ? theme.colorScheme.primary
        : theme.colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: accent ? FontWeight.w700 : FontWeight.w500,
                color: accent ? theme.colorScheme.primary : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// How long the rider wants at the hub — the minimum, never the exact stay: the
/// timetable decides the rest, and every option says what it really gives.
class _StayPicker extends StatelessWidget {
  const _StayPicker({required this.state, required this.notifier});

  final StopoverPlanState state;
  final StopoverPlanNotifier notifier;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
        child: Row(
          children: [
            const Padding(
              padding: EdgeInsets.only(right: 8),
              child: Text(
                'Mind. Aufenthalt',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
              ),
            ),
            for (final m in kStayChoices)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 3),
                child: ChoiceChip(
                  label: Text(formatStay(Duration(minutes: m))),
                  selected: state.stayMinutes == m,
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  onSelected: (_) => notifier.setStayMinutes(m),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The gap itself, drawn as its own block between the two legs — this is what
/// the screen exists for, so it is not a footnote on a card.
class _StayStrip extends StatelessWidget {
  const _StayStrip({required this.state, required this.hubName});

  final StopoverPlanState state;
  final String hubName;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final stay = state.plannedStay;
    final hubDeparture = state.hubDeparture;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(
            Icons.free_breakfast_outlined,
            size: 18,
            color: theme.colorScheme.onSecondaryContainer,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  stay != null
                      ? 'Aufenthalt in $hubName: ${formatStay(stay)}'
                      : 'Aufenthalt in $hubName: '
                            'mind. ${formatStay(Duration(minutes: state.stayMinutes))}',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: theme.colorScheme.onSecondaryContainer,
                  ),
                ),
                if (hubDeparture != null)
                  Text(
                    stay != null
                        ? 'Weiter um ${DateFormat('HH:mm').format(hubDeparture)}'
                        : 'Hinfahrt unten wählen · weiter um '
                              '${DateFormat('HH:mm').format(hubDeparture)}',
                    style: TextStyle(
                      fontSize: 11,
                      color: theme.colorScheme.onSecondaryContainer,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.index,
    required this.title,
    required this.subtitle,
  });

  final int index;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Row(
        children: [
          Container(
            width: 22,
            height: 22,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: theme.colorScheme.primary,
              shape: BoxShape.circle,
            ),
            child: Text(
              '$index',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: theme.colorScheme.onPrimary,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Etappe $index · $title',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 11,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One candidate for the ride to the hub, with the stay it buys stated on it —
/// the number the rider is actually choosing between.
class _FirstLegOption extends StatelessWidget {
  const _FirstLegOption({
    required this.journey,
    required this.second,
    required this.selected,
    required this.onSelect,
  });

  final Journey journey;
  final Journey second;
  final bool selected;
  final VoidCallback onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final stay = stayBetween(journey, second);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: onSelect,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
            child: Row(
              children: [
                Icon(
                  selected
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  size: 18,
                  color: selected
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    stay != null
                        ? '${formatStay(stay)} Aufenthalt'
                        : 'Aufenthalt unbekannt',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: selected ? theme.colorScheme.primary : null,
                    ),
                  ),
                ),
                if (selected)
                  Text(
                    'gewählt',
                    style: TextStyle(
                      fontSize: 11,
                      color: theme.colorScheme.primary,
                    ),
                  ),
              ],
            ),
          ),
        ),
        JourneyCard(
          journey: journey,
          onTap: () => context.push('/connection', extra: journey),
        ),
      ],
    );
  }
}

/// Saves both halves as two separate trips — which is the whole idea: they are
/// not one connection, and the Reiseplan should not pretend otherwise.
class _SaveBar extends ConsumerWidget {
  const _SaveBar({required this.state});

  final StopoverPlanState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final first = state.firstLeg;
    final second = state.secondLeg;
    if (second == null) return const SizedBox.shrink();
    final stay = state.plannedStay;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: FilledButton.icon(
          onPressed: first == null
              ? null
              : () => _save(context, ref, first, second),
          icon: const Icon(Icons.bookmark_add_outlined),
          label: Text(
            first == null
                ? 'Hinfahrt wählen'
                : stay != null
                ? 'Beide Etappen speichern (${formatStay(stay)} Pause)'
                : 'Beide Etappen speichern',
          ),
        ),
      ),
    );
  }

  void _save(
    BuildContext context,
    WidgetRef ref,
    Journey first,
    Journey second,
  ) {
    final library = ref.read(libraryProvider);
    final notifier = ref.read(libraryProvider.notifier);
    var added = 0;
    for (final journey in [first, second]) {
      final key = SavedJourney(journey: journey, savedAtMs: 0).key;
      // Adding, not toggling: a leg already in the Reiseplan must stay there —
      // a toggle would remove it and leave half a plan behind.
      if (!library.hasJourney(key)) {
        notifier.toggleJourney(journey);
        added++;
      }
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 3),
        content: Text(
          added == 0
              ? 'Beide Etappen sind schon im Reiseplan.'
              : 'Als $added einzelne Etappe${added > 1 ? 'n' : ''} '
                    'im Reiseplan — nicht als eine Verbindung.',
        ),
      ),
    );
  }
}
