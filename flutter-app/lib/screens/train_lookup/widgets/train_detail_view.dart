import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../models/coach_sequence.dart';
import '../../../models/trip.dart';
import 'coach_sequence_view.dart' show splitTrainBanner;
import 'seat_map_view.dart' show SeatPlanBody;
import 'stop_timeline.dart';
import 'train_info_header.dart';
import 'wagenreihung_screen.dart';

/// The full detail of one train: header, live map and stop timeline. Used
/// standalone on the train screen and stacked per leg in the connection view.
/// Returns column children (no Scaffold) so it can be embedded.
///
/// The Wagenreihung + free-seat plan no longer live inline (no dropdown): a
/// single tappable tile opens the dedicated fullscreen
/// [WagenreihungScreen], where the platform layout and the seats get the whole
/// screen and the free seats load straight away.
class TrainDetailView extends ConsumerStatefulWidget {
  final Trip trip;
  final CoachSequence? coach;
  final void Function(Stopover stop)? onStopTap;

  /// EVA / name of the stop you board at and alight at on this leg. When set,
  /// the timeline collapses stops outside that segment (e.g. the train's run
  /// before your boarding station). Null = standalone train, show all stops.
  final String? boardingId;
  final String? alightingId;

  /// Optional action rendered in the header next to the train name (the
  /// connection view passes its compact "Weitere Abfahrten" button here).
  final Widget? headerAction;

  /// Per-train reliability strip (Anschluss/Pünktlichkeit for this leg), shown
  /// in the inline train block. Only the connection leg view passes it.
  final Widget? predictionStrip;

  /// Station the user rides to on this leg — used to highlight the correct
  /// portion of a splitting train (Flügelzug) in the Wagenreihung. Null on a
  /// standalone train lookup.
  final String? legDestinationName;

  const TrainDetailView({
    super.key,
    required this.trip,
    this.coach,
    this.onStopTap,
    this.boardingId,
    this.alightingId,
    this.headerAction,
    this.predictionStrip,
    this.legDestinationName,
  });

  @override
  ConsumerState<TrainDetailView> createState() => _TrainDetailViewState();
}

class _TrainDetailViewState extends ConsumerState<TrainDetailView> {
  @override
  Widget build(BuildContext context) {
    final trip = widget.trip;
    final coach = widget.coach;
    final reservable = SeatPlanBody.isAvailableFor(trip);
    // There's something to open if we have a coach sequence to draw or a
    // reservable seat plan to show.
    final hasExtra = coach != null || reservable;

    // A leg of a connection (vs. a standalone train lookup) when an endpoint is
    // set — then the train header folds inline onto the route spine.
    final isLeg = widget.boardingId != null || widget.alightingId != null;

    // Wing-train (Flügelzug) guidance. On a leg it's hoisted up under the
    // boarding stop (where you decide which portion to board). Only a REAL
    // split (portions to different destinations) gets the red warning.
    final splitBanner = (isLeg && coach != null && coach.splits)
        ? splitTrainBanner(context, coach,
            targetDestination: widget.legDestinationName)
        : null;

    final Widget? trainExtra =
        hasExtra ? _wagenreihungTile(context, hasCoach: coach != null) : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // One block: train name/info + Halte timeline, in one card. On a leg
        // the header renders inline on the route line.
        StopTimeline(
          stopovers: trip.stopovers,
          onStopTap: widget.onStopTap,
          boardingId: widget.boardingId,
          alightingId: widget.alightingId,
          legAmenities: _legAmenities(trip, widget.coach),
          inlineHeader: true,
          header: TrainInfoHeader(
            trip: trip,
            coachSequence: widget.coach,
            action: widget.headerAction,
            embedded: true,
            padding: isLeg ? EdgeInsets.zero : null,
            predictionStrip: isLeg ? widget.predictionStrip : null,
            // Only a real leg passes board/alight, so the route map dims the
            // boarding portion at the boarding stop; standalone lookup → null.
            boardingId: widget.boardingId,
            alightingId: widget.alightingId,
          ),
          trainExtra: trainExtra,
          boardingBanner: splitBanner,
        ),
      ],
    );
  }

  /// The single entry point to the Wagenreihung + seat plan: tap → fullscreen.
  Widget _wagenreihungTile(BuildContext context, {required bool hasCoach}) {
    final theme = Theme.of(context);
    final title = hasCoach ? 'Wagenreihung & Sitzplätze' : 'Freie Sitzplätze';
    final subtitle = hasCoach
        ? 'Wagen, Abschnitte & freie Plätze ansehen'
        : 'Sitzplan & freie Plätze ansehen';
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      child: Material(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: _openFullscreen,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            child: Row(
              children: [
                Icon(Icons.train, size: 20, color: theme.colorScheme.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          style: theme.textTheme.titleSmall
                              ?.copyWith(fontWeight: FontWeight.bold)),
                      const SizedBox(height: 2),
                      Text(subtitle,
                          style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant)),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right,
                    size: 22, color: theme.colorScheme.onSurfaceVariant),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Open the dedicated fullscreen Wagenreihung + seat-plan screen. Pushed on
  /// the root navigator so it covers the tab shell with a real back button.
  void _openFullscreen() {
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => WagenreihungScreen(
          trip: widget.trip,
          sequence: widget.coach,
          targetDestination: widget.legDestinationName,
        ),
      ),
    );
  }

  /// Leg-wide amenities shown in the gap between the boarding and alighting
  /// stop. Primary source is the train's own `zugattribute` (bike,
  /// accessibility, AC, …) — present for an RE just as for an IC, regardless
  /// of whether a Wagenreihung exists. Family/quiet zones, which live only in
  /// the Wagenreihung, are merged in when available.
  List<({IconData icon, String label})> _legAmenities(
      Trip trip, CoachSequence? cs) {
    final out = <({IconData icon, String label})>[];
    final seen = <String>{};
    void add(IconData icon, String label) {
      if (label.isEmpty || !seen.add(label)) return;
      out.add((icon: icon, label: label));
    }

    for (final a in trip.attributes) {
      final icon = _attrIcon(a);
      if (icon != null) add(icon, a.value);
    }

    if (cs != null) {
      final coaches = cs.allCoaches;
      if (coaches.any((c) => c.hasFamilyZone)) {
        add(Icons.family_restroom, 'Familienbereich');
      }
      if (coaches.any((c) => c.hasQuietZone)) {
        add(Icons.volume_off, 'Ruhebereich');
      }
    }
    return out;
  }

  /// Icon for a train attribute, or null to skip it (reservation hints, the
  /// operator name, "Halt nur bei Bedarf" — not amenities worth a chip).
  IconData? _attrIcon(TripAttribute a) {
    switch (a.kategorie) {
      case 'FAHRRADMITNAHME':
        return Icons.directions_bike;
      case 'BARRIEREFREI':
        return Icons.accessible;
    }
    switch (a.key.toUpperCase()) {
      case 'EH': // Fahrzeuggebundene Einstiegshilfe
        return Icons.accessible;
      case 'KL': // Klimaanlage
        return Icons.ac_unit;
      case 'WV':
      case 'WL':
      case 'WI': // WLAN
        return Icons.wifi;
      case 'BR': // Bordrestaurant
      case 'BT': // Bordbistro
        return Icons.restaurant;
    }
    return null;
  }
}
