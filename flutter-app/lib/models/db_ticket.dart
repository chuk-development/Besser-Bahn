import 'dart:convert';
import 'dart:typed_data';

/// One entry of `reisenuebersicht.auftragsIndizes` — a paid order with one or
/// more `kundenwunschIds`. The full ticket is fetched lazily per id.
class DbReiseIndex {
  final String auftragsnummer;
  final List<String> kundenwunschIds;
  final DateTime? aenderungsDatum;

  const DbReiseIndex({
    required this.auftragsnummer,
    required this.kundenwunschIds,
    this.aenderungsDatum,
  });

  factory DbReiseIndex.fromJson(Map<String, dynamic> j) => DbReiseIndex(
        auftragsnummer: (j['auftragsnummer'] ?? '').toString(),
        kundenwunschIds: (j['kundenwunschIds'] as List<dynamic>? ?? const [])
            .map((e) => e.toString())
            .toList(),
        aenderungsDatum: DateTime.tryParse(
                (j['aenderungsDatum'] ?? '').toString())
            ?.toLocal(),
      );
}

/// One entry of `reisenuebersicht.reiseIndizes` — a *tracked* but unpaid trip
/// (the user hit "Reise merken" on a search result; the official Meine-Reisen
/// equivalent of a local bookmark). Different shape than an order: identified
/// by `rkUuid` and carries the planned start date directly.
class DbSavedReiseIndex {
  final String rkUuid;
  final int? reisekettenId;
  final DateTime? aenderungsDatum;
  final DateTime? startDatum;

  const DbSavedReiseIndex({
    required this.rkUuid,
    this.reisekettenId,
    this.aenderungsDatum,
    this.startDatum,
  });

  factory DbSavedReiseIndex.fromJson(Map<String, dynamic> j) =>
      DbSavedReiseIndex(
        rkUuid: (j['rkUuid'] ?? '').toString(),
        reisekettenId: (j['reisekettenId'] as num?)?.toInt(),
        aenderungsDatum:
            DateTime.tryParse((j['aenderungsDatum'] ?? '').toString())
                ?.toLocal(),
        startDatum:
            DateTime.tryParse((j['startDatum'] ?? '').toString())?.toLocal(),
      );
}

/// The combined "Meine Reisen" overview: paid orders and tracked (unpaid)
/// trips arrive together from `GET /mob/reisenuebersicht`.
class DbReisenUebersicht {
  final List<DbReiseIndex> orders;
  final List<DbSavedReiseIndex> saved;

  const DbReisenUebersicht({this.orders = const [], this.saved = const []});

  bool get isEmpty => orders.isEmpty && saved.isEmpty;
}

/// A fully-loaded booked ticket — from
/// `GET /mob/auftrag/{auftragsnummer}/kundenwunsch/{kundenwunschId}`.
class DbTicket {
  final String auftragsnummer;
  final String kundenwunschId;
  final String? angebotsname; // "Flexpreis Europa", "Super Sparpreis" …
  final String status; // GUELTIG / …
  final String? ticketStatus;
  final String klasse; // KLASSE_1 / KLASSE_2
  final String? fahrtrichtung; // einfacheFahrt / hin_und_rueckfahrt
  final String? cityInfotext;

  /// Spatial validity (the named from→to of the ticket).
  final String? vonName;
  final String? nachName;

  /// Temporal validity.
  final DateTime? gueltigAb;
  final DateTime? gueltigBis;
  final DateTime? buchungsdatum;

  /// "1 Erwachsener", "1 Jugendlicher, BahnCard 50" … assembled from
  /// `reisendenInformation` / `reisendenProfil`.
  final String reisendeText;

  /// The scannable barcode (Aztec/Apt), extracted from the embedded ticket
  /// HTML as a PNG.
  final Uint8List? barcode;

  /// Raw decoded ticket HTML (`mediaTyp` text/html), for a full-fidelity view.
  final String? ticketHtml;

  /// Check-in linkage.
  final String? kciTicketRefId;
  final String? tripUUID;

  /// Seat/bike reservations on this ticket (train, coach, seat).
  final List<DbReservierung> reservierungen;

  /// Raw `reise.reiseInfos.verbindung` map — same shape as a search result's
  /// verbindung wrapper, so [VendoService.parseConnection] turns it into a
  /// [Journey] for the Reiseplan tab and the Reisen tile.
  final Map<String, dynamic>? verbindungJson;

