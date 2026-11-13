import 'dart:convert';
import 'dart:typed_data';

import '../src/core.dart';

/// Checks of group "regional": the regional transport backends the app trusts
/// over DB for the platform a bus/tram really leaves from
/// (flutter-app/lib/services/regional_*). Ported from
/// api-tests/test_regional_apis.py (the daily "Regionale APIs" suite).
///
/// Three systems, one question each ("planned platform vs the one it really
/// leaves from today"):
///
///   * HAFAS `mgate.exe` — dPlatfS vs dPlatfR         (16 Verbünde)
///   * EFA/Mentz `XML_DM_REQUEST` — plannedPlatformName vs platformName  (7)
///   * Geofox GTI (HVV Hamburg) — platform vs realtimePlatform  (HMAC-signed)
///
/// These hit the real endpoints, so they survive the real world: one backend
/// being down is a SKIP, not a failure (the app treats it the same — it is an
/// extra on top of DB). The group only FAILS when the *majority* of a system is
/// unreachable or the platform field vanished, because that means the protocol
/// moved and the app has gone blind. One exception: a backend that rejects our
/// credentials (AUTH) fails — it will keep doing that until we change them.
final List<Check> regionalChecks = [
  for (final p in _regionalProfiles)
    Check(
      'regional: HAFAS ${p.id} (${p.label})',
      () => _checkHafasBackendPlatforms(p),
      group: 'regional',
    ),
  Check(
    'regional: HAFAS majority alive + platformed',
    _checkHafasMajorityAliveAndPlatformed,
    group: 'regional',
  ),
  for (final p in _efaProfiles)
    Check(
      'regional: EFA ${p.id} (${p.label})',
      () => _checkEfaBackendPlatforms(p),
      group: 'regional',
    ),
  Check(
    'regional: EFA majority alive + platformed',
    _checkEfaMajorityAliveAndPlatformed,
    group: 'regional',
  ),
  Check(
    'regional: GTI signature known value',
    _checkGtiSignatureKnownValue,
    group: 'regional',
  ),
  Check(
    'regional: GTI auth accepted',
    _checkGtiAuthAccepted,
    group: 'regional',
  ),
  Check(
    'regional: GTI departure platforms',
    _checkGtiDeparturePlatforms,
    group: 'regional',
  ),
];

// --------------------------------------------------------------------------- //
// Transport hiccups are not protocol changes
// --------------------------------------------------------------------------- //

/// A read timeout, a reset, a TLS hiccup or a HAFAS box answering "not today"
/// says nothing about whether the protocol still works — only that this one
/// Verbund is having a moment. Shape errors are NOT in here: those are the
/// signal the monitor exists for. (requests' JSONDecodeError and HTTPError are
/// RequestExceptions, hence FormatException and HttpError.)
/// A HAFAS endpoint that answers a POST with a redirect. dart:io (the app's
/// stack) only follows redirects for GET/HEAD, so the app never reaches the
/// new host — a real outage for the app, not a bad minute. Never caught as a
/// network error: it fails the per-backend check and names the new URL.
class _RedirectError implements Exception {
  final String endpoint;
  final int status;
  final String? location;
  _RedirectError(this.endpoint, this.status, this.location);
  @override
  String toString() =>
      '$endpoint answers POST with $status → ${location ?? '?'} — dart:io '
      '(the app) does not follow POST redirects; update the endpoint in '
      'flutter-app/lib/services/regional_profiles.dart';
}

bool _isNetworkError(Object e) =>
    e is RequestException ||
    e is HttpError ||
    e is CheckError ||
    e is FormatException;

String _lastError = '';

/// One live request, retried once after a short pause on a transport error.
/// Returns null if it stays unreachable; the reason lands in [_lastError] so a
/// skip still names what went wrong.
Future<T?> _attempt<T>(Future<T> Function() fn) async {
  for (var attempt = 0; attempt < 2; attempt++) {
    try {
      return await fn();
    } catch (e) {
      if (!_isNetworkError(e)) rethrow;
      _lastError = '${e.runtimeType}: ${clip(e, 80)}';
      if (attempt == 0) await Future<void>.delayed(const Duration(seconds: 2));
    }
  }
  return null;
}

