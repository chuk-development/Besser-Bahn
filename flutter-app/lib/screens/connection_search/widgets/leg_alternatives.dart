import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/extensions.dart';
import '../../../models/journey.dart';
import '../../../providers/service_providers.dart';
import '../../../providers/train_lookup_provider.dart';
import '../../../services/vendo_service.dart';
import '../../../widgets/occupancy_indicator.dart';

/// "Weitere Abfahrten" expander for one journey leg: lazily fetches the
/// alternative trains of the same product group running this exact segment
/// (arriving by the leg's arrival), lists them DB-Navigator style, and opens a
/// tapped train's full Zugdetails. "Mehr anzeigen" pages further out.
class LegAlternatives extends ConsumerStatefulWidget {
  final JourneyLeg leg;
  const LegAlternatives({super.key, required this.leg});

  @override
  ConsumerState<LegAlternatives> createState() => _LegAlternativesState();
}

class _LegAlternativesState extends ConsumerState<LegAlternatives> {
  bool _expanded = false;
  bool _loading = false;
  String? _error;
  String? _laterRef;
  final List<Journey> _alts = [];

  Future<void> _toggle() async {
    setState(() => _expanded = !_expanded);
    if (_expanded && _alts.isEmpty && !_loading) await _fetch();
  }

  Future<void> _fetch({String? context}) async {
    final leg = widget.leg;
    final from = leg.origin.vendoLocationId;
    final to = leg.destination.vendoLocationId;
    final an = leg.plannedArrival ?? leg.arrival;
    if (an == null || from.isEmpty || to.isEmpty) {
      setState(() => _error = 'Nicht verfügbar.');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await ref.read(vendoServiceProvider).fetchWeitereAbfahrten(
            abgangsLocationId: from,
            zielLocationId: to,
            ankunft: an,
            produktGattungen:
                VendoService.produktGattungenFor(leg.line?.product),
            context: context,
          );
      if (!mounted) return;
      setState(() {
        final seen = _alts
            .map((j) => j.legs.firstOrNull?.tripId)
            .whereType<String>()
            .toSet();
        for (final j in res.journeys) {
          final id = j.legs.firstOrNull?.tripId;
          if (id != null && !seen.add(id)) continue;
          _alts.add(j);
        }
        _laterRef = res.laterRef;
      });
    } catch (_) {
      if (mounted) setState(() => _error = 'Konnte nicht laden.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Open the tapped alternative's full Zugdetails (same view as the train tab).
  void _open(Journey alt) {
    final l = alt.legs.firstOrNull;
    if (l == null) return;
    final number = (l.line?.fahrtNr.isNotEmpty ?? false)
        ? l.line!.fahrtNr
        : l.line?.displayName ?? '';
    if (number.isEmpty) return;
    ref.read(trainLookupProvider.notifier).lookupTrain(
          number,
          fromStationId: l.origin.id.isNotEmpty ? l.origin.id : null,
        );
    context.push('/train-run');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: _toggle,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  Icon(Icons.departure_board, size: 18, color: primary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Weitere Abfahrten',
                      style: theme.textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.bold),
                    ),
                  ),
                  Icon(_expanded ? Icons.expand_less : Icons.expand_more,
                      size: 20, color: primary),
                ],
              ),
            ),
          ),
          if (_expanded) ...[
            const Divider(height: 1),
            if (_loading && _alts.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 20),
                child: Center(
                  child: SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2)),
                ),
              )
            else if (_error != null && _alts.isEmpty)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(_error!,
                    style: TextStyle(color: theme.colorScheme.error)),
              )
            else if (_alts.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('Keine weiteren Abfahrten.'),
              )
            else
              ...List.generate(_alts.length, (i) {
                return Column(
                  children: [
                    if (i != 0) const Divider(height: 1, indent: 16),
                    _altRow(context, _alts[i]),
                  ],
                );
              }),
            if (_laterRef != null && _alts.isNotEmpty)
              InkWell(
                onTap:
                    _loading ? null : () => _fetch(context: _laterRef),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (_loading)
                        const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2))
                      else
                        Icon(Icons.expand_more, size: 18, color: primary),
                      const SizedBox(width: 8),
                      Text('Mehr anzeigen',
                          style: theme.textTheme.bodyMedium?.copyWith(
                              color: primary, fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }

  /// One alternative departure: dep/arr times (planned + realtime), the line
  /// badge with occupancy, the train's direction, and its platform.
  Widget _altRow(BuildContext context, Journey alt) {
    final leg = alt.legs.firstOrNull;
    if (leg == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final dest = (leg.direction?.trim().isNotEmpty ?? false)
        ? leg.direction!.trim()
        : leg.destination.name;
    final platform = leg.departurePlatform ?? leg.plannedDeparturePlatform;
    final name = leg.line?.titleWithNumber ?? leg.line?.displayName ?? '';

    return InkWell(
      onTap: () => _open(alt),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 54,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  _timeCell(theme, leg.plannedDeparture, leg.departure,
                      leg.departureDelay, bold: true),
                  const SizedBox(height: 4),
                  _timeCell(theme, leg.plannedArrival, leg.arrival,
                      leg.arrivalDelay, bold: false),
                ],
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      if (name.isNotEmpty)
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(name,
                              style: const TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600)),
                        ),
                      if (leg.occupancy != null) ...[
                        const SizedBox(width: 6),
                        OccupancyIndicator(level: leg.occupancy!.level),
                      ],
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    dest,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 13,
                        color: theme.colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            if (platform != null && platform.isNotEmpty) ...[
              const SizedBox(width: 8),
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Text('Gl. $platform',
                    style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant)),
              ),
            ],
            const SizedBox(width: 4),
            Icon(Icons.chevron_right,
                size: 18, color: theme.colorScheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }

  /// Planned time, struck through + realtime in red when delayed ≥ 1 min.
  Widget _timeCell(ThemeData theme, DateTime? planned, DateTime? real,
      int? delaySec, {required bool bold}) {
    if (planned == null) return const SizedBox.shrink();
    final delayed = (delaySec ?? 0) >= 60;
    final base = bold
        ? theme.colorScheme.onSurface
        : theme.colorScheme.onSurfaceVariant;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text(
          planned.hhmm,
          style: TextStyle(
            fontSize: 13,
            fontWeight: bold ? FontWeight.bold : FontWeight.w500,
            color: delayed ? base.withAlpha(140) : base,
            decoration: delayed ? TextDecoration.lineThrough : null,
          ),
        ),
        if (delayed && real != null)
          Text(
            real.hhmm,
            style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.bold,
                color: delaySec.delayColor),
          ),
      ],
    );
  }
}
