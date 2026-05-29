import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../models/coach_sequence.dart';
import '../../../models/seat_map.dart';
import '../../../models/trip.dart';
import '../../../providers/seat_map_provider.dart';
import 'coach_sequence_view.dart';
import 'seat_map_view.dart';
import 'stop_timeline.dart';
import 'train_info_header.dart';

/// The full detail of one train: header, live map, coach sequence and stop
/// timeline. Used standalone on the train screen and stacked per leg in the
/// connection view. Returns column children (no Scaffold) so it can be embedded.
///
/// For trains with a reservable seat plan, the free-seat view lives *inside*
/// the Wagenreihung card: the train doubles as the coach picker (selectable
/// cars + free-seat badges) and the selected coach's seat plan renders below
/// it — no separate "Freie Sitzplätze" section. Selection + class state live
/// here and feed both. When there's no Wagenreihung, the panel stands alone.
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
  bool _seatsExpanded = false; // free-seat panel starts collapsed
  int? _selectedWagon; // explicit user pick; null → auto (first free)

  @override
  Widget build(BuildContext context) {
    final trip = widget.trip;
    final reservable = SeatPlanBody.isAvailableFor(trip);

    // Only fetch the seat map once the panel is opened.
    final req = (reservable && _seatsExpanded)
        ? SeatMapRequest.fromTrip(trip)
        : null;
    final seatAsync = req != null ? ref.watch(seatMapProvider(req)) : null;
    final SeatMap? seatMap =
        seatAsync?.maybeWhen(data: (m) => m, orElse: () => null);

    // Free-seat count per wagon, and the effective selection (explicit pick or
    // first coach with free seats) shared by the Wagenreihung and the panel.
    final freeByWagon = <int, int>{};
    if (seatMap != null) {
      for (final c in seatMap.coaches) {
        final nr = int.tryParse(c.number);
        if (nr != null) freeByWagon[nr] = c.freeCount;
      }
    }
    final effectiveWagon = _effectiveWagon(seatMap);
    final hasWagenreihung = widget.coach != null;

    final seatPlan = reservable
        ? SeatPlanBody(
            trip: trip,
            expanded: _seatsExpanded,
            onToggle: () => setState(() => _seatsExpanded = !_seatsExpanded),
            seatAsync: seatAsync,
            selectedWagon: effectiveWagon,
            onSelectWagon: (nr) => setState(() => _selectedWagon = nr),
            hasExternalSelector: hasWagenreihung,
          )
        : null;

    // A leg of a connection (vs. a standalone train lookup) when an endpoint is
    // set — then the train header folds inline onto the route spine.
    final isLeg = widget.boardingId != null || widget.alightingId != null;

    // Wing-train (Flügelzug) guidance. On a leg it's hoisted up under the
    // boarding stop (where you decide which portion to board); otherwise it
    // stays inside the Wagenreihung card.
    final coach = widget.coach;
    final splitBanner = (isLeg && coach != null && coach.groups.length > 1)
        ? splitTrainBanner(context, coach,
            targetDestination: widget.legDestinationName)
        : null;

    // Wagenreihung (or, when there's none, the bare seat-plan panel) folded
    // INTO the train card as a sub-section, not a separate card.
    final Widget? trainExtra = widget.coach != null
        ? CoachSequenceView(
            sequence: widget.coach!,
            selectable: reservable && _seatsExpanded,
            freeByWagon: freeByWagon,
            selectedWagon: effectiveWagon,
            onCoachTap: (c) => setState(() => _selectedWagon = c.wagonNumber),
            seatPlan: seatPlan,
            embedded: true,
            targetDestination: widget.legDestinationName,
            showSplitBanner: !isLeg,
          )
        : seatPlan;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // One block: train name/info + Wagenreihung + Halte timeline, all in
        // one card. On a leg the header renders inline on the route line.
        StopTimeline(
          stopovers: trip.stopovers,
          onStopTap: widget.onStopTap,
          boardingId: widget.boardingId,
          alightingId: widget.alightingId,
          legAmenities: _legAmenities(trip, widget.coach),
          inlineHeader: true,
          header: TrainInfoHeader(
            trip: trip,
            action: widget.headerAction,
            embedded: true,
            padding: isLeg ? EdgeInsets.zero : null,
            predictionStrip: isLeg ? widget.predictionStrip : null,
          ),
          trainExtra: trainExtra,
          boardingBanner: splitBanner,
        ),
      ],
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

  int? _effectiveWagon(SeatMap? map) {
    if (_selectedWagon != null) return _selectedWagon;
    if (map == null) return null;
    for (final c in map.coaches) {
      if (c.hasFree) return int.tryParse(c.number);
    }
    return map.coaches.isNotEmpty ? int.tryParse(map.coaches.first.number) : null;
  }
}