  const DbTicket({
    required this.auftragsnummer,
    required this.kundenwunschId,
    required this.status,
    required this.klasse,
    required this.reisendeText,
    this.angebotsname,
    this.ticketStatus,
    this.fahrtrichtung,
    this.cityInfotext,
    this.vonName,
    this.nachName,
    this.gueltigAb,
    this.gueltigBis,
    this.buchungsdatum,
    this.barcode,
    this.ticketHtml,
    this.kciTicketRefId,
    this.tripUUID,
    this.reservierungen = const [],
    this.verbindungJson,
  });

  bool get firstClass => klasse == 'KLASSE_1';

  bool get isReturn =>
      (fahrtrichtung ?? '').toLowerCase().contains('rueck') ||
      (fahrtrichtung ?? '').toLowerCase().contains('rück');

  /// Station name + SH-Tarif Haltestellen-Nummer extracted from the ticket
  /// HTML — DB's tariff tickets carry the route as "Von Kiel (4000)" /
  /// "Nach Martensrade (5330)". The JSON `vonName` carries the bare name only,
  /// so the in-app status block falls back to these when present to match
  /// what's printed on the official ticket.
  ({String name, String? id})? get routeFrom => _parseRoute(r'Von');
  ({String name, String? id})? get routeTo => _parseRoute(r'Nach');

  ({String name, String? id})? _parseRoute(String prefix) {
    final html = ticketHtml;
    if (html == null) return null;
    // Match e.g. "Von Kiel (4000)" / "Nach Bad Vilbel (123)" — non-greedy
    // station name, optional bracketed numeric SH-Tarif id.
    final m = RegExp('$prefix\\s+([^<\\n(]{2,80}?)(?:\\s*\\((\\d+)\\))?\\s*<',
            multiLine: true)
        .firstMatch(html);
    if (m == null) return null;
    final name = m.group(1)?.trim();
    if (name == null || name.isEmpty) return null;
    return (name: name, id: m.group(2));
  }

