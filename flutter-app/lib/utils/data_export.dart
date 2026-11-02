import 'dart:convert';

import '../core/berlin_time.dart';
import '../core/trip_metrics.dart';
import '../models/journey.dart';
import '../models/purchased_split.dart';
import '../models/travel_stats.dart';

/// Pure formatters for the local-data export (#72) — CSV of the travel
/// statistics and GeoJSON of the travelled routes. No I/O here so the shapes
/// are unit-testable; the file writing / share sheet lives in the caller.

/// One value, CSV-escaped (quote when it contains a comma, quote or newline).
String _csv(Object? v) {
  final s = v?.toString() ?? '';
  if (s.contains(RegExp('[",\n]'))) {
    return '"${s.replaceAll('"', '""')}"';
  }
  return s;
}

String _row(List<Object?> cells) => cells.map(_csv).join(',');

/// Reisestatistik as CSV (#72): a summary block, then the route and line
/// rankings, then the confirmed split-ticket savings. Semicolon-free so it
/// opens cleanly in a comma-locale spreadsheet; German labels for the user.
String statsToCsv(TravelStats stats, List<PurchasedSplit> splits) {
  final b = StringBuffer();
  b.writeln(_row(['Kennzahl', 'Wert']));
  b.writeln(_row(['Reisen', stats.tripCount]));
  b.writeln(_row(['Kilometer', stats.totalKm.toStringAsFixed(1)]));
  b.writeln(_row(['Pünktlich (%)', (stats.onTimeRate * 100).round()]));
  b.writeln(_row(['Verspätung gesamt (Min)', stats.totalDelayMinutes]));
  b.writeln(_row(['Schlimmste Verspätung (Min)', stats.worstDelayMinutes]));
  b.writeln(
    _row(['Längste Fahrt (km)', stats.longestTripKm.toStringAsFixed(1)]),
  );
  b.writeln(_row(['Anschlüsse erreicht', stats.connectionsMade]));
  b.writeln(_row(['Anschlüsse verpasst', stats.connectionsMissed]));

  if (stats.routeCounts.isNotEmpty) {
    b.writeln();
    b.writeln(_row(['Strecke', 'Fahrten']));
    for (final e in stats.topRoutes(1000)) {
      b.writeln(_row([e.key, e.value]));
    }
  }

  if (stats.lineCounts.isNotEmpty) {
    b.writeln();
    b.writeln(_row(['Linie', 'Fahrten']));
    for (final e in stats.topLines(1000)) {
      b.writeln(_row([e.key, e.value]));
    }
  }

  if (splits.isNotEmpty) {
    b.writeln();
    b.writeln(_row(['Split-Ticket', 'Direktpreis', 'Split-Preis', 'Gespart']));
    for (final s in splits) {
      b.writeln(
        _row([
          s.routeLabel,
          s.directPrice.toStringAsFixed(2),
          s.splitPrice.toStringAsFixed(2),
          s.savings.toStringAsFixed(2),
        ]),
      );
    }
    final total = splits.fold<double>(0, (a, s) => a + s.savings);
    b.writeln(_row(['Gesamt gespart', '', '', total.toStringAsFixed(2)]));
  }

  return b.toString();
}

