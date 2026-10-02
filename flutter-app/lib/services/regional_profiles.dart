/// The regional transport authorities' own backends, one per area.
///
/// Every German Verbund runs its own HAFAS, and it is the one that knows what
/// the operator actually did today: a closed bay, a platform moved for
/// engineering work, the diversion notice in the operator's own words. DB's
/// nationwide backend regularly does not — measured at Kiel Hbf, where bay B1
/// has been shut since 6 July 2026 and DB still routes riders to it.
///
/// So these are consulted *in addition to* DB, for the few values where the
/// local authority is simply closer to the truth, and DB stays the source for
/// everything else (prices, nationwide routing, long-distance).
///
/// **Which of these are real.** Probed live on 27.07.2026, all 16 answering with
/// `ver: 1.34` and client version `4000100`; `hafas-client`'s own `mobil-nrw`
/// and `vrn` endpoints no longer resolve at all and are deliberately absent.
library;

/// Which protocol a regional backend speaks.
///
/// Two systems split Germany between them, and the split is not political: the
/// Verbünde that bought HAFAS (Hacon) run `mgate.exe`, the ones that bought EFA
/// (Mentz) run `XML_DM_REQUEST`. Both answer the same question — planned
/// platform vs the one it really leaves from — under different field names, so
/// everything above this layer sees one shape.
enum RegionalBackend {
  /// HAFAS `mgate.exe`: `dPlatfS` (planned) vs `dPlatfR` (live).
  hafas,

  /// EFA/Mentz `XML_DM_REQUEST` with `outputFormat=rapidJSON`:
  /// `plannedPlatformName` vs `platformName`.
  efa,
}

/// One regional backend.
class RegionalProfile {
  /// Stable key, also what the log and the healthcheck call it.
  final String id;

  /// What the rider is shown as the source of a value ("NAH.SH", "VBB").
  final String label;

  final String endpoint;

  final RegionalBackend backend;

  /// HAFAS client identity (unused for [RegionalBackend.efa]). `ver`/`v` are deliberately NOT the values in
  /// `hafas-client`'s profiles: those are years old and several backends answer
  /// them with `HAMM` (a parser error) — 1.34/4000100 is what the whole cluster
  /// accepts today.
  final String clientId;
  final String clientType;
  final String? clientName;
  final String aid;

  /// Rough area, as (south, west, north, east). A free prefilter so a stop in
  /// Munich never asks sixteen backends; the real test is whether the backend
  /// resolves the stop at all.
  final double minLat, minLon, maxLat, maxLon;

  /// Lower runs first. City networks beat state-wide ones on their own turf:
  /// they carry the bay-level detail, the state backend often only the trains.
  final int priority;

  const RegionalProfile({
    required this.id,
    required this.label,
    required this.endpoint,
    this.backend = RegionalBackend.hafas,
    this.clientId = '',
    this.aid = '',
    required this.minLat,
    required this.minLon,
    required this.maxLat,
    required this.maxLon,
    this.clientType = 'IPH',
    this.clientName,
    this.priority = 50,
  });

  bool covers(double lat, double lon) =>
      lat >= minLat && lat <= maxLat && lon >= minLon && lon <= maxLon;
}