/// Like [_attempt], but skips the check when the backend stays unreachable.
///
/// Every live call in a per-backend check must go through this: `fpa.invg.de`
/// once answered LocMatch and then read-timed out on StationBoard, which turned
/// the whole daily monitor red (#79) — for one slow Verbund the app treats as
/// optional anyway.
Future<T> _call<T>(String pid, Future<T> Function() fn) async {
  final res = await _attempt(fn);
  if (res == null) {
    // AUTH is not a bad minute: the backend understood us fine and rejected
    // our credentials — it will keep doing that until we change them. bvg, vmt
    // and saarfahrplan sat on `LocMatch AUTH` (truncated aids) unnoticed for
    // months precisely because a skip is silent. That one gets to be red.
    if (_lastError.contains('AUTH')) {
      throw CheckError(
        '$pid rejected our credentials — aid/client stale ($_lastError)',
      );
    }
    throw SkipCheck('$pid unreachable: $_lastError');
  }
  return res;
}

// --------------------------------------------------------------------------- //
// HAFAS — the 16 Verbünde
// --------------------------------------------------------------------------- //

typedef _HafasProfile = ({
  String id,
  String label,
  String endpoint,
  String clientId,
  String clientName,
  String aid,
  String probe,
});

/// flutter-app/lib/services/regional_profiles.dart lists them. `hafas-client`'s
/// per-profile `ver`/client version are years old and several of these answer
/// them with a HAMM parser error — 1.34 / 4000100 is what the whole cluster
/// accepts, and what the app sends.
const List<_HafasProfile> _regionalProfiles = [
  (
    id: 'kvb',
    label: 'KVB Köln',
    endpoint: 'https://auskunft.kvb.koeln/gate',
    clientId: 'HAFAS',
    clientName: 'webapp',
    aid: 'Rt6foY5zcTTRXMQs',
    probe: 'Köln Hbf',
  ),
  (
    id: 'avv',
    label: 'AVV Aachen',
    endpoint: 'https://auskunft.avv.de/bin/mgate.exe',
    clientId: 'AVV_AACHEN',
    clientName: 'webapp',
    aid: '4vV1AcH3N511icH',
    probe: 'Aachen Bushof',
  ),
  (
    id: 'bvg',
    label: 'BVG Berlin',
    endpoint: 'https://bvg.hafas.cloud/apps/gate',
    clientId: 'VBB',
    clientName: 'webapp',
    aid: 'dVg4TZbW8anjx9ztPwe2uk4LVRi9wO',
    probe: 'Berlin Alexanderplatz',
  ),
  (
    id: 'rsag',
    label: 'RSAG Rostock',
    endpoint: 'https://fahrplan.rsag-online.de/bin/mgate.exe',
    clientId: 'RSAG',
    clientName: 'webapp',
    aid: 'tF5JTs25rzUhGrrl',
    probe: 'Rostock Hbf',
  ),
  (
    id: 'invg',
    label: 'INVG Ingolstadt',
    endpoint: 'https://fpa.invg.de/bin/mgate.exe',
    clientId: 'INVG',
    clientName: 'invgPROD-APPSTORE-LIVE',
    aid: 'GITvwi3BGOmTQ2a5',
    probe: 'Ingolstadt Hbf',
  ),
  (
    id: 'vos',
    label: 'VOS Osnabrück',
    endpoint: 'https://fahrplan.vos.info/bin/mgate.exe',
    clientId: 'SWO',
    clientName: 'webapp',
    aid: 'PnYowCQP7Tp1V',
    probe: 'Osnabrück Hbf',
  ),
  (
    id: 'vsn',
    label: 'VSN Südniedersachsen',
    endpoint: 'https://fahrplaner.vsninfo.de/hafas/mgate.exe',
    clientId: 'VSN',
    clientName: 'vsn',
    aid: 'Mpf5UPC0DmzV8jkg',
    probe: 'Göttingen Hbf',
  ),
  (
    id: 'nvv',
    label: 'NVV Nordhessen',
    endpoint: 'https://auskunft.nvv.de/auskunft/bin/app/mgate.exe',
    clientId: 'NVV',
    clientName: 'NVVMobilPROD_APPSTORE',
    aid: 'Kt8eNOH7qjVeSxNA',
    probe: 'Kassel Hbf',
  ),
  (
    id: 'sbahn-muenchen',
    label: 'MVV München',
    endpoint: 'https://s-bahn-muenchen.hafas.de/bin/540/mgate.exe',
    clientId: 'DB-REGIO-MVV',
    clientName: 'MuenchenNavigator',
    aid: 'd491MVVhz9ZZts23',
    probe: 'München Hbf',
  ),
  (
    id: 'nahsh',
    label: 'NAH.SH',
    endpoint: 'https://nahsh.hafas.cloud/gate',
    clientId: 'NAHSH',
    clientName: 'NAHSHPROD',
    aid: 'r0Ot9FLFNAFxijLW',
    probe: 'Kiel Hauptbahnhof',
  ),
  (
    id: 'vbb',
    label: 'VBB',
    endpoint: 'https://fahrinfo.vbb.de/bin/mgate.exe',
    clientId: 'VBB',
    clientName: 'VBB WebApp',
    aid: 'hafas-vbb-webapp',
    probe: 'Berlin Hbf',
  ),
  (
    id: 'vbn',
    label: 'VBN',
    endpoint: 'https://fahrplaner.vbn.de/bin/mgate.exe',
    clientId: 'VBN',
    clientName: 'vbn',
    aid: 'kaoxIXLn03zCr2KR',
    probe: 'Bremen Hbf',
  ),
  (
    id: 'rmv',
    label: 'RMV',
    endpoint: 'https://www.rmv.de/auskunft/bin/jp/mgate.exe',
    clientId: 'RMV',
    clientName: 'webapp',
    aid: 'x0k4ZR33ICN9CWmj',
    probe: 'Frankfurt (Main) Hauptbahnhof',
  ),
  (
    id: 'insa',
    label: 'INSA Sachsen-Anhalt',
    endpoint: 'https://reiseauskunft.insa.de/bin/mgate.exe',
    clientId: 'NASA',
    clientName: 'nasaPROD',
    aid: 'nasa-apps',
    probe: 'Magdeburg Hbf',
  ),
  (
    id: 'vmt',
    label: 'VMT Thüringen',
    endpoint: 'https://vmt.eks-prod-euc1.hafas.cloud/bin/mgate.exe',
    clientId: 'VMT',
    clientName: 'webapp',
    aid: 'web-vmt-qdr6c6y8s4cvfmfw',
    probe: 'Erfurt Hbf',
  ),
  (
    id: 'saarfahrplan',
    label: 'saarVV',
    endpoint: 'https://saarfahrplan.de/bin/mgate.exe',
    clientId: 'ZPS-SAAR',
    clientName: 'Saarfahrplan',
    aid: 'yCW9qZFSye1wIv3gCzm5r7d2kJ3LIF',
    probe: 'Saarbrücken Hbf',
  ),
];

