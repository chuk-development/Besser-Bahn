import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

import '../core/app_log.dart';
import '../models/departure.dart';

/// Reads the IRIS timetable ("iris-tts") plan feed — DB's own station plan XML,
/// the source the platform displays run on.
///
/// Why a second source at all: the Vendo `bahnhofstafel` board carries only
/// `richtung` (the final destination). The stations' own boards show a whole
/// "Über" column — the stops on the way — and that is the information riders
/// actually pick a train by ("does it stop in Elmshorn?"). IRIS ships that list
/// (`ppth`) for every run of an hour in ONE small request, so the board gets it
/// without a `zuglauf` call per row (~37 KB each, and a fast way into a 429 —
/// see `_RequestGate` in [VendoService]).
///
/// Limits worth knowing: IRIS is rail only. Buses on a station board (Kiel Hbf
/// is mostly buses) have no entry here and simply keep an empty via list.
class IrisService {
  IrisService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  static const _base = 'https://iris.noncd.db.de/iris-tts/timetable';

  /// Parsed hours, keyed `eva-yyMMdd-HH`. The plan is the *timetable*, not
  /// realtime, so it is stable for the whole hour; realtime still comes from
  /// Vendo. Kept small — a board only ever looks a few hours ahead.
  final _cache = <String, List<IrisRun>>{};

  /// Every planned run at [evaId] from the hour of [from] over [hours] hours.
  Future<List<IrisRun>> planWindow(
    String evaId, {
    DateTime? from,
    int hours = 3,
  }) async {
    final start = from ?? DateTime.now();
    final runs = <IrisRun>[];
    for (var i = 0; i < hours; i++) {
      final hour = DateTime(
        start.year,
        start.month,
        start.day,
        start.hour,
      ).add(Duration(hours: i));
      try {
        runs.addAll(await _plan(evaId, hour));
      } catch (e) {
        // Enrichment only — a missing hour costs the "Über" line, nothing else.
        AppLog.log(
          'iris plan ${AppLog.pii(evaId, 'ID')} ${hour.hour}h failed: $e',
          tag: 'iris',
        );
      }
    }
    return runs;
  }

  Future<List<IrisRun>> _plan(String evaId, DateTime hour) async {
    final key = '$evaId-${_yymmdd(hour)}-${_two(hour.hour)}';
    final cached = _cache[key];
    if (cached != null) return cached;

    final url = '$_base/plan/$evaId/${_yymmdd(hour)}/${_two(hour.hour)}';
    final res = await _client
        .get(Uri.parse(url), headers: const {'Accept': 'application/xml'})
        .timeout(const Duration(seconds: 8));
    if (res.statusCode != 200) {
      throw IrisException('IRIS plan HTTP ${res.statusCode}');
    }
    final runs = parsePlan(res.body);
    _cache[key] = runs;
    return runs;
  }

  /// Parses an IRIS `<timetable>` document. Public for the tests.
  ///
  /// Shape: one `<s>` per run at this station, with `<tl>` (train label:
  /// category `c`, number `n`), and `<ar>`/`<dp>` for the arrival/departure
  /// side. `ppth` is the path — for `<dp>` the stops still to come, for `<ar>`
  /// the ones already served — pipe separated and already in travel order.
  static List<IrisRun> parsePlan(String xml) {
    final doc = XmlDocument.parse(xml);
    final runs = <IrisRun>[];
    for (final s in doc.findAllElements('s')) {
      final tl = s.getElement('tl');
      final number = tl?.getAttribute('n')?.trim() ?? '';
      if (number.isEmpty) continue;
      final category = tl?.getAttribute('c')?.trim() ?? '';
      for (final side in const ['dp', 'ar']) {
        final e = s.getElement(side);
        if (e == null) continue;
        final planned = _parseIrisTime(e.getAttribute('pt'));
        if (planned == null) continue;
        runs.add(
          IrisRun(
            trainNumber: number,
            category: category,
            line: e.getAttribute('l')?.trim() ?? '',
            plannedWhen: planned,
            arrival: side == 'ar',
            via: (e.getAttribute('ppth') ?? '')
                .split('|')
                .map((s) => s.trim())
                .where((s) => s.isNotEmpty)
                .toList(),
          ),
        );
      }
    }
    return runs;
  }

  /// Adds the "Über" stops to [departures] from the IRIS plan of [evaId].
  ///
  /// Matching is deliberately strict — same train number AND the same planned
  /// minute — because a bus line number can collide with a train number. A row
  /// that does not match keeps its empty via list.
  Future<List<Departure>> withVia(
    List<Departure> departures,
    String evaId, {
    required bool arrivals,
  }) async {
    if (departures.isEmpty) return departures;
    final times = departures
        .map((d) => d.plannedWhen)
        .whereType<DateTime>()
        .toList();
    if (times.isEmpty) return departures;
    times.sort();
    final span = times.last.difference(times.first).inHours + 2;
    final runs = await planWindow(
      evaId,
      from: times.first,
      hours: span.clamp(1, 4),
    );
    if (runs.isEmpty) return departures;

    final byKey = <String, IrisRun>{};
    for (final r in runs) {
      if (r.arrival != arrivals) continue;
      byKey['${r.trainNumber}@${_minuteKey(r.plannedWhen)}'] = r;
    }

    return departures.map((d) {
      final planned = d.plannedWhen;
      final nr = d.line.fahrtNr.trim();
      if (planned == null || nr.isEmpty) return d;
      final run = byKey['$nr@${_minuteKey(planned)}'];
      if (run == null || run.via.isEmpty) return d;
      // Number + minute alone could pair a bus with a train; the product has to
      // agree too. IRIS `l` is the line ("RE70"), `c` the category ("RE").
      final line = d.line.name.replaceAll(' ', '').toUpperCase();
      final product = d.line.productName.trim().toUpperCase();
      final matchesLabel =
          (run.line.isNotEmpty && run.line.toUpperCase() == line) ||
          (run.category.isNotEmpty && run.category.toUpperCase() == product);
      if (!matchesLabel) return d;
      return d.copyWith(via: run.via);
    }).toList();
  }

  static String _minuteKey(DateTime t) =>
      '${_yymmdd(t)}${_two(t.hour)}${_two(t.minute)}';

  static String _yymmdd(DateTime t) =>
      '${_two(t.year % 100)}${_two(t.month)}${_two(t.day)}';

  static String _two(int v) => v.toString().padLeft(2, '0');

  /// IRIS timestamps are local `yyMMddHHmm`.
  static DateTime? _parseIrisTime(String? raw) {
    final v = raw?.trim() ?? '';
    if (v.length != 10) return null;
    final n = int.tryParse(v);
    if (n == null) return null;
    return DateTime(
      2000 + int.parse(v.substring(0, 2)),
      int.parse(v.substring(2, 4)),
      int.parse(v.substring(4, 6)),
      int.parse(v.substring(6, 8)),
      int.parse(v.substring(8, 10)),
    );
  }
}

/// One planned call of a train at a station, as IRIS states it.
class IrisRun {
  final String trainNumber;
  final String category; // "RE", "ICE", …
  final String line; // "RE70", may be empty on long distance
  final DateTime plannedWhen;
  final bool arrival;
  final List<String> via;

  const IrisRun({
    required this.trainNumber,
    required this.category,
    required this.line,
    required this.plannedWhen,
    required this.arrival,
    required this.via,
  });
}

class IrisException implements Exception {
  final String message;
  const IrisException(this.message);
  @override
  String toString() => 'IrisException: $message';
}
