import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../models/journey.dart';
import '../models/traewelling_models.dart';
import '../models/trip.dart';
import '../providers/service_providers.dart';
import '../providers/settings_provider.dart';
import '../providers/traewelling_provider.dart';
import '../services/traewelling_service.dart';
import '../theme/app_colors.dart';
import 'app_nav_bar.dart';
import 'traewelling_logo.dart';

/// Entry point for checking the *current* train into Träwelling — used by the
/// in-train check-in button so there's no separate manual station search.
///
/// Behaviour follows the user's settings:
/// - not logged in → a hint that links to the Träwelling connect screen;
/// - `trwlAutoCheckin` on → checks in immediately (origin → destination, at the
///   configured default visibility), no sheet;
/// - off → opens a confirm sheet to pick the destination + visibility first.
Future<void> startTrwlCheckin(
  BuildContext context,
  WidgetRef ref,
  Trip trip, {

  /// Restrict the check-in to a segment of [trip] (a connection leg): the stop
  /// you board at / alight at. Default to the run's origin → destination.
  String? boardingName,
  DateTime? boardingDeparture,
  String? alightingName,
  String? boardingEva,
}) async {
  // The session is restored asynchronously on first use. Reading it before
  // that finished made the first tap claim "not connected" (#109).
  await ref.read(traewellingAuthProvider.notifier).ready;
  if (!context.mounted) return;
  final auth = ref.read(traewellingAuthProvider);
  if (!auth.isLoggedIn) {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      SnackBar(
        content: const Text('Mit Träwelling verbinden, um einzuchecken.'),
        action: SnackBarAction(
          label: 'Anmelden',
          onPressed: () => context.push('/trawelling'),
        ),
      ),
    );
    return;
  }

  final settings = ref.read(settingsProvider);
  if (settings.trwlAutoCheckin) {
    final stops = trip.stopovers;
    final boarding = stops.isNotEmpty ? stops.first : null;
    final alighting = stops.length > 1 ? stops.last : null;
    final boardName = boardingName ?? boarding?.stop.name ?? trip.origin.name;
    final alightName =
        alightingName ?? alighting?.stop.name ?? trip.destination.name;
    final boardDep =
        boardingDeparture ??
        boarding?.departure ??
        boarding?.plannedDeparture ??
        DateTime.now();
    await runTrwlCheckin(
      context,
      ref,
      lineName: trip.line.displayName,
      boardingName: boardName,
      boardingDeparture: boardDep,
      alightingName: alightName,
      boardingEva: boardingEva,
      visibility: settings.trwlVisibility,
    );
    return;
  }

  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _CheckinSheet(
      trip: trip,
      boardingName: boardingName,
      alightingName: alightingName,
    ),
  );
}

/// When 'Automatisch einchecken' is on, saving a connection also checks each of
/// its train legs into Träwelling (at the configured visibility). No-op when the
/// setting is off or the user isn't connected — saving still works either way.
/// Reports one summary SnackBar so the user sees the trip reached Träwelling.
Future<void> autoCheckinSavedJourney(
  BuildContext context,
  WidgetRef ref,
  Journey journey,
) async {
  final settings = ref.read(settingsProvider);
  if (!settings.trwlAutoCheckin) return;
  if (!ref.read(traewellingAuthProvider).isLoggedIn) return;

  final legs = journey.legs
      .where((l) => !l.isWalking && l.line != null)
      .toList();
  if (legs.isEmpty) return;

  final messenger = ScaffoldMessenger.of(context);
  final service = ref.read(traewellingServiceProvider);
  messenger.showSnackBar(
    const SnackBar(
      duration: Duration(seconds: 2),
      content: Text('Checke auf Träwelling ein…'),
    ),
  );

  var ok = 0;
  String? lastErr;
  for (final l in legs) {
    final dep = l.plannedDeparture ?? l.departure;
    if (dep == null) continue;
    try {
      await service.checkinFromTrip(
        lineName: l.line!.displayName,
        boardingName: l.origin.name,
        boardingDeparture: dep,
        alightingName: l.destination.name,
        boardingEva: l.origin.id,
        visibility: settings.trwlVisibility,
      );
      ok++;
    } on CheckinCollisionException {
      ok++; // already checked in for this leg → still counts as present
    } on TraewellingException catch (e) {
      lastErr = e.message;
    } catch (e) {
      lastErr = '$e';
    }
  }
  ref.invalidate(trwlDashboardProvider);
  await ref.read(traewellingAuthProvider.notifier).refreshUser();
  if (!context.mounted) return;
  messenger.showSnackBar(
    SnackBar(
      content: Text(
        ok > 0
            ? 'Auf Träwelling eingecheckt ($ok/${legs.length} Fahrten).'
            : 'Träwelling-Einchecken fehlgeschlagen'
                  '${lastErr != null ? ': $lastErr' : ''}.',
      ),
    ),
  );
}

