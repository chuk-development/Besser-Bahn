import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../models/traewelling_models.dart';
import '../../providers/service_providers.dart';
import '../../providers/traewelling_provider.dart';
import '../../services/traewelling_service.dart';
import '../../theme/app_colors.dart';

/// Multi-step check-in: pick station → departure → destination stop → check in.
class TraewellingCheckinScreen extends ConsumerStatefulWidget {
  const TraewellingCheckinScreen({super.key});

  @override
  ConsumerState<TraewellingCheckinScreen> createState() =>
      _TraewellingCheckinScreenState();
}

class _TraewellingCheckinScreenState
    extends ConsumerState<TraewellingCheckinScreen> {
  final _timeFmt = DateFormat('HH:mm');
  final _searchCtrl = TextEditingController();
  final _bodyCtrl = TextEditingController();

  TrwlStation? _station;
  List<TrwlStation> _stationResults = [];
  List<TrwlDeparture> _departures = [];
  TrwlDeparture? _departure;
  TrwlTrip? _trip;
  TrwlStopover? _destination;
  TrwlVisibility _visibility = TrwlVisibility.public;

  bool _loading = false;
  String? _error;

  TraewellingService get _service => ref.read(traewellingServiceProvider);

  @override
  void dispose() {
    _searchCtrl.dispose();
    _bodyCtrl.dispose();
    super.dispose();
  }

  Future<void> _runStationSearch(String q) async {
    if (q.trim().length < 2) {
      setState(() => _stationResults = []);
      return;
    }
    try {
      final r = await _service.searchStations(q.trim());
      if (mounted) setState(() => _stationResults = r);
    } catch (_) {}
  }

  Future<void> _selectStation(TrwlStation s) async {
    setState(() {
      _station = s;
      _stationResults = [];
      _searchCtrl.text = s.name;
      _loading = true;
      _error = null;
      _departures = [];
      _departure = null;
      _trip = null;
      _destination = null;
    });
    try {
      final deps = await _service.departures(s.id);
      setState(() => _departures = deps);
    } catch (e) {
      setState(() => _error = _msg(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _selectDeparture(TrwlDeparture d) async {
    setState(() {
      _departure = d;
      _loading = true;
      _error = null;
      _trip = null;
      _destination = null;
    });
    try {
      final trip =
          await _service.trip(hafasTripId: d.tripId, lineName: d.lineName);
      setState(() => _trip = trip);
    } catch (e) {
      setState(() => _error = _msg(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Stopovers strictly after the boarding station (valid destinations).
  List<TrwlStopover> get _destinationOptions {
    final trip = _trip;
    if (trip == null) return [];
    final boardId = _station?.id;
    final idx = trip.stopovers.indexWhere((s) => s.stationId == boardId);
    return idx >= 0 ? trip.stopovers.sublist(idx + 1) : trip.stopovers;
  }

  Future<void> _checkin({bool force = false}) async {
    final station = _station, departure = _departure, dest = _destination;
    if (station == null || departure == null || dest == null) return;
    final depTime = departure.departure;
    final arrTime = dest.arrival ?? dest.departure;
    if (depTime == null || arrTime == null) {
      setState(() => _error = 'Zeiten unvollständig — andere Fahrt wählen.');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await _service.checkin(
        tripId: departure.tripId,
        lineName: departure.lineName,
        start: station.id,
        destination: dest.stationId,
        departure: depTime,
        arrival: arrTime,
        body: _bodyCtrl.text.trim(),
        visibility: _visibility.value,
        force: force,
      );
      ref.invalidate(trwlDashboardProvider);
      await ref.read(traewellingAuthProvider.notifier).refreshUser();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Eingecheckt! 🎉')),
      );
      Navigator.of(context).pop();
    } on CheckinCollisionException {
      if (mounted) _confirmForce();
    } catch (e) {
      setState(() => _error = _msg(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _confirmForce() {
    showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Überschneidung'),
        content: const Text(
            'Du bist bereits für eine überlappende Fahrt eingecheckt. '
            'Trotzdem einchecken?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c),
              child: const Text('Abbrechen')),
          FilledButton(
            onPressed: () {
              Navigator.pop(c);
              _checkin(force: true);
            },
            child: const Text('Trotzdem'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Einchecken')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Step 1: station
          TextField(
            controller: _searchCtrl,
            decoration: InputDecoration(
              labelText: 'Bahnhof / Haltestelle',
              prefixIcon: const Icon(Icons.search),
              border: const OutlineInputBorder(),
              suffixIcon: _searchCtrl.text.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        _searchCtrl.clear();
                        setState(() {
                          _station = null;
                          _stationResults = [];
                          _departures = [];
                          _departure = null;
                          _trip = null;
                          _destination = null;
                        });
                      },
                    ),
            ),
            onChanged: _runStationSearch,
          ),
          ..._stationResults.map((s) => ListTile(
                dense: true,
                leading: const Icon(Icons.train),
                title: Text(s.name),
                onTap: () => _selectStation(s),
              )),

          if (_loading) ...[
            const SizedBox(height: 24),
            const Center(child: CircularProgressIndicator()),
          ],
          if (_error != null) ...[
            const SizedBox(height: 16),
            Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
          ],

          // Step 2: departures
          if (_station != null && _trip == null && _departures.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text('Abfahrten', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            ..._departures.map((d) => Card(
                  margin: const EdgeInsets.only(bottom: 6),
                  child: ListTile(
                    leading: _lineBadge(d.lineName, d.routeColor),
                    title: Text(d.direction ?? d.lineName),
                    subtitle: d.platform != null ? Text('Gleis ${d.platform}') : null,
                    trailing: Text(
                      d.departure != null
                          ? _timeFmt.format(d.departure!.toLocal())
                          : '',
                      style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: d.isDelayed ? AppColors.delay : null),
                    ),
                    onTap: () => _selectDeparture(d),
                  ),
                )),
          ],

          // Step 3: destination + submit
          if (_trip != null) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                _lineBadge(_departure!.lineName, _departure!.routeColor),
                const SizedBox(width: 8),
                Expanded(
                    child: Text(_trip!.direction ?? '',
                        style: theme.textTheme.titleMedium)),
              ],
            ),
            const SizedBox(height: 12),
            Text('Ausstieg wählen', style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            RadioGroup<TrwlStopover>(
              groupValue: _destination,
              onChanged: (v) => setState(() => _destination = v),
              child: Column(
                children: _destinationOptions
                    .map((s) => RadioListTile<TrwlStopover>(
                          value: s,
                          dense: true,
                          title: Text(s.name),
                          secondary: Text(s.arrival != null
                              ? _timeFmt.format(s.arrival!.toLocal())
                              : ''),
                        ))
                    .toList(),
              ),
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
            DropdownButtonFormField<TrwlVisibility>(
              initialValue: _visibility,
              decoration: const InputDecoration(
                labelText: 'Sichtbarkeit',
                border: OutlineInputBorder(),
              ),
              items: TrwlVisibility.values
                  .map((v) =>
                      DropdownMenuItem(value: v, child: Text(v.label)))
                  .toList(),
              onChanged: (v) => setState(() => _visibility = v ?? _visibility),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.dbRed,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              onPressed: (_destination == null || _loading)
                  ? null
                  : () => _checkin(),
              icon: const Icon(Icons.check),
              label: const Text('Einchecken'),
            ),
            const SizedBox(height: 32),
          ],
        ],
      ),
    );
  }

  Widget _lineBadge(String line, String? hex) {
    Color c = AppColors.dbRed;
    if (hex != null && hex.length >= 6) {
      final p = int.tryParse(hex.replaceAll('#', ''), radix: 16);
      if (p != null) c = Color(0xFF000000 | p);
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration:
          BoxDecoration(color: c, borderRadius: BorderRadius.circular(6)),
      child: Text(line,
          style: const TextStyle(
              color: Colors.white, fontWeight: FontWeight.bold)),
    );
  }

  String _msg(Object e) =>
      e is TraewellingException ? e.message : e.toString();
}
