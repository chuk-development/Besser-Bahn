import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../core/extensions.dart';
import '../models/journey.dart';
import '../providers/service_providers.dart';
import '../services/location_service.dart';

/// "Tür-zu-Tür": tap to use the device location, estimate the walk to the
/// boarding station and show when you must leave to make the train —
/// "Losgehen um 19:42 · ~8 Min Fußweg". Pure on-device geometry: great-circle
/// distance ÷ walking speed, with a small buffer. No routing service.
class LeaveByCard extends ConsumerStatefulWidget {
  final Journey journey;
  const LeaveByCard({super.key, required this.journey});

  @override
  ConsumerState<LeaveByCard> createState() => _LeaveByCardState();
}

class _LeaveByCardState extends ConsumerState<LeaveByCard> {
  static const _walkSpeedMps = 1.35; // ≈ 4.9 km/h, relaxed pace
  static const _bufferMinutes = 3; // crossing the forecourt, finding the Gleis

  bool _loading = false;
  int? _walkMinutes;
  String? _error;

  Future<void> _compute() async {
    final origin = widget.journey.origin;
    if (origin == null || !origin.hasLocation) {
      setState(() => _error = 'Für diese Station fehlen Koordinaten.');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final fix = await ref.read(locationServiceProvider).currentFix();
      final metres = const Distance().as(
        LengthUnit.Meter,
        fix.latLng,
        LatLng(origin.latitude!, origin.longitude!),
      );
      final mins = (metres / _walkSpeedMps / 60).ceil() + _bufferMinutes;
      if (mounted) {
        setState(() {
          _walkMinutes = mins;
          _loading = false;
        });
      }
    } on LocationException catch (e) {
      if (mounted) {
        setState(() {
          _error = e.message;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Standort nicht verfügbar.';
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dep = widget.journey.departure ?? widget.journey.plannedDeparture;
    if (dep == null) return const SizedBox.shrink();

    final walk = _walkMinutes;
    final leaveBy = walk != null ? dep.subtract(Duration(minutes: walk)) : null;
    final lateAlready = leaveBy != null && leaveBy.isBefore(DateTime.now());

    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(Icons.directions_walk, color: theme.colorScheme.primary),
            const SizedBox(width: 14),
            Expanded(
              child: walk == null
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Wann musst du los?',
                            style: theme.textTheme.titleSmall
                                ?.copyWith(fontWeight: FontWeight.w600)),
                        Text(
                          _error ?? 'Fußweg zu ${widget.journey.origin?.name ?? "Start"} berechnen.',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: _error != null
                                ? theme.colorScheme.error
                                : theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          lateAlready
                              ? 'Beeil dich — eigentlich schon los!'
                              : 'Losgehen um ${leaveBy!.hhmm}',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: lateAlready ? theme.colorScheme.error : null,
                          ),
                        ),
                        Text('~$walk Min Fußweg zu ${widget.journey.origin?.name ?? "Start"}',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            )),
                      ],
                    ),
            ),
            _loading
                ? const SizedBox(
                    width: 20, height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : IconButton(
                    icon: Icon(walk == null ? Icons.my_location : Icons.refresh),
                    tooltip: 'Standort verwenden',
                    onPressed: _compute,
                  ),
          ],
        ),
      ),
    );
  }
}
