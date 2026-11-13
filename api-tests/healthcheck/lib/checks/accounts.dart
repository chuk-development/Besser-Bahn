import 'dart:convert';

import '../src/core.dart';

/// Checks of group "accounts": Träwelling, the DB account login and backend,
/// BahnBonus CO₂, the prediction service and the GitHub release feed.
/// Ported from api-tests/healthcheck.py.
final List<Check> accountsChecks = [
  Check(
    'prediction service (bahn.chuk.dev scores)',
    checkPredictionService,
    soft: true,
    group: 'accounts',
  ),
  Check(
    'traewelling UA requirement (#34)',
    checkTraewellingUserAgent,
    soft: true,
    group: 'accounts',
  ),
  Check(
    'traewelling check-in API',
    checkTraewellingApi,
    soft: true,
    group: 'accounts',
  ),
  Check(
    'traewelling endpoints (#42)',
    checkTraewellingEndpoints,
    soft: true,
    group: 'accounts',
  ),
  Check(
    'traewelling OAuth scopes (#101)',
    checkTraewellingScopes,
    soft: true,
    group: 'accounts',
  ),
  Check(
    'DB OAuth authorize page (#35)',
    checkDbOauthAuthorizePage,
    group: 'accounts',
  ),
  Check(
    'DB account token endpoint (kf_mobile)',
    checkDbAccountTokenEndpoint,
    soft: true,
    group: 'accounts',
  ),
  Check(
    'DB account mob endpoints (auth-gated)',
    checkDbAccountEndpointsRequireAuth,
    soft: true,
    group: 'accounts',
  ),
  Check(
    'DB account forced refresh shape (#31)',
    checkDbAccountForcedRefreshShape,
    soft: true,
    group: 'accounts',
  ),
  Check(
    'DB BahnBonus CO₂ service (#37)',
    checkDbBahnbonusCo2,
    soft: true,
    group: 'accounts',
  ),
  // Soft: GitHub rate-limits per IP, and CI shares its IP widely.
  Check(
    'GitHub releases API (In-App-Update-Hinweis)',
    checkGithubReleasesApi,
    soft: true,
    group: 'accounts',
  ),
];

String _constantsSource() =>
    appFile('lib/core/constants.dart').readAsStringSync();

/// The identifying User-Agent the app actually ships, read out of
/// `AppConstants.userAgent` in the Dart source (not a copy of it) so this
/// check exercises the real string and cannot drift from it.
String _appUserAgent() {
  final src = _constantsSource();
  final version = RegExp(r"appVersion\s*=\s*'([^']+)'").firstMatch(src);
  final ua = RegExp(r"userAgent\s*=\n?\s*'(BesserBahn/[^']+)'").firstMatch(src);
  if (version == null || ua == null) {
    throw CheckError(
      'cannot read AppConstants.appVersion/userAgent from '
      'lib/core/constants.dart — did it get renamed?',
    );
  }
  return ua.group(1)!.replaceAll(r'$appVersion', version.group(1)!);
}

/// Träwelling gates its entire surface — OAuth token exchange, refresh and the
/// REST API alike — on an *identifiable* User-Agent, answering 403 "No
/// identifiable User-Agent provided" without one (#34). The tell is 403 vs
/// 401: 403 means "who are you", 401 means the UA was fine and only a token is
/// missing. Pins both directions: a generic UA is still refused, and the UA
/// the app ships is still accepted.
Future<String> checkTraewellingUserAgent() async {
  const url =
      'https://traewelling.de/api/v1/trains/station/autocomplete/Berlin';

  // Direction 1: a generic library UA is refused. `Dart/…` is the one that
  // matters: it is what broke the login in #34.
  final generic = await get(
    url,
    headers: {
      'Accept': 'application/json',
      'User-Agent': 'Dart/3.10 (dart:io)',
    },
  );
  if (generic.status != 403) {
    throw CheckError(
      'Träwelling no longer 403s a generic User-Agent '
      '(status=${generic.status}) — the UA rule changed; re-check '
      'the reproduction in test/traewelling_user_agent_test.dart',
    );
  }
  if (!generic.text.contains('identifiable User-Agent')) {
    throw CheckError(
      '403 but not the UA rejection: ${clip(generic.text, 120)}',
    );
  }

  // Direction 2: the UA the app ships is accepted.
  final ua = _appUserAgent();
  final ours = await get(
    url,
    headers: {'Accept': 'application/json', 'User-Agent': ua},
  );
  if (ours.status == 403) {
    throw CheckError(
      "Träwelling rejects the app's own User-Agent ('$ua'): "
      '${clip(ours.text, 160)} — the Träwelling login is broken (#34)',
    );
  }
  if (ours.status == 404 || ours.status == 410) {
    throw CheckError('autocomplete path gone (status=${ours.status})');
  }
  if (ours.status != 200 && ours.status != 401) {
    throw CheckError('unexpected status ${ours.status}');
  }
  return "UA rule holds: generic 403, '$ua' → ${ours.status}";
}

