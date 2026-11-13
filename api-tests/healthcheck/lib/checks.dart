import 'src/core.dart';
import 'checks/mob_board.dart';
import 'checks/mob_journey.dart';
import 'checks/mob_journey2.dart';
import 'checks/mob_journey3.dart';
import 'checks/stations.dart';
import 'checks/geo.dart';
import 'checks/accounts.dart';
import 'checks/regional.dart';

export 'src/core.dart';

/// Every check, in the order the report prints them.
List<Check> allChecks() {
  final all = <Check>[
    ...mobBoardChecks,
    ...mobJourneyChecks,
    ...mobJourney2Checks,
    ...mobJourney3Checks,
    ...stationsChecks,
    ...geoChecks,
    ...accountsChecks,
    ...regionalChecks,
  ];
  int rank(Check c) {
    final i = kOrder.indexOf(c.name);
    return i < 0 ? kOrder.length : i;
  }

  // Stable: unknown names keep their group order, after the known ones.
  final indexed = [for (var i = 0; i < all.length; i++) (i, all[i])];
  indexed.sort((a, b) {
    final r = rank(a.$2).compareTo(rank(b.$2));
    return r != 0 ? r : a.$1.compareTo(b.$1);
  });
  return [for (final e in indexed) e.$2];
}

/// The report order (the Python script's CHECKS list).
const kOrder = <String>[
  'bahn.de web API blocked (reiseloesung)',
  'vendo departures (bahnhofstafel)',
  'vendo Ticket hinzufügen (manuellLaden)',
  'vendo Komfort-Check-in status (kci)',
  'vendo arrivals (bahnhofstafel)',
  'vendo board semantics (gattung/cancel)',
  'IRIS plan via stops (board "Über")',
  'vendo train run (zuglauf halte)',
  'vendo platform change (gleis vs ezGleis)',
  'vendo zuglauf notes (Umleitung/Zusatzhalt)',
  'vendo location search',
  'vendo nearby stations (bytypes)',
  'mob endpoint surface reachable (67)',
  'vendo journey + prices (v9)',
  'vendo address search (ADR)',
  'vendo POI search',
  'vendo door-to-door to an address',
  'vendo split scope: leg vs zuglauf (#22)',
  'vendo earlier alight (#26)',
  'vendo verkehrsmittel filter (#18)',
  'vendo search options (#19)',
  'vendo transfer info (#20.6)',
  'vendo serviceDays (#20.8)',
  'vendo tagesbestpreis (#21)',
  'stammdaten vs reisende.dart (#21)',
  'vendo walking route (#21)',
  'vendo party search (pax/bike/dog/SBA)',
  'vendo journey pagination (context)',
  'vendo arrival deadline + buffer (Termin)',
  'vendo stopover split (Aufenthalt)',
  'vendo weitere abfahrten (segment)',
  'vendo share journey (teilen vbid)',
  'vendo train polyline (zuglauf)',
  'vendo seat map (gsd free seats)',
  'prediction service (bahn.chuk.dev scores)',
  'wagenreihung wing-train split (RE)',
  'wagenreihung transfer sectors (#27)',
  'wagenreihung time-vs-date key (#32)',
  'wagenreihung S-Bahn served (#33)',
  'osm platform geometry (overpass)',
  'osm bus stop sides (#55)',
  'delfi stop poles (#55)',
  'regionale Steig-/Gleisquellen HAFAS (16 Verbünde)',
  'regionale Steig-/Gleisquellen EFA (BW/BY/NRW/SN)',
  'basemap (OpenFreeMap Positron vector)',
  'basemap offline style bundle (#29)',
  'bahnhof.de station map (karte)',
  'map bay ↔ departures link',
  'map Gleis ↔ departures (normalised)',
  'bahnhof.de sitemap',
  'traewelling UA requirement (#34)',
  'traewelling check-in API',
  'traewelling endpoints (#42)',
  'traewelling OAuth scopes (#101)',
  'DB OAuth authorize page (#35)',
  'DB account token endpoint (kf_mobile)',
  'DB account mob endpoints (auth-gated)',
  'DB account forced refresh shape (#31)',
  'DB BahnBonus CO₂ service (#37)',
  'HAFAS rest mirror (flaky)',
  'website journey blocked check',
  'GitHub releases API (In-App-Update-Hinweis)',
];