  factory DbTicket.fromJson(Map<String, dynamic> json) {
    final reise = json['reise'] as Map<String, dynamic>? ?? const {};
    final std = reise['standardInfos'] as Map<String, dynamic>? ?? const {};
    final info = reise['reiseInfos'] as Map<String, dynamic>? ?? const {};

    final zeit = std['zeitlicheGueltigkeit'] as Map<String, dynamic>?;
    final raum = info['raeumlicheGueltigkeit'] as Map<String, dynamic>?;
    final von = raum?['abgangsOrt'] as Map<String, dynamic>?;
    final nach = raum?['ankunftsOrt'] as Map<String, dynamic>?;

    final ticketObj = info['ticket'] as Map<String, dynamic>?;
    final html = _decodeTicketHtml(ticketObj?['ticket'] as String?);

    return DbTicket(
      auftragsnummer: (std['auftragsnummer'] ?? '').toString(),
      kundenwunschId: (std['kundenwunschId'] ?? '').toString(),
      angebotsname: info['angebotsname'] as String?,
      status: (std['status'] ?? info['ticketStatus'] ?? '').toString(),
      ticketStatus: info['ticketStatus'] as String?,
      klasse: (info['klasse'] ?? 'KLASSE_2').toString(),
      fahrtrichtung: info['fahrtrichtung'] as String?,
      cityInfotext: info['cityInfotext'] as String?,
      vonName: von?['name'] as String?,
      nachName: nach?['name'] as String?,
      gueltigAb: _parse(zeit?['ersterGeltungszeitpunkt']),
      gueltigBis: _parse(zeit?['letzterGeltungszeitpunkt']),
      buchungsdatum: _parse(std['buchungsdatum']),
      reisendeText: _reisende(info),
      barcode: _extractBarcode(html),
      ticketHtml: html,
      kciTicketRefId: info['kciTicketRefId'] as String?,
      tripUUID: ((info['verbindung'] as Map<String, dynamic>?)?['tripUUID'])
          as String?,
      reservierungen: (info['reservierungen'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(DbReservierung.fromJson)
          .toList(),
      verbindungJson: info['verbindung'] as Map<String, dynamic>?,
    );
  }

  static DateTime? _parse(dynamic v) =>
      v is String ? DateTime.tryParse(v)?.toLocal() : null;

  /// The ticket body is base64-encoded HTML.
  static String? _decodeTicketHtml(String? b64) {
    if (b64 == null || b64.isEmpty) return null;
    try {
      return utf8.decode(base64Decode(b64));
    } catch (_) {
      return null;
    }
  }

  /// Pull the scannable barcode PNG out of the ticket HTML. The HTML embeds a
  /// couple of `data:image/png;base64,…` images (the Aztec barcode + a small
  /// logo); the barcode is by far the largest, so pick the biggest one.
  static Uint8List? _extractBarcode(String? html) {
    if (html == null) return null;
    final matches = RegExp(r'data:image/png;base64,([A-Za-z0-9+/=]+)')
        .allMatches(html);
    String? best;
    for (final m in matches) {
      final b64 = m.group(1);
      if (b64 != null && (best == null || b64.length > best.length)) {
        best = b64;
      }
    }
    if (best == null) return null;
    try {
      return base64Decode(best);
    } catch (_) {
      return null;
    }
  }

  static String _reisende(Map<String, dynamic> info) {
    final list = info['reisendenInformation'] as List<dynamic>? ?? const [];
    final parts = <String>[];
    for (final r in list.whereType<Map<String, dynamic>>()) {
      final anzahl = (r['anzahl'] as num?)?.toInt() ?? 1;
      final typ = (r['typ'] ?? '').toString();
      parts.add('$anzahl× ${_paxType(typ)}');
    }
    // BahnCard discount, if any, from the traveller profile.
    final profil = info['reisendenProfil'] as Map<String, dynamic>?;
    final reisende = profil?['reisende'] as List<dynamic>? ?? const [];
    final erm = <String>{};
    for (final r in reisende.whereType<Map<String, dynamic>>()) {
      for (final e in (r['ermaessigungen'] as List<dynamic>? ?? const [])) {
        final label = _ermaessigung(e.toString());
        if (label != null) erm.add(label);
      }
    }
    final base = parts.isEmpty ? '1× Reisende:r' : parts.join(', ');
    return erm.isEmpty ? base : '$base · ${erm.join(', ')}';
  }

  static String _paxType(String typ) {
    final t = typ.toUpperCase();
    if (t.startsWith('ERWACHSENER')) return 'Erwachsene:r';
    if (t.startsWith('JUGENDLICHER')) return 'Jugendliche:r';
    if (t.startsWith('KIND')) return 'Kind';
    if (t.startsWith('SENIOR')) return 'Senior:in';
    return 'Reisende:r';
  }

  static String? _ermaessigung(String raw) {
    final r = raw.toUpperCase();
    if (r.contains('BAHNCARD100')) return 'BahnCard 100';
    if (r.contains('BAHNCARD50')) return 'BahnCard 50';
    if (r.contains('BAHNCARD25')) return 'BahnCard 25';
    return null;
  }
}

/// A single seat/bike reservation on a ticket (from `reiseInfos.reservierungen`).
class DbReservierung {
  final String? serviceName; // "ICE", "RJ" …
  final String zugnummer;
  final String? kategorie; // SITZPLATZ / FAHRRAD …
  final int anzahlPlaetze;
  final List<DbPlatz> plaetze; // coach + seat description
  final String? vonName;
  final String? nachName;

  const DbReservierung({
    required this.zugnummer,
    this.serviceName,
    this.kategorie,
    this.anzahlPlaetze = 1,
    this.plaetze = const [],
    this.vonName,
    this.nachName,
  });

  /// First reserved coach number (for locating it on the platform), if numeric.
  int? get firstWagon =>
      plaetze.isEmpty ? null : int.tryParse(plaetze.first.wagen);

  /// "ICE 584" / "RJ 88".
  String get trainLabel =>
      [serviceName, zugnummer].where((s) => (s ?? '').isNotEmpty).join(' ');

  /// "Wagen 22 · Platz 88" (joins all reserved seats).
  String get seatLabel => plaetze
      .map((p) => 'Wagen ${p.wagen}'
          '${p.platz.isNotEmpty ? ' · Platz ${p.platz}' : ''}')
      .join('   ');

  factory DbReservierung.fromJson(Map<String, dynamic> j) {
    final wagen = (j['wagen'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(DbPlatz.fromJson)
        .toList();
    final von = j['abgangsOrt'] as Map<String, dynamic>?;
    final nach = j['ankunftsOrt'] as Map<String, dynamic>?;
    return DbReservierung(
      serviceName: j['serviceName'] as String?,
      zugnummer: (j['zugnummer'] ?? '').toString(),
      kategorie: j['kategorie'] as String?,
      anzahlPlaetze: (j['anzahlPlaetze'] as num?)?.toInt() ?? 1,
      plaetze: wagen,
      vonName: von?['name'] as String?,
      nachName: nach?['name'] as String?,
    );
  }
}

class DbPlatz {
  final String wagen;
  final String platz; // seat description, e.g. "88" or "12"

  const DbPlatz({required this.wagen, required this.platz});

  factory DbPlatz.fromJson(Map<String, dynamic> j) => DbPlatz(
        wagen: (j['nummer'] ?? '').toString(),
        platz: (j['plaetzeBeschreibung'] ?? '').toString(),
      );
}
