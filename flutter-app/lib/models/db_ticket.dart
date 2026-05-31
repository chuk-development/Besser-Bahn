import 'dart:convert';
import 'dart:typed_data';

/// One entry of the trip overview (`GET /mob/reisenuebersicht`). Identifies a
/// booked order; the full ticket is fetched lazily per [kundenwunschId].
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
  });

  bool get firstClass => klasse == 'KLASSE_1';

  bool get isReturn =>
      (fahrtrichtung ?? '').toLowerCase().contains('rueck') ||
      (fahrtrichtung ?? '').toLowerCase().contains('rück');

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