Future<Map<String, dynamic>> _hafas(
  _HafasProfile p,
  String meth,
  Map<String, dynamic> req,
) async {
  final body = {
    'lang': 'de',
    'svcReqL': [
      {'cfg': <String, dynamic>{}, 'meth': meth, 'req': req},
    ],
    'client': {
      'id': p.clientId,
      'type': 'IPH',
      'name': p.clientName,
      'v': '4000100',
    },
    'ver': '1.34',
    'auth': {'type': 'AID', 'aid': p.aid},
  };
  final r = await post(
    p.endpoint,
    headers: {'Content-Type': 'application/json', 'User-Agent': dbnavUa},
    body: jsonEncode(body),
  );
  if (r.status >= 300 && r.status < 400) {
    throw _RedirectError(p.endpoint, r.status, r.header('location'));
  }
  r.raiseForStatus();
  final d = r.jsonMap();
  if (d['err'] != null && d['err'] != '' && d['err'] != 'OK') {
    throw CheckError('$meth ${d['err']}');
  }
  final svcL = listOf(d, 'svcResL');
  final svc = svcL.isNotEmpty && svcL.first is Map<String, dynamic>
      ? svcL.first as Map<String, dynamic>
      : <String, dynamic>{};
  if (svc['err'] != 'OK') throw CheckError('$meth ${svc['err']}');
  return mapOf(svc, 'res');
}

String? _hafasPlatform(Map<String, dynamic> stop, String key) {
  final flat = stop['dPlatf$key'];
  if (flat is String && flat.trim().isNotEmpty) return flat.trim();
  final obj = stop['dPltf$key'];
  if (obj is Map && obj['txt'] is String && (obj['txt'] as String).isNotEmpty) {
    return (obj['txt'] as String).trim();
  }
  return null;
}

String _hafasDate(DateTime d) => '${d.year}${two(d.month)}${two(d.day)}';

