import 'dart:convert';
import 'dart:typed_data';

/// The signed-in DB customer profile — from `POST /mob/kundenkonten/{id}`.
class DbProfile {
  final String kundenkontoId;
  final String kundennummer;
  final String vorname;
  final String nachname;
  final String? anrede; // "HR" / "FR" / …
  final String? email;
  final String? geburtsdatum; // YYYY-MM-DD
  final DbAddress? adresse;

  /// `kundenprofile[].id` — needed as `kundenprofilId` for the trip overview.
  final String? kundenprofilId;
  final String? bahnbonusStatus; // raw enum, e.g. "UNBEKANNT"

  const DbProfile({
    required this.kundenkontoId,
    required this.kundennummer,
    required this.vorname,
    required this.nachname,
    this.anrede,
    this.email,
    this.geburtsdatum,
    this.adresse,
    this.kundenprofilId,
    this.bahnbonusStatus,
  });

  String get fullName => [vorname, nachname]
      .where((s) => s.trim().isNotEmpty)
      .join(' ')
      .trim();

  String get anredeText => switch (anrede) {
        'HR' => 'Herr',
        'FR' => 'Frau',
        _ => '',
      };

  factory DbProfile.fromJson(Map<String, dynamic> j) {
    final profile = (j['kundenprofile'] as List<dynamic>?)
        ?.whereType<Map<String, dynamic>>()
        .firstOrNull;
    final mail = profile?['kontaktmailadresse'] as Map<String, dynamic>?;
    final addr = j['hauptadresse'] as Map<String, dynamic>?;
    return DbProfile(
      kundenkontoId: (j['kundenkontoId'] ?? '').toString(),
      kundennummer: (j['kundennummer'] ?? '').toString(),
      vorname: (j['vorname'] ?? '').toString(),
      nachname: (j['nachname'] ?? '').toString(),
      anrede: j['anrede'] as String?,
      email: mail?['email'] as String?,
      geburtsdatum: j['geburtsdatum'] as String?,
      adresse: addr != null ? DbAddress.fromJson(addr) : null,
      kundenprofilId: profile?['id'] as String?,
      bahnbonusStatus: j['bahnbonusStatus'] as String?,
    );
  }
}

class DbAddress {
  final String? strasse;
  final String? plz;
  final String? ort;
  final String? land;

  const DbAddress({this.strasse, this.plz, this.ort, this.land});

  factory DbAddress.fromJson(Map<String, dynamic> j) => DbAddress(
        strasse: j['strasse'] as String?,
        plz: j['plz'] as String?,
        ort: j['ort'] as String?,
        land: j['land'] as String?,
      );

  /// "Musterstraße 1, 12345 Musterstadt".
  String get oneLine {
    final l1 = (strasse ?? '').trim();
    final l2 = [plz, ort].where((s) => (s ?? '').trim().isNotEmpty).join(' ');
    return [l1, l2].where((s) => s.trim().isNotEmpty).join(', ');
  }
}

/// BahnBonus loyalty status — from `GET /mob/kundenkonten/{id}/bbStatus`.
class DbBahnBonus {
  final int activeBonusPoints;
  final int activeStatusPoints;
  final String statusLevel; // "0".."3"
  final bool subscription;
  final String? loyaltyNumber;

  const DbBahnBonus({
    required this.activeBonusPoints,
    required this.activeStatusPoints,
    required this.statusLevel,
    required this.subscription,
    this.loyaltyNumber,
  });

  /// DB's BahnBonus tiers by numeric level.
  String get levelName => switch (statusLevel) {
        '1' => 'Silber',
        '2' => 'Gold',
        '3' => 'Platin',
        _ => 'Blau',
      };

  factory DbBahnBonus.fromJson(Map<String, dynamic> j) => DbBahnBonus(
        activeBonusPoints: (j['activeBonusPoints'] as num?)?.toInt() ?? 0,
        activeStatusPoints: (j['activeStatusPoints'] as num?)?.toInt() ?? 0,
        statusLevel: (j['statusLevel'] ?? '0').toString(),
        subscription: j['bbSubscription'] as bool? ?? false,
        loyaltyNumber: j['loyaltyNumber'] as String?,
      );
}

/// A BahnCard — from `GET /mob/emobilebahncards`. `bildSicht`/`kontrollSicht`
/// are base64 PNGs of the card faces DB renders in its own app.
class DbBahnCard {
  final String nummer;
  final String typ; // BC25 / BC50 / BC100 …
  final String produktBezeichnung;
  final String? karteninhaber;
  final String klasse; // KLASSE_1 / KLASSE_2
  final String? gueltigAb; // YYYY-MM-DD
  final String? gueltigBis;
  final bool business;
  final Uint8List? bildSicht; // decoded card face PNG
  final Uint8List? kontrollSicht; // decoded control-view PNG

  const DbBahnCard({
    required this.nummer,
    required this.typ,
    required this.produktBezeichnung,
    required this.klasse,
    this.karteninhaber,
    this.gueltigAb,
    this.gueltigBis,
    this.business = false,
    this.bildSicht,
    this.kontrollSicht,
  });

  bool get firstClass => klasse == 'KLASSE_1';

  factory DbBahnCard.fromJson(Map<String, dynamic> j) => DbBahnCard(
        nummer: (j['bahnCardNummer'] ?? '').toString(),
        typ: (j['bahnCardTyp'] ?? '').toString(),
        produktBezeichnung: (j['produktBezeichnung'] ?? '').toString(),
        karteninhaber: j['karteninhaber'] as String?,
        klasse: (j['klasse'] ?? 'KLASSE_2').toString(),
        gueltigAb: j['gueltigAb'] as String?,
        gueltigBis: j['gueltigBis'] as String?,
        business: j['isBahnCardBusiness'] as bool? ?? false,
        bildSicht: _decodePng(j['bildSicht'] as String?),
        kontrollSicht: _decodePng(j['kontrollSicht'] as String?),
      );

  static Uint8List? _decodePng(String? b64) {
    if (b64 == null || b64.isEmpty) return null;
    try {
      // Strip a possible data-URI prefix before decoding.
      final raw = b64.contains(',') ? b64.split(',').last : b64;
      return base64Decode(raw);
    } catch (_) {
      return null;
    }
  }
}

extension _FirstOrNull<E> on Iterable<E> {
  E? get firstOrNull => isEmpty ? null : first;
}
