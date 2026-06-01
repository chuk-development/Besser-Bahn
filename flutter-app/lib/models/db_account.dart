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

  /// `kundendatensatzId` — needed for the favorites endpoint
  /// (`/mob/kundendatensatz/{id}/favoriten`).
  final String? kundendatensatzId;

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
    this.kundendatensatzId,
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
      kundendatensatzId: j['kundendatensatzId'] as String?,
      bahnbonusStatus: j['bahnbonusStatus'] as String?,
    );
  }
}

/// One server-side Bahnhof favorite — from
/// `GET /mob/kundendatensatz/{kundendatensatzId}/favoriten`.
class DbStationFavorite {
  final String id; // server uuid
  final String locationId; // HAFAS location string
  final String locationName; // raw DB name
  final String? name; // optional custom alias the user set ("wp", "Zuhause")
  final String? evaNr;
  final double? lat;
  final double? lng;

  const DbStationFavorite({
    required this.id,
    required this.locationId,
    required this.locationName,
    this.name,
    this.evaNr,
    this.lat,
    this.lng,
  });

  /// Display label — alias if the user set one, else the raw station name.
  String get displayName =>
      (name != null && name!.trim().isNotEmpty) ? name!.trim() : locationName;

  factory DbStationFavorite.fromJson(Map<String, dynamic> j) {
    final loc = j['location'] as Map<String, dynamic>?;
    final coords = loc?['coordinates'] as Map<String, dynamic>?;
    return DbStationFavorite(
      id: (j['id'] ?? '').toString(),
      locationId: (j['locationId'] ?? '').toString(),
      locationName: (j['locationName'] ?? loc?['name'] ?? '').toString(),
      name: j['name'] as String?,
      evaNr: (loc?['evaNr'] ?? '').toString().isEmpty
          ? null
          : (loc?['evaNr']).toString(),
      lat: (coords?['latitude'] as num?)?.toDouble(),
      lng: (coords?['longitude'] as num?)?.toDouble(),
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

  /// DB rotates the Kontrollsicht PNG periodically as anti-fraud measure;
  /// this is the date until which the cached image is considered valid for
  /// a ticket check. Past it, the app should re-fetch.
  final String? kontrollSichtGueltigBis;

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
    this.kontrollSichtGueltigBis,
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
        kontrollSichtGueltigBis: j['kontrollSichtGueltigBis'] as String?,
        business: j['isBahnCardBusiness'] as bool? ?? false,
        bildSicht: _decodePng(j['bildSicht'] as String?),
        kontrollSicht: _decodePng(j['kontrollSicht'] as String?),
      );

  /// Persistable shape — mirrors the API JSON so the same [fromJson] reads
  /// it back. Used by the on-disk cache so the BahnCard view (incl. the
  /// Kontrollansicht PNG) survives offline / between launches.
  Map<String, dynamic> toJson() => {
        'bahnCardNummer': nummer,
        'bahnCardTyp': typ,
        'produktBezeichnung': produktBezeichnung,
        if (karteninhaber != null) 'karteninhaber': karteninhaber,
        'klasse': klasse,
        if (gueltigAb != null) 'gueltigAb': gueltigAb,
        if (gueltigBis != null) 'gueltigBis': gueltigBis,
        if (kontrollSichtGueltigBis != null)
          'kontrollSichtGueltigBis': kontrollSichtGueltigBis,
        'isBahnCardBusiness': business,
        if (bildSicht != null) 'bildSicht': base64Encode(bildSicht!),
        if (kontrollSicht != null)
          'kontrollSicht': base64Encode(kontrollSicht!),
      };

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