/// LocMatch → StationBoard, and departures carry the planned platform. A
/// single dead backend skips; the aggregate check is what fails when too many
/// are gone.
Future<String> _checkHafasBackendPlatforms(_HafasProfile p) async {
  final res = await _call(
    p.id,
    () => _hafas(p, 'LocMatch', {
      'input': {
        'loc': {'type': 'S', 'name': '${p.probe}?'},
        'maxLoc': 5,
        'field': 'S',
      },
    }),
  );
  final locs = maps(listOf(mapOf(res, 'match'), 'locL'));
  if (locs.isEmpty) {
    throw CheckError("${p.id}: LocMatch returned no stop for '${p.probe}'");
  }
  final board = await _call(
    p.id,
    () => _hafas(p, 'StationBoard', {
      'type': 'DEP',
      'date': _hafasDate(DateTime.now()),
      'time': '090000',
      'stbLoc': {'extId': locs.first['extId']},
      'maxJny': 60,
    }),
  );
  final jny = maps(listOf(board, 'jnyL'));
  if (jny.isEmpty) throw CheckError('${p.id}: empty board at ${p.probe}');
  // Whether THIS stop happens to carry platforms is checked in the aggregate —
  // a single stop that resolves to a bay-less tram halt (VRN does this for
  // "Mannheim Hauptbahnhof") is a data quirk, not a broken backend.
  final withPf = jny
      .where((j) => _hafasPlatform(mapOf(j, 'stbStop'), 'S') != null)
      .length;
  return '${locs.first['name'] ?? p.probe}: ${jny.length} departures, '
      '$withPf with planned platform';
}

/// How many HAFAS backends expose the planned platform, and how many were
/// reachable.
Future<(int, int)> _hafasPlatformShare() async {
  var reachable = 0;
  var withPlatform = 0;
  for (final p in _regionalProfiles) {
    final Map<String, dynamic>? res;
    try {
      res = await _attempt(
        () => _hafas(p, 'LocMatch', {
          'input': {
            'loc': {'type': 'S', 'name': '${p.probe}?'},
            'maxLoc': 3,
            'field': 'S',
          },
        }),
      );
    } on _RedirectError {
      continue; // its own per-backend check fails and names the new URL
    }
    final locs = maps(listOf(mapOf(res, 'match'), 'locL'));
    if (locs.isEmpty) continue;
    reachable++;
    // A board that times out must not count against `withPlatform` — it never
    // got to say whether it names a platform. Drop the backend from both
    // tallies instead of scoring it a silent zero.
    final board = await _attempt(
      () => _hafas(p, 'StationBoard', {
        'type': 'DEP',
        'date': _hafasDate(DateTime.now()),
        'time': '090000',
        'stbLoc': {'extId': locs.first['extId']},
        'maxJny': 60,
      }),
    );
    if (board == null) {
      reachable--;
      continue;
    }
    if (maps(
      listOf(board, 'jnyL'),
    ).any((j) => _hafasPlatform(mapOf(j, 'stbStop'), 'S') != null)) {
      withPlatform++;
    }
  }
  return (reachable, withPlatform);
}

/// The protocol still works across the fleet AND still yields the planned
/// platform. Fails only if most are dark or the dPlatfS field vanished
/// everywhere — the two ways the app goes blind.
Future<String> _checkHafasMajorityAliveAndPlatformed() async {
  final (reachable, withPlatform) = await _hafasPlatformShare();
  final total = _regionalProfiles.length;
  if (reachable < total ~/ 2) {
    throw CheckError(
      'only $reachable/$total HAFAS backends answered — protocol '
      '1.34/4000100 may have been rejected fleet-wide',
    );
  }
  // Most reachable ones must still name a platform; a lone quirk is tolerated.
  if (withPlatform < reachable ~/ 2) {
    throw CheckError(
      'only $withPlatform/$reachable reachable HAFAS backends expose '
      'dPlatfS — the planned/live pair the app needs may be gone',
    );
  }
  return '$reachable/$total reachable, $withPlatform with dPlatfS';
}

// --------------------------------------------------------------------------- //
// EFA / Mentz — BW, Bayern, NRW, Sachsen, RLP
// --------------------------------------------------------------------------- //

typedef _EfaProfile = ({String id, String label, String base, String probe});