/// Träwelling REST host the check-in flow rides on. A live auth-gated route
/// answers 401 without a token, a removed one 404/410. Sends the app's
/// identifying User-Agent; a 403 is a failure here.
Future<String> checkTraewellingApi() async {
  final r = await get(
    'https://traewelling.de/api/v1/trains/station/autocomplete/Berlin',
    headers: {'Accept': 'application/json', 'User-Agent': _appUserAgent()},
  );
  if (r.status == 404 || r.status == 410) {
    throw CheckError('autocomplete path gone (status=${r.status})');
  }
  if (r.status == 403) {
    throw CheckError('403 despite an identifying UA: ${clip(r.text, 160)}');
  }
  if (r.status != 200 && r.status != 401) {
    throw CheckError('unexpected status ${r.status}');
  }
  return 'trains/station/autocomplete reachable (status=${r.status})';
}

/// Every Träwelling path the app calls, with the statuses a live route gives.
/// A removed/renamed route answers 404 — which is how the Feed died silently
/// (`/dashboard/global` is gone; the public timeline is `/statuses`, #42).
const _trwlPaths = <(String, List<int>)>[
  ('/auth/user', [401]),
  ('/dashboard', [401]),
  ('/statuses', [200, 401]), // public timeline — the global feed
  ('/user/self/followers', [401]),
  ('/user/self/followings', [401]),
  ('/user/self/follow-requests', [401]),
  ('/trains/station/autocomplete/Berlin', [200, 401]),
];

/// Each REST path the Träwelling integration calls still exists.
Future<String> checkTraewellingEndpoints() async {
  final headers = {
    'Accept': 'application/json',
    'User-Agent': _appUserAgent(),
    'Authorization': 'Bearer invalid',
  };
  final gone = <String>[];
  final odd = <String>[];
  for (final (path, ok) in _trwlPaths) {
    final r = await get('https://traewelling.de/api/v1$path', headers: headers);
    if (r.status == 404 || r.status == 410) {
      gone.add('$path→${r.status}');
    } else if (!ok.contains(r.status)) {
      odd.add('$path→${r.status}');
    }
  }
  if (gone.isNotEmpty) throw CheckError('path(s) gone: ${gone.join(', ')}');
  if (odd.isNotEmpty) throw CheckError('unexpected status: ${odd.join(', ')}');
  return '${_trwlPaths.length} paths live (401/200, none 404)';
}

/// The scopes the app's Träwelling login asks for, read out of
/// `TraewellingConstants.scopeList` in the Dart source.
List<String> _appTraewellingScopes() {
  final block = RegExp(
    r'scopeList\s*=\s*<String>\[(.*?)\];',
    dotAll: true,
  ).firstMatch(_constantsSource());
  if (block == null) {
    throw CheckError(
      'cannot read TraewellingConstants.scopeList from '
      'lib/core/constants.dart — did it get renamed?',
    );
  }
  return RegExp(
    r"'([^']+)'",
  ).allMatches(block.group(1)!).map((m) => m.group(1)!).toList();
}