/// Runs the actual check-in and reports the outcome via SnackBars. Handles the
/// 409 collision by offering a "trotzdem einchecken" (force) retry. Returns
/// true on success.
Future<bool> runTrwlCheckin(
  BuildContext context,
  WidgetRef ref, {
  required String lineName,
  required String boardingName,
  required DateTime boardingDeparture,
  required String alightingName,
  required int visibility,
  String? boardingEva,
  String body = '',
  bool force = false,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final service = ref.read(traewellingServiceProvider);
  try {
    await service.checkinFromTrip(
      lineName: lineName,
      boardingName: boardingName,
      boardingDeparture: boardingDeparture,
      alightingName: alightingName,
      boardingEva: boardingEva,
      visibility: visibility,
      body: body,
      force: force,
    );
    ref.invalidate(trwlDashboardProvider);
    await ref.read(traewellingAuthProvider.notifier).refreshUser();
    messenger.showSnackBar(const SnackBar(content: Text('Eingecheckt! 🎉')));
    return true;
  } on CheckinCollisionException {
    if (!context.mounted) return false;
    final retry = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Überschneidung'),
        content: const Text(
          'Du bist bereits für eine überlappende Fahrt eingecheckt. '
          'Trotzdem einchecken?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Trotzdem'),
          ),
        ],
      ),
    );
    if (retry == true && context.mounted) {
      return runTrwlCheckin(
        context,
        ref,
        lineName: lineName,
        boardingName: boardingName,
        boardingDeparture: boardingDeparture,
        alightingName: alightingName,
        visibility: visibility,
        body: body,
        force: true,
      );
    }
    return false;
  } on TraewellingException catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(e.message)));
    return false;
  } catch (e) {
    messenger.showSnackBar(
      SnackBar(content: Text('Check-in fehlgeschlagen: $e')),
    );
    return false;
  }
}

class _CheckinSheet extends ConsumerStatefulWidget {
  final Trip trip;
  final String? boardingName;
  final String? alightingName;
  const _CheckinSheet({
    required this.trip,
    this.boardingName,
    this.alightingName,
  });

  @override
  ConsumerState<_CheckinSheet> createState() => _CheckinSheetState();
}

class _CheckinSheetState extends ConsumerState<_CheckinSheet> {
  final _timeFmt = DateFormat('HH:mm');
  final _bodyCtrl = TextEditingController();
  late int _boardIdx;
  late Stopover _destination;
  late TrwlVisibility _visibility;
  bool _submitting = false;

  bool _nameEq(String a, String b) =>
      a.trim().toLowerCase() == b.trim().toLowerCase();

  /// Boarding stop — the leg's origin when given, else the run's first stop.
  Stopover get _boarding => widget.trip.stopovers[_boardIdx];

  /// Valid destinations: every stop after the boarding stop.
  List<Stopover> get _destOptions =>
      widget.trip.stopovers.length > _boardIdx + 1
      ? widget.trip.stopovers.sublist(_boardIdx + 1)
      : [];

  @override
  void initState() {
    super.initState();
    final stops = widget.trip.stopovers;
    final bn = widget.boardingName;
    final bi = bn == null
        ? 0
        : stops.indexWhere((s) => _nameEq(s.stop.name, bn));
    _boardIdx = bi >= 0 ? bi : 0;

    final an = widget.alightingName;
    final destMatch = an == null
        ? -1
        : _destOptions.indexWhere((s) => _nameEq(s.stop.name, an));
    _destination = destMatch >= 0
        ? _destOptions[destMatch]
        : (_destOptions.isNotEmpty ? _destOptions.last : stops.first);

    final v = ref.read(settingsProvider).trwlVisibility;
    _visibility = TrwlVisibility.values.firstWhere(
      (e) => e.value == v,
      orElse: () => TrwlVisibility.private,
    );
  }

  @override
  void dispose() {
    _bodyCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() => _submitting = true);
    final boardDep =
        _boarding.departure ?? _boarding.plannedDeparture ?? DateTime.now();
    final ok = await runTrwlCheckin(
      context,
      ref,
      lineName: widget.trip.line.displayName,
      boardingName: _boarding.stop.name,
      boardingDeparture: boardDep,
      alightingName: _destination.stop.name,
      visibility: _visibility.value,
      body: _bodyCtrl.text.trim(),
    );
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop();
    } else {
      setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final trip = widget.trip;
    final boardDep = _boarding.departure ?? _boarding.plannedDeparture;
    // Lift the sheet clear of whatever is in front of it at the bottom: the
    // soft keyboard while typing, otherwise the floating nav bar (this sheet
    // opens from the Zug tab, so the bar hovers over it). Never both — with the
    // keyboard up the bar is behind it.
    final keyboard = MediaQuery.of(context).viewInsets.bottom;
    final navBar = AppNavBar.insetOf(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        4,
        20,
        (keyboard > navBar ? keyboard : navBar) + 20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const TraewellingLogo(size: 28),
              const SizedBox(width: 10),
              Text(
                'In Träwelling einchecken',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            '${trip.line.displayName} · ab ${_boarding.stop.name}'
            '${boardDep != null ? ' ${_timeFmt.format(boardDep.toLocal())}' : ''}',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<Stopover>(
            initialValue: _destination,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Ausstieg',
              border: OutlineInputBorder(),
            ),
            items: _destOptions
                .map(
                  (s) => DropdownMenuItem(
                    value: s,
                    child: Text(
                      '${s.stop.name}'
                      '${(s.arrival ?? s.plannedArrival) != null ? '  ${_timeFmt.format((s.arrival ?? s.plannedArrival)!.toLocal())}' : ''}',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                )
                .toList(),
            onChanged: (v) => setState(() => _destination = v ?? _destination),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<TrwlVisibility>(
            initialValue: _visibility,
            decoration: const InputDecoration(
              labelText: 'Sichtbarkeit',
              border: OutlineInputBorder(),
            ),
            items: TrwlVisibility.values
                .map((v) => DropdownMenuItem(value: v, child: Text(v.label)))
                .toList(),
            onChanged: (v) => setState(() => _visibility = v ?? _visibility),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _bodyCtrl,
            maxLength: 280,
            decoration: const InputDecoration(
              labelText: 'Statustext (optional)',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.dbRed,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              onPressed: _submitting ? null : _submit,
              icon: _submitting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.check),
              label: Text(_submitting ? 'Checke ein…' : 'Einchecken'),
            ),
          ),
        ],
      ),
    );
  }
}