/// EFA/Mentz backends — the states HAFAS never covered. `plannedPlatformName`
/// vs `platformName` is the same planned/live pair HAFAS calls dPlatfS/dPlatfR.
const List<_EfaProfile> _efaProfiles = [
  (
    id: 'vvs',
    label: 'VVS Stuttgart',
    base: 'https://www3.vvs.de/mngvvs',
    probe: 'Stuttgart Hauptbahnhof',
  ),
  (
    id: 'mvv',
    label: 'MVV München',
    base: 'https://efa.mvv-muenchen.de/ng',
    probe: 'München Hauptbahnhof',
  ),
  (
    id: 'vvo',
    label: 'VVO Dresden',
    base: 'https://efa.vvo-online.de/VMSSL3',
    probe: 'Dresden Hauptbahnhof',
  ),
  (
    id: 'vrr',
    label: 'VRR',
    base: 'https://efa.vrr.de/vrr',
    probe: 'Essen Hauptbahnhof',
  ),
  (
    id: 'vrn',
    label: 'VRN',
    base: 'https://www.vrn.de/mngvrn',
    probe: 'Mannheim Hauptbahnhof',
  ),
  (
    id: 'efa-bw',
    label: 'bwegt',
    base: 'https://www.efa-bw.de/nvbw',
    probe: 'Stuttgart Hauptbahnhof',
  ),
  (
    id: 'defas',
    label: 'Bayern-Fahrplan',
    base: 'https://mobile.defas-fgi.de/beg',
    probe: 'München Hauptbahnhof',
  ),
];

Future<Map<String, dynamic>> _efa(
  String base,
  String path,
  Map<String, dynamic> params,
) async {
  final r = await get(
    '$base/$path',
    query: {'outputFormat': 'rapidJSON', 'version': '10.2.10.139', ...params},
    headers: {'Accept': 'application/json', 'User-Agent': dbnavUa},
  );
  r.raiseForStatus();
  return r.jsonMap();
}

List<Map<String, dynamic>> _efaStops(Map<String, dynamic>? sf) {
  final all = maps(listOf(sf, 'locations'));
  final stops = all.where((l) => l['type'] == 'stop').toList();
  return stops.isNotEmpty ? stops : all;
}

/// STOPFINDER → DM_REQUEST, and a departure names BOTH planned and live
/// platform. One value alone cannot say whether a platform moved.
Future<String> _checkEfaBackendPlatforms(_EfaProfile p) async {
  final sf = await _call(
    p.id,
    () => _efa(p.base, 'XML_STOPFINDER_REQUEST', {
      'name_sf': p.probe,
      'type_sf': 'any',
      'coordOutputFormat': 'WGS84[DD.ddddd]',
    }),
  );
  final locs = _efaStops(sf);
  if (locs.isEmpty) {
    throw CheckError("${p.id}: stopfinder found nothing for '${p.probe}'");
  }
  final dm = await _call(
    p.id,
    () => _efa(p.base, 'XML_DM_REQUEST', {
      'name_dm': locs.first['id'],
      'type_dm': 'stop',
      'mode': 'direct',
      'useRealtime': '1',
      'limit': '30',
    }),
  );
  final events = maps(listOf(dm, 'stopEvents'));
  if (events.isEmpty) {
    final msg = dm['systemMessages'];
    throw CheckError(
      '${p.id}: empty board at ${p.probe} '
      '${msg == null || (msg is List && msg.isEmpty) ? '' : msg}',
    );
  }
  // Whether this stop names both platform fields is the aggregate's job — VRN
  // resolves "Mannheim Hauptbahnhof" to a bay-less tram halt, which is a data
  // quirk of one stop, not a broken backend.
  return '${locs.first['name'] ?? p.probe}: ${events.length} departures, '
      '${events.where(_efaHasBothPlatforms).length} with planned+live platform';
}

bool _efaHasBothPlatforms(Map<String, dynamic> e) {
  final props = mapOf(mapOf(e, 'location'), 'properties');
  bool truthy(dynamic v) => v != null && v != '' && v != false;
  return truthy(props['plannedPlatformName']) && truthy(props['platformName']);
}