/// Every scope the login asks for still exists upstream — and `*` is never one
/// of them (Passport 13 strips the wildcard, the grant ends up empty, #101).
Future<String> checkTraewellingScopes() async {
  final ours = _appTraewellingScopes();
  if (ours.isEmpty) {
    throw CheckError('the app requests no Träwelling scopes at all');
  }
  if (ours.contains('*')) {
    throw CheckError(
      'the app asks for the `*` wildcard again — Passport 13 '
      'strips it and the grant ends up empty (#101)',
    );
  }
  final r = await get(
    'https://raw.githubusercontent.com/Traewelling/traewelling/'
    'develop/app/Providers/AuthServiceProvider.php',
    headers: {'Accept': 'text/plain'},
  );
  if (r.status != 200) {
    throw CheckError('cannot read upstream scope list (status=${r.status})');
  }
  final block = RegExp(
    r'\$scopes\s*=\s*\[(.*?)\];',
    dotAll: true,
  ).firstMatch(r.text);
  if (block == null) {
    throw CheckError(
      r'upstream AuthServiceProvider has no $scopes array — '
      'the scope catalogue moved',
    );
  }
  final known = RegExp(
    r"'([^']+)'\s*=>",
  ).allMatches(block.group(1)!).map((m) => m.group(1)!).toSet();
  final missing = ours.where((s) => !known.contains(s)).toList();
  if (missing.isNotEmpty) {
    throw CheckError(
      'scope(s) Träwelling no longer knows: ${missing.join(', ')}',
    );
  }
  return '${ours.length} scopes all known upstream (${known.length} defined)';
}

/// DB account login rides DB's Keycloak realm `db` (public client
/// `kf_mobile`, Authorization Code + PKCE). A live token endpoint rejects a
/// bogus grant with 400/401, a removed realm path answers 404.
Future<String> checkDbAccountTokenEndpoint() async {
  final r = await post(
    'https://accounts.bahn.de/auth/realms/db/protocol/openid-connect/token',
    headers: {'Accept': 'application/json'},
    body: {
      'grant_type': 'refresh_token',
      'client_id': 'kf_mobile',
      'refresh_token': 'healthcheck-invalid',
    },
  );
  if (r.status == 404 || r.status == 410) {
    throw CheckError('token path gone (status=${r.status})');
  }
  // An Akamai "Access Denied" page is the edge, not Keycloak.
  if (clip(r.text, 300).toLowerCase().contains('access denied')) {
    throw CheckError(
      'Akamai edge blocks the probe (Access Denied), '
      'realm not reached — TLS fingerprint?',
    );
  }
  // A live realm rejects the bogus grant with an OAuth 4xx; some Keycloak
  // builds answer 500 to a malformed refresh token.
  if (![400, 401, 403, 500].contains(r.status)) {
    throw CheckError('unexpected status ${r.status}');
  }
  var err = '';
  try {
    final j = r.json();
    if (j is Map) err = '${j['error'] ?? ''}';
  } catch (_) {}
  return 'realm db token endpoint live (status=${r.status} $err)';
}

const _bahncardsMedia = 'application/x.db.vendo.mob.emobilebahncards.v2+json';

/// The Profile tab's /mob data needs a Bearer token: unauthenticated a live
/// path answers 401/403, a gone path 404. Probes `emobilebahncards` and the
/// saved-trips `POST /mob/reisen`.
Future<String> checkDbAccountEndpointsRequireAuth() async {
  final r = await get(
    'https://$mobHost/mob/emobilebahncards',
    headers: vendoHeaders(_bahncardsMedia),
  );
  if (r.status == 404 || r.status == 410) {
    throw CheckError('emobilebahncards path gone (status=${r.status})');
  }
  if (r.status != 401 && r.status != 403) {
    // 200 would mean it stopped requiring auth (very unexpected) — flag it.
    throw CheckError('unexpected status ${r.status} (expected 401/403)');
  }

  const reisenMedia = 'application/x.db.vendo.mob.freiereisen.v5+json';
  final r2 = await post(
    'https://$mobHost/mob/reisen',
    headers: vendoHeaders(reisenMedia),
    body: utf8.encode('{}'),
  );
  if (r2.status == 404 || r2.status == 410) {
    throw CheckError('mob/reisen path gone (status=${r2.status})');
  }
  if (![400, 401, 403].contains(r2.status)) {
    throw CheckError('mob/reisen unexpected status ${r2.status}');
  }
  return 'mob/emobilebahncards + mob/reisen reachable, auth-gated '
      '(status=${r.status}/${r2.status})';
}