/// Every backend that answered, ordered so [regionalProfilesFor] hands back the
/// most local one first.
const List<RegionalProfile> kRegionalProfiles = [
  // ---- city / local networks (most detail, smallest area) -----------------
  RegionalProfile(
    id: 'kvb',
    label: 'KVB Köln',
    endpoint: 'https://auskunft.kvb.koeln/gate',
    clientId: 'HAFAS',
    clientName: 'webapp',
    aid: 'Rt6foY5zcTTRXMQs',
    minLat: 50.75,
    minLon: 6.65,
    maxLat: 51.10,
    maxLon: 7.30,
    priority: 10,
  ),
  RegionalProfile(
    id: 'avv',
    label: 'AVV Aachen',
    endpoint: 'https://auskunft.avv.de/bin/mgate.exe',
    clientId: 'AVV_AACHEN',
    clientName: 'webapp',
    aid: '4vV1AcH3N511icH',
    minLat: 50.55,
    minLon: 5.85,
    maxLat: 51.10,
    maxLon: 6.60,
    priority: 10,
  ),
  RegionalProfile(
    id: 'bvg',
    label: 'BVG Berlin',
    endpoint: 'https://bvg-apps-ext.hafas.de/bin/mgate.exe',
    clientId: 'VBB',
    clientName: 'webapp',
    aid: 'dVg4TZbW8anjx9ztPwe2uk4LVRi9wO',
    minLat: 52.33,
    minLon: 13.08,
    maxLat: 52.68,
    maxLon: 13.77,
    priority: 10,
  ),
  RegionalProfile(
    id: 'rsag',
    label: 'RSAG Rostock',
    endpoint: 'https://fahrplan.rsag-online.de/bin/mgate.exe',
    clientId: 'RSAG',
    clientName: 'webapp',
    aid: 'tF5JTs25rzUhGrrl',
    minLat: 53.90,
    minLon: 11.75,
    maxLat: 54.30,
    maxLon: 12.40,
    priority: 10,
  ),
  RegionalProfile(
    id: 'invg',
    label: 'INVG Ingolstadt',
    endpoint: 'https://fpa.invg.de/bin/mgate.exe',
    clientId: 'INVG',
    clientName: 'invgPROD-APPSTORE-LIVE',
    aid: 'GITvwi3BGOmTQ2a5',
    minLat: 48.60,
    minLon: 11.20,
    maxLat: 48.95,
    maxLon: 11.70,
    priority: 10,
  ),
  RegionalProfile(
    id: 'vos',
    label: 'VOS Osnabrück',
    endpoint: 'https://fahrplan.vos.info/bin/mgate.exe',
    clientId: 'SWO',
    clientName: 'webapp',
    aid: 'PnYowCQP7Tp1V',
    minLat: 52.10,
    minLon: 7.60,
    maxLat: 52.60,
    maxLon: 8.35,
    priority: 15,
  ),
  RegionalProfile(
    id: 'vsn',
    label: 'VSN Südniedersachsen',
    endpoint: 'https://fahrplaner.vsninfo.de/hafas/mgate.exe',
    clientId: 'VSN',
    clientName: 'vsn',
    aid: 'Mpf5UPC0DmzV8jkg',
    minLat: 51.20,
    minLon: 9.20,
    maxLat: 52.10,
    maxLon: 10.90,
    priority: 15,
  ),
  RegionalProfile(
    id: 'nvv',
    label: 'NVV Nordhessen',
    endpoint: 'https://auskunft.nvv.de/auskunft/bin/app/mgate.exe',
    clientId: 'NVV',
    clientName: 'NVVMobilPROD_APPSTORE',
    aid: 'Kt8eNOH7qjVeSxNA',
    minLat: 50.80,
    minLon: 8.40,
    maxLat: 51.65,
    maxLon: 10.30,
    priority: 15,
  ),
  RegionalProfile(
    id: 'sbahn-muenchen',
    label: 'MVV München',
    endpoint: 'https://s-bahn-muenchen.hafas.de/bin/540/mgate.exe',
    clientId: 'DB-REGIO-MVV',
    clientName: 'MuenchenNavigator',
    aid: 'd491MVVhz9ZZts23',
    minLat: 47.80,
    minLon: 10.80,
    maxLat: 48.70,
    maxLon: 12.30,
    priority: 15,
  ),

  // ---- state-wide networks ------------------------------------------------
  RegionalProfile(
    id: 'nahsh',
    label: 'NAH.SH',
    endpoint: 'https://nah.sh.hafas.de/bin/mgate.exe',
    clientId: 'NAHSH',
    clientName: 'NAHSHPROD',
    aid: 'r0Ot9FLFNAFxijLW',
    minLat: 53.30,
    minLon: 7.80,
    maxLat: 55.10,
    maxLon: 11.40,
  ),
  RegionalProfile(
    id: 'vbb',
    label: 'VBB',
    endpoint: 'https://fahrinfo.vbb.de/bin/mgate.exe',
    clientId: 'VBB',
    clientName: 'VBB WebApp',
    aid: 'hafas-vbb-webapp',
    minLat: 51.35,
    minLon: 11.20,
    maxLat: 53.60,
    maxLon: 14.80,
  ),
  RegionalProfile(
    id: 'vbn',
    label: 'VBN',
    endpoint: 'https://fahrplaner.vbn.de/bin/mgate.exe',
    clientId: 'VBN',
    clientName: 'vbn',
    aid: 'kaoxIXLn03zCr2KR',
    minLat: 52.30,
    minLon: 6.60,
    maxLat: 54.00,
    maxLon: 9.90,
  ),
  RegionalProfile(
    id: 'rmv',
    label: 'RMV',
    endpoint: 'https://www.rmv.de/auskunft/bin/jp/mgate.exe',
    clientId: 'RMV',
    clientName: 'webapp',
    aid: 'x0k4ZR33ICN9CWmj',
    minLat: 49.35,
    minLon: 7.70,
    maxLat: 51.10,
    maxLon: 10.30,
  ),
  RegionalProfile(
    id: 'insa',
    label: 'INSA Sachsen-Anhalt',
    endpoint: 'https://reiseauskunft.insa.de/bin/mgate.exe',
    clientId: 'NASA',
    clientName: 'nasaPROD',
    aid: 'nasa-apps',
    minLat: 50.90,
    minLon: 10.50,
    maxLat: 53.10,
    maxLon: 13.30,
  ),
  RegionalProfile(
    id: 'vmt',
    label: 'VMT Thüringen',
    endpoint: 'https://vmt.eks-prod-euc1.hafas.cloud/bin/mgate.exe',
    clientId: 'VMT',
    clientName: 'webapp',
    aid: 'web-vmt-qdr6c6y8s4cvfmfw',
    minLat: 50.20,
    minLon: 9.85,
    maxLat: 51.65,
    maxLon: 12.70,
  ),
  // ---- EFA / Mentz: the states HAFAS never covered ----------------------
  //
  // Verified live on 27.07.2026, all eight answering with planned AND live
  // platform per departure. Between them they close the gaps that made the
  // HAFAS-only version blind in Baden-Württemberg, Bayern, NRW, Sachsen and
  // parts of Rheinland-Pfalz.
  RegionalProfile(
    id: 'vvs',
    label: 'VVS Stuttgart',
    endpoint: 'https://www3.vvs.de/mngvvs',
    backend: RegionalBackend.efa,
    minLat: 48.55,
    minLon: 8.85,
    maxLat: 49.10,
    maxLon: 9.65,
    priority: 10,
  ),
  RegionalProfile(
    id: 'mvv',
    label: 'MVV München',
    endpoint: 'https://efa.mvv-muenchen.de/ng',
    backend: RegionalBackend.efa,
    minLat: 47.85,
    minLon: 11.00,
    maxLat: 48.60,
    maxLon: 12.20,
    priority: 12,
  ),
  RegionalProfile(
    id: 'vvo',
    label: 'VVO Dresden',
    endpoint: 'https://efa.vvo-online.de/VMSSL3',
    backend: RegionalBackend.efa,
    minLat: 50.55,
    minLon: 12.10,
    maxLat: 51.60,
    maxLon: 15.05,
    priority: 20,
  ),
  RegionalProfile(
    id: 'vrr',
    label: 'VRR',
    endpoint: 'https://efa.vrr.de/vrr',
    backend: RegionalBackend.efa,
    minLat: 50.60,
    minLon: 5.85,
    maxLat: 52.55,
    maxLon: 9.50,
    priority: 30,
  ),
  RegionalProfile(
    id: 'vrn',
    label: 'VRN',
    endpoint: 'https://www.vrn.de/mngvrn',
    backend: RegionalBackend.efa,
    minLat: 48.85,
    minLon: 7.60,
    maxLat: 50.20,
    maxLon: 9.60,
    priority: 30,
  ),
  RegionalProfile(
    id: 'efa-bw',
    label: 'bwegt',
    endpoint: 'https://www.efa-bw.de/nvbw',
    backend: RegionalBackend.efa,
    minLat: 47.50,
    minLon: 7.45,
    maxLat: 49.85,
    maxLon: 10.55,
    priority: 40,
  ),
  RegionalProfile(
    id: 'defas',
    label: 'Bayern-Fahrplan',
    endpoint: 'https://mobile.defas-fgi.de/beg',
    backend: RegionalBackend.efa,
    minLat: 47.25,
    minLon: 8.95,
    maxLat: 50.60,
    maxLon: 13.90,
    priority: 40,
  ),
  RegionalProfile(
    id: 'saarfahrplan',
    label: 'saarVV',
    endpoint: 'https://saarfahrplan.de/bin/mgate.exe',
    clientId: 'ZPS-SAAR',
    clientName: 'Saarfahrplan',
    aid: 'yCW9qZFSye1wIv3gCzm5r7d2kJ3LIF',
    minLat: 49.10,
    minLon: 6.30,
    maxLat: 49.65,
    maxLon: 7.45,
  ),
];

/// The backends that might know about a stop, most local first.
List<RegionalProfile> regionalProfilesFor(double lat, double lon) {
  final hits = [
    for (final p in kRegionalProfiles)
      if (p.covers(lat, lon)) p,
  ];
  hits.sort((a, b) => a.priority.compareTo(b.priority));
  return hits;
}