Future<(int, int)> _efaPlatformShare() async {
  var reachable = 0;
  var withPlatform = 0;
  for (final p in _efaProfiles) {
    final sf = await _attempt(
      () => _efa(p.base, 'XML_STOPFINDER_REQUEST', {
        'name_sf': p.probe,
        'type_sf': 'any',
      }),
    );
    final locs = _efaStops(sf);
    if (locs.isEmpty) continue;
    reachable++;
    final dm = await _attempt(
      () => _efa(p.base, 'XML_DM_REQUEST', {
        'name_dm': locs.first['id'],
        'type_dm': 'stop',
        'mode': 'direct',
        'useRealtime': '1',
        'limit': '30',
      }),
    );
    if (dm == null) {
      // Timed out before it could name a platform — see the HAFAS share.
      reachable--;
      continue;
    }
    if (maps(listOf(dm, 'stopEvents')).any(_efaHasBothPlatforms)) {
      withPlatform++;
    }
  }
  return (reachable, withPlatform);
}

/// The EFA fleet still answers AND still names plannedPlatformName +
/// platformName. Fails only if most are dark or the field pair vanished.
Future<String> _checkEfaMajorityAliveAndPlatformed() async {
  final (reachable, withPlatform) = await _efaPlatformShare();
  final total = _efaProfiles.length;
  if (reachable < total ~/ 2) {
    throw CheckError(
      'only $reachable/$total EFA backends answered — rapidJSON shape may '
      'have changed',
    );
  }
  if (withPlatform < reachable ~/ 2) {
    throw CheckError(
      'only $withPlatform/$reachable reachable EFA backends name both '
      'plannedPlatformName and platformName',
    );
  }
  return '$reachable/$total reachable, $withPlatform with both platform fields';
}

// --------------------------------------------------------------------------- //
// Geofox GTI (HVV Hamburg) — HMAC-signed
// --------------------------------------------------------------------------- //

const _gtiBase = 'https://gti.geofox.de/gti/restapp';
const _gtiUser = 'hvv-app';

/// From the hvv APK's libsekret.so.
final _gtiKey = utf8.encode(']vUl>8We7hY6');

String _gtiSig(String body) =>
    base64.encode(_hmacSha1(_gtiKey, utf8.encode(body)));

/// `json.dumps(obj, separators=(",", ":"))`: compact, and — like Python's
/// default `ensure_ascii` — every non-ASCII character as a `\uXXXX` escape, so
/// the signed bytes are the ones the Python suite signed.
String _compactAsciiJson(Object obj) {
  final s = jsonEncode(obj);
  final out = StringBuffer();
  for (final unit in s.codeUnits) {
    if (unit > 0x7f) {
      out.write('\\u${unit.toRadixString(16).padLeft(4, '0')}');
    } else {
      out.writeCharCode(unit);
    }
  }
  return out.toString();
}

Future<Map<String, dynamic>> _gti(String path, Map<String, dynamic> obj) async {
  final body = _compactAsciiJson(obj);
  final r = await post(
    '$_gtiBase/$path',
    headers: {
      'geofox-auth-user': _gtiUser,
      'geofox-auth-type': 'HmacSHA1',
      'geofox-auth-signature': _gtiSig(body),
      'X-Platform': 'android',
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      'User-Agent': dbnavUa,
    },
    body: body,
  );
  r.raiseForStatus();
  return r.jsonMap();
}

/// The HMAC recipe extracted from the APK, pinned offline: if this drifts,
/// every signed call breaks and the live checks would only say "auth failed"
/// with no clue why.
Future<String> _checkGtiSignatureKnownValue() async {
  const want = 'OrxF3rXPxotvUKt3FmEBFTRmH/0=';
  final got = _gtiSig('{}');
  if (got != want) {
    throw CheckError('HMAC of "{}" is $got, expected $want');
  }
  return 'HMAC-SHA1("{}") = $got';
}

/// `init` with the extracted key must be accepted — proves the app user +
/// signature still authenticate.
Future<String> _checkGtiAuthAccepted() async {
  final d = await _call('gti', () => _gti('init', {}));
  if (d['returnCode'] != 'OK') {
    throw CheckError(
      'Geofox rejected the key (returnCode=${d['returnCode']}) — the app '
      'secret may have rotated',
    );
  }
  return 'init returnCode=OK'
      '${d['version'] != null ? ', version ${d['version']}' : ''}';
}