/// Pull-to-refresh sends every account request *forced* (no If-None-Match,
/// #31); background revalidation keeps the ETag. Both shapes must reach the
/// auth gate. 429 counts as accepted: the limiter sits behind the edge.
Future<String> checkDbAccountForcedRefreshShape() async {
  const url = 'https://$mobHost/mob/emobilebahncards';
  const ok = [401, 403, 429];

  final forcedHeaders = vendoHeaders(_bahncardsMedia)
    ..['call-trigger'] = 'manual';
  final forced = await get(url, headers: forcedHeaders);
  if (!ok.contains(forced.status)) {
    throw CheckError(
      'forced refresh shape rejected (status=${forced.status}, '
      'expected the 401/403 auth gate)',
    );
  }

  final condHeaders = vendoHeaders(_bahncardsMedia)
    ..['If-None-Match'] = 'W/"probe-not-a-real-etag"'
    ..['call-trigger'] = 'auto';
  final cond = await get(url, headers: condHeaders);
  if (!ok.contains(cond.status)) {
    throw CheckError(
      'conditional refresh shape rejected (status=${cond.status}, '
      'expected the 401/403 auth gate)',
    );
  }
  return 'forced (no if-none-match) + conditional refresh shapes both '
      'accepted, auth-gated (status=${forced.status}/${cond.status})';
}

/// The official CO₂ balance comes from BahnBonus' own CO₂ service (#37). No
/// token in CI, so only prove the route exists and is auth-gated.
Future<String> checkDbBahnbonusCo2() async {
  final r = await get(
    'https://apis.deutschebahn.com/db/apis/bahnbonus/co2-service/v1/statistics',
    query: {
      'interval': 'YEARLY',
      'startDate': '2026-01-01',
      'endDate': '2026-01-01',
    },
    headers: {'Accept': 'application/json'},
  );
  if (r.status == 404 || r.status == 410) {
    throw CheckError('co2-service path gone (status=${r.status})');
  }
  if (![401, 403, 429].contains(r.status)) {
    // 200 unauthenticated would mean it stopped requiring auth — flag it.
    throw CheckError('unexpected status ${r.status} (expected 401/403)');
  }
  return 'co2-service/v1/statistics reachable, auth-gated (status=${r.status})';
}

/// The DB login page has to render for a request shaped like the browser the
/// app actually opens (#35): the scheme redirect yields Keycloak's form, an
/// RFC 8252 loopback redirect is stopped by DB's edge WAF. Browser headers are
/// the whole point — API-ish headers hide the WAF.
Future<String> checkDbOauthAuthorizePage() async {
  const auth =
      'https://accounts.bahn.de/auth/realms/db/protocol/openid-connect/auth';
  final headers = {
    'User-Agent':
        'Mozilla/5.0 (Linux; Android 11; SM-A705FN) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
    'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
    'Accept-Language': 'de-DE,de;q=0.9',
  };

  Future<String> fetch(String redirectUri) async {
    final r = await get(
      auth,
      query: {
        'response_type': 'code',
        'client_id': 'kf_mobile',
        'state': 'healthcheck',
        'nonce': 'n' * 24,
        'code_challenge': 'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM',
        'code_challenge_method': 'S256',
        'prompt': 'login',
        'scope': 'offline_access',
        'redirect_uri': redirectUri,
      },
      headers: headers,
    );
    final body = r.text.toLowerCase();
    if (body.contains('support id') ||
        body.contains('requested url was rejected')) {
      return 'waf';
    }
    if (body.contains('password') || body.contains('kc-form-login')) {
      return 'login';
    }
    if (r.status == 400 && body.contains('redirect_uri')) return 'rejected';
    return 'unknown(status=${r.status}, len=${r.text.length})';
  }

  final scheme = await fetch('dbnav://dbnavigator.bahn.de/login/success');
  if (scheme != 'login') {
    throw CheckError(
      "DB login page no longer renders for the app's redirect ($scheme)",
    );
  }
  final loopback = await fetch('http://127.0.0.1:42171/callback');
  if (loopback == 'login') {
    return 'scheme redirect renders the login form; loopback now passes '
        'the WAF too (the dbnav:// app-chooser could be avoided, #35)';
  }
  return 'scheme redirect renders the login form; loopback blocked ($loopback)';
}