/// Travelled routes as GPX 1.1 (#72): one `<trk>` per journey, its stations as
/// track points in order. Same data as the GeoJSON, in the format the hiking /
/// cycling / GPS world actually reads (Komoot, OsmAnd, Garmin, Strava) — a
/// GeoJSON file is useless to most of those.
///
/// Timestamps are deliberately omitted: the app knows when a journey departed,
/// not when the train passed each station, and a made-up `<time>` would make
/// every tool compute nonsense speeds.
String journeysToGpx(List<Journey> journeys) {
  String esc(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');

  final b = StringBuffer()
    ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
    ..writeln(
      '<gpx version="1.1" creator="Besser-Bahn" '
      'xmlns="http://www.topografix.com/GPX/1/1">',
    );
  for (final j in journeys) {
    final pts = <List<double>>[];
    for (final leg in j.legs) {
      if (leg.isWalking) continue;
      for (final end in [leg.origin, leg.destination]) {
        if (end.latitude == null || end.longitude == null) continue;
        final pt = [end.latitude!, end.longitude!];
        if (pts.isEmpty || pts.last[0] != pt[0] || pts.last[1] != pt[1]) {
          pts.add(pt);
        }
      }
    }
    if (pts.length < 2) continue;
    final when = (j.departure ?? j.arrival)?.toIso8601String();
    b
      ..writeln('  <trk>')
      ..writeln('    <name>${esc(TripMetrics.routeLabel(j))}</name>');
    if (when != null) b.writeln('    <desc>${esc(when)}</desc>');
    b.writeln('    <trkseg>');
    for (final p in pts) {
      b.writeln('      <trkpt lat="${p[0]}" lon="${p[1]}"></trkpt>');
    }
    b
      ..writeln('    </trkseg>')
      ..writeln('  </trk>');
  }
  b.writeln('</gpx>');
  return b.toString();
}

/// Travelled routes as GeoJSON (#72): a FeatureCollection with one LineString
/// per journey, drawn through each boarded leg's endpoint coordinates. Journeys
/// (or legs) without coordinates are skipped, so the output is a lower bound,
/// never wrong. Opens in any GIS / map tool.
String journeysToGeoJson(List<Journey> journeys) {
  final features = <Map<String, dynamic>>[];
  for (final j in journeys) {
    final coords = <List<double>>[];
    for (final leg in j.legs) {
      if (leg.isWalking) continue;
      for (final end in [leg.origin, leg.destination]) {
        if (end.latitude == null || end.longitude == null) continue;
        // GeoJSON order is [lon, lat]; skip a repeated point (arrival == next
        // departure at the same station).
        final pt = [end.longitude!, end.latitude!];
        if (coords.isEmpty ||
            coords.last[0] != pt[0] ||
            coords.last[1] != pt[1]) {
          coords.add(pt);
        }
      }
    }
    if (coords.length < 2) continue;
    features.add({
      'type': 'Feature',
      'properties': {
        'route': TripMetrics.routeLabel(j),
        'date': (j.departure ?? j.arrival)?.toIso8601String(),
        'km': double.parse(TripMetrics.distanceKm(j).toStringAsFixed(1)),
      },
      'geometry': {'type': 'LineString', 'coordinates': coords},
    });
  }
  return const JsonEncoder.withIndent(
    '  ',
  ).convert({'type': 'FeatureCollection', 'features': features});
}

/// What a row of the Reisen tab is (#72) — the user splits money spent on
/// tickets from trips that were only planned.
enum TripExportKind {
  /// A ticket bought on the DB account.
  ticket('Ticket'),

  /// A seat reservation booked without a ticket (`autonomeReservierung`).
  reservation('Reservierung'),

  /// A trip marked on the DB account ("Gemerkte Reise"), not bought.
  dbSaved('Gemerkte Reise'),

  /// A trip saved only in this app.
  local('Gespeicherte Reise');

  const TripExportKind(this.label);
  final String label;
}

/// One trip of the Reisen tab, flattened for [tripsToCsv]. Every field except
/// [kind] is optional: a ticket whose Verbindung will not parse still exports
/// its order data, and a local trip has no order data at all.
class TripExportRow {
  final TripExportKind kind;
  final Journey? journey;

  /// Used for the departure column when [journey] is unknown (ticket validity
  /// start, the gemerkte Reise's start day).
  final DateTime? fallbackStart;
  final String? fallbackFrom;
  final String? fallbackTo;

  final double? price;

  /// Where [price] comes from: the printed ticket, or the search result the
  /// trip was saved from (a search price, not proof of what was paid).
  final String? priceSource;
  final String? offerName; // "Flexpreis", "Super Sparpreis" …
  final String? travelClass; // KLASSE_1 / KLASSE_2
  final List<String> discounts; // "BahnCard 25" …
  final String? travellers;
  final DateTime? bookedAt;
  final String? orderNumber;

  const TripExportRow({
    required this.kind,
    this.journey,
    this.fallbackStart,
    this.fallbackFrom,
    this.fallbackTo,
    this.price,
    this.priceSource,
    this.offerName,
    this.travelClass,
    this.discounts = const [],
    this.travellers,
    this.bookedAt,
    this.orderNumber,
  });

  DateTime? get start =>
      journey?.plannedDeparture ?? journey?.departure ?? fallbackStart;
}

/// The Reisen tab as CSV (#72): one row per trip, oldest first, for the
/// user's own analysis (money spent, tariffs, train numbers).
///
/// Times are German wall-clock (`yyyy-MM-dd HH:mm`, Europe/Berlin), the same
/// time the ticket shows (#106). Planned times, not live ones: an export of a
/// past trip should not depend on when the delay was last fetched. Money and
/// distances use a dot decimal, so every spreadsheet reads them as numbers
/// once the file is imported as comma-separated.
String tripsToCsv(List<TripExportRow> rows) {
  String two(int v) => v.toString().padLeft(2, '0');
  String stamp(DateTime? dt) {
    if (dt == null) return '';
    final b = toBerlin(dt);
    return '${b.year}-${two(b.month)}-${two(b.day)} '
        '${two(b.hour)}:${two(b.minute)}';
  }

  String klasse(String? k) => switch (k) {
    'KLASSE_1' => '1',
    'KLASSE_2' => '2',
    _ => '',
  };

  String trains(Journey j) => [
    for (final l in j.legs)
      if (!l.isWalking && l.line != null)
        _trainLabel(l.line!.name, l.line!.fahrtNr),
  ].join(' + ');

  final sorted = [...rows]
    ..sort(
      (a, b) =>
          (a.start ?? DateTime(9999)).compareTo(b.start ?? DateTime(9999)),
    );

  final b = StringBuffer();
  b.writeln(
    _row([
      'Typ',
      'Abfahrt',
      'Ankunft',
      'Von',
      'Nach',
      'Dauer (Min)',
      'Umstiege',
      'Züge',
      'Kilometer',
      'Preis (EUR)',
      'Preisquelle',
      'Angebot',
      'Klasse',
      'BahnCard',
      'Reisende',
      'Gebucht am',
      'Auftragsnummer',
    ]),
  );
  for (final r in sorted) {
    final j = r.journey;
    final dep = j?.plannedDeparture ?? j?.departure ?? r.fallbackStart;
    final arr = j?.plannedArrival ?? j?.arrival;
    final minutes = (dep != null && arr != null)
        ? arr.difference(dep).inMinutes
        : null;
    final km = j == null ? null : TripMetrics.distanceKm(j);
    b.writeln(
      _row([
        r.kind.label,
        stamp(dep),
        stamp(arr),
        j?.legs.firstOrNull?.origin.name ?? r.fallbackFrom,
        j?.legs.lastOrNull?.destination.name ?? r.fallbackTo,
        minutes,
        j == null ? null : (j.transfers < 0 ? 0 : j.transfers),
        j == null ? null : trains(j),
        (km == null || km <= 0) ? null : km.toStringAsFixed(1),
        r.price?.toStringAsFixed(2),
        r.price == null ? null : r.priceSource,
        r.offerName,
        klasse(r.travelClass),
        r.discounts.join(' + '),
        r.travellers,
        stamp(r.bookedAt),
        r.orderNumber,
      ]),
    );
  }
  return b.toString();
}

/// "ICE 584" stays as it is; "RE1" with run number 21012 becomes
/// "RE1 (21012)" — a line name alone does not identify the train.
String _trainLabel(String name, String fahrtNr) {
  final n = name.trim();
  final nr = fahrtNr.trim();
  if (nr.isEmpty || n.contains(nr)) return n;
  return n.isEmpty ? nr : '$n ($nr)';
}