/// checkName → departureList, and rail/U-Bahn departures carry
/// `platform`/`realtimePlatform` (the planned/live pair).
///
/// NB Hamburg does not publish bus BAY assignments — neither Geofox nor the
/// NAH.SH neighbour has them — so the platform data here is rail/U-/S-Bahn.
Future<String> _checkGtiDeparturePlatforms() async {
  final found = await _call(
    'gti',
    () => _gti('checkName', {
      'version': 58,
      'theName': {'name': 'Hauptbahnhof', 'city': 'Hamburg', 'type': 'STATION'},
      'maxList': 3,
    }),
  );
  final results = listOf(found, 'results');
  if (results.isEmpty)
    throw CheckError('checkName found no Hamburg Hauptbahnhof');

  final now = DateTime.now();
  final board = await _call(
    'gti',
    () => _gti('departureList', {
      'version': 58,
      'station': results.first,
      'time': {
        'date': '${two(now.day)}.${two(now.month)}.${now.year}',
        'time': hhmm(now),
      },
      'maxList': 40,
      'maxTimeOffset': 120,
      'useRealtime': true,
    }),
  );
  final deps = maps(listOf(board, 'departures'));
  if (board['returnCode'] != 'OK' || deps.isEmpty) {
    throw CheckError(
      'departureList returnCode=${board['returnCode']}, ${deps.length} deps',
    );
  }
  final withPlatform = deps
      .where((d) => d['platform'] != null && d['platform'] != '')
      .length;
  if (withPlatform == 0) {
    throw CheckError(
      'no departure carries a platform — Geofox stopped exposing '
      'platform/realtimePlatform',
    );
  }
  return '${deps.length} departures, $withPlatform with platform';
}

// --------------------------------------------------------------------------- //
// HMAC-SHA1 (dart:core has no hashing; avoids a package:crypto dependency)
// --------------------------------------------------------------------------- //

List<int> _hmacSha1(List<int> key, List<int> msg) {
  const block = 64;
  var k = key.length > block ? _sha1(key) : key;
  k = [...k, ...List<int>.filled(block - k.length, 0)];
  final ipad = [for (final b in k) b ^ 0x36];
  final opad = [for (final b in k) b ^ 0x5c];
  return _sha1([
    ...opad,
    ..._sha1([...ipad, ...msg]),
  ]);
}

List<int> _sha1(List<int> data) {
  int rotl(int x, int n) => ((x << n) | (x >> (32 - n))) & 0xffffffff;

  final bitLen = data.length * 8;
  final padded = <int>[...data, 0x80];
  while (padded.length % 64 != 56) {
    padded.add(0);
  }
  for (var i = 7; i >= 0; i--) {
    padded.add((bitLen >> (8 * i)) & 0xff);
  }

  var h0 = 0x67452301, h1 = 0xEFCDAB89, h2 = 0x98BADCFE;
  var h3 = 0x10325476, h4 = 0xC3D2E1F0;
  final w = Uint32List(80);
  for (var off = 0; off < padded.length; off += 64) {
    for (var i = 0; i < 16; i++) {
      w[i] =
          (padded[off + 4 * i] << 24) |
          (padded[off + 4 * i + 1] << 16) |
          (padded[off + 4 * i + 2] << 8) |
          padded[off + 4 * i + 3];
    }
    for (var i = 16; i < 80; i++) {
      w[i] = rotl(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1);
    }
    var a = h0, b = h1, c = h2, d = h3, e = h4;
    for (var i = 0; i < 80; i++) {
      int f, kk;
      if (i < 20) {
        f = (b & c) | ((~b) & d);
        kk = 0x5A827999;
      } else if (i < 40) {
        f = b ^ c ^ d;
        kk = 0x6ED9EBA1;
      } else if (i < 60) {
        f = (b & c) | (b & d) | (c & d);
        kk = 0x8F1BBCDC;
      } else {
        f = b ^ c ^ d;
        kk = 0xCA62C1D6;
      }
      final t = (rotl(a, 5) + (f & 0xffffffff) + e + kk + w[i]) & 0xffffffff;
      e = d;
      d = c;
      c = rotl(b, 30);
      b = a;
      a = t;
    }
    h0 = (h0 + a) & 0xffffffff;
    h1 = (h1 + b) & 0xffffffff;
    h2 = (h2 + c) & 0xffffffff;
    h3 = (h3 + d) & 0xffffffff;
    h4 = (h4 + e) & 0xffffffff;
  }
  final out = <int>[];
  for (final h in [h0, h1, h2, h3, h4]) {
    out.addAll([(h >> 24) & 0xff, (h >> 16) & 0xff, (h >> 8) & 0xff, h & 0xff]);
  }
  return out;
}