/// Self-hosted reliability model at bahn.chuk.dev (`/v1/journey-scores`): up,
/// and still returns `puenktlichkeit` for a minimal one-leg (two-row) payload.
Future<String> checkPredictionService() async {
  final payload = {
    'number': [786, 786],
    'lat': [52.376, 53.552],
    'lon': [9.741, 10.006],
    'stop_sequence': [0, 1],
    'distance_traveled': [0, 120000],
    'dwell_time_schedule': [null, null],
    'dwell_time_prognosed': [null, null],
    'bearing': [0, 20],
    'delay_prognosed': [0, 0],
    'minute_of_day': [600, 660],
    'minutes_to_prognosed_time': [30, 90],
    'weekday': [5, 5],
    'is_regional': [false, false],
    'is_arrival': [false, true],
    'operator': ['DB Fernverkehr AG', 'DB Fernverkehr AG'],
    'category': ['ICE', 'ICE'],
    'line': ['ICE 786', 'ICE 786'],
    'prognosed_transfer_time': [null, null],
    'minimal_transfer_time': [null, null],
  };
  final r = await post(
    'https://bahn.chuk.dev/v1/journey-scores',
    headers: {'Content-Type': 'application/json'},
    body: jsonEncode(payload),
  );
  r.raiseForStatus();
  final d = r.jsonMap('journey-scores response');
  if (!d.containsKey('puenktlichkeit')) {
    throw CheckError(
      "journey-scores response missing 'puenktlichkeit' "
      "(app's Pünktlichkeit badge would break)",
    );
  }
  final p = d['puenktlichkeit'];
  if (p is! num || p < 0 || p > 100) {
    throw CheckError('puenktlichkeit out of range: $p');
  }
  return 'journey-scores ok (puenktlichkeit=${p.toStringAsFixed(0)}%, '
      'verbindungsscore=${d['verbindungsscore']})';
}

/// The in-app update hint reads GitHub's latest-release endpoint: `tag_name`
/// plus an arm64-v8a .apk asset with a download URL. A 403 with an exhausted
/// rate limit is a skip, not a failure.
Future<String> checkGithubReleasesApi() async {
  final r = await get(
    'https://api.github.com/repos/chuk-development/Besser-Bahn/releases/latest',
    headers: {
      'Accept': 'application/vnd.github+json',
      // GitHub requires a UA; a plain browser one, no project/tool name.
      'User-Agent': browserHeaders()['User-Agent']!,
    },
  );
  if (r.status == 403 && r.header('x-ratelimit-remaining') == '0') {
    throw SkipCheck('GitHub API rate limit for this IP reached');
  }
  r.raiseForStatus();
  final d = r.jsonMap('latest release');
  final tag = d['tag_name'];
  if (tag is! String || tag.isEmpty) {
    throw CheckError(
      "latest release has no 'tag_name' — the update hint would never fire",
    );
  }
  if (!RegExp(r'^v?\d+\.\d+').hasMatch(tag)) {
    throw CheckError(
      "tag_name '$tag' is not a version the app can compare "
      '(expects 2.4.1 style)',
    );
  }
  final assets = d['assets'];
  if (assets is! List) throw CheckError("release has no 'assets' list");
  final apks = [
    for (final a in assets.whereType<Map>())
      if ('${a['name'] ?? ''}'.endsWith('.apk')) '${a['name']}',
  ];
  if (apks.isEmpty) {
    throw CheckError(
      'latest release ships no .apk asset — the download '
      'button would fall back to the release page',
    );
  }
  if (!apks.any((n) => n.contains('arm64-v8a'))) {
    throw CheckError('no arm64-v8a .apk in the latest release: $apks');
  }
  if (!assets.whereType<Map>().any(
    (a) => (a['browser_download_url'] ?? '') != '',
  )) {
    throw CheckError("assets carry no 'browser_download_url'");
  }
  return 'latest=$tag, ${apks.length} apk asset(s)';
}
