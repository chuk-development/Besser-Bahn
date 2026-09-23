import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;

import '../core/app_log.dart';
import '../models/station.dart';
import 'regional_profiles.dart';

/// A platform that has moved: what DB's timetable says, where the vehicle really
/// goes from today, which authority said so, and — when it said so — why.
typedef PlatformCorrection = ({
  String planned,
  String live,
  String? note,
  String source,

  /// The planned platform is *closed* (a construction notice names it), even
  /// though no live replacement is in the feed yet. Then [live] equals
  /// [planned] and [note] carries the operator's closure text — the app warns
  /// "Steig B1 gesperrt" rather than sending the rider to a shut bay, and fills
  /// in the actual replacement once the realtime value appears near departure.
  bool closed,
});

/// The NAH.SH HAFAS — the Schleswig-Holstein transport authority's own backend,
/// used for ONE thing: the bay a bus actually leaves from when it has been moved.
///
/// **Why a fourth data source.** Kiel Hbf bay B1 has been fully closed since
/// 6 July 2026 and lines 22/50/51/52/81/91/N22 leave from B2 instead. Measured
/// on the day:
///
///  * DB Vendo (`/mob`, the app's main source) says B1 — no `himNotizen`, no
///    `echtzeitNotizen`, nothing. Not a parsing gap on our side: a Bus 13 at the
///    same board that day carried `{prio: HOCH, text: "Halt entfällt"}`, so the
///    field is live, the closure simply is not in it.
///  * DELFI via Transitous/MOTIS says B1 too, with `realTime: true`.
///  * The nationwide DELFI realtime stream is GTFS-RT **TripUpdates** and
///    SIRI-ET only — punctuality. There is no ServiceAlerts channel to carry a
///    closed bay at all.
///  * NAH.SH HAFAS has it as an ordinary realtime platform change:
///    `dPlatfS: B1`, `dPlatfR: B2`. 12 of 61 departures that morning, and the
///    distribution matches the operator's own notice exactly (B1→B2, B2→A1).
///
/// So this is the only source that answers "which bay, really" — and it answers
/// it in the same shape the app already understands for trains (planned Gleis vs
/// live Gleis).
///
/// **Deliberately narrow.** Each region runs its own HAFAS, so this one only
/// knows Schleswig-Holstein; [servesStop] gates on that before any request goes
/// out. It is asked only about buses and trams (for trains DB's own `ezGleis` is
/// authoritative and nationwide), and every failure is silent — without an
/// answer the app shows exactly what it showed before.
class RegionalTransitService {
  RegionalTransitService({http.Client? client})
    : _client = client ?? http.Client();

  final http.Client _client;

  /// HAFAS protocol version and client build the whole cluster accepts today.
  /// `hafas-client`'s per-profile values are years old and several backends
  /// answer them with a `HAMM` parser error.
  static const _protocolVersion = '1.34';
  static const _clientVersion = '4000100';

  /// One request. Short on purpose: this is an *extra* on top of DB, so a slow
  /// backend must give up quickly rather than hold a "loading" state — the
  /// Reiseplan already shows DB's platform and only swaps it if a correction
  /// actually arrives.
  static const _timeout = Duration(seconds: 6);

  /// Whole-question budget across all the backends tried for one leg. Even if
  /// the first two stall until their own timeouts, the third is never started
  /// past this — better no correction than a spinner that outlives the glance.
  static const _budget = Duration(seconds: 9);

  /// How long a backend that just failed is skipped. A dead endpoint (DNS gone,
  /// 500s, timing out) must not cost every following leg another timeout — the
  /// first failure takes it out of rotation for a while, so the rest of the
  /// Reiseplan stays instant.
  static const _deadFor = Duration(minutes: 5);

  /// User-Agent per backend, so a request looks like the authority's own app
  /// rather than a Dart HTTP client. The identifying part is already the real
  /// `client`/`aid`; this only keeps us out of the "unknown scraper" bucket.
  static const _userAgent =
      'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Version/4.0 Chrome/126.0.0.0 Mobile Safari/537.36';

  /// Profiles that just failed, and when they may be tried again. Static: the
  /// breaker is about the endpoint, not about one service instance.
  static final Map<String, DateTime> _deadUntil = {};

  static bool _isDead(RegionalProfile p) {
    final until = _deadUntil[p.id];
    if (until == null) return false;
    if (DateTime.now().isAfter(until)) {
      _deadUntil.remove(p.id);
      return false;
    }
    return true;
  }

  static void _markDead(RegionalProfile p) {
    _deadUntil[p.id] = DateTime.now().add(_deadFor);
    AppLog.log(
      '${p.id} als tot markiert für ${_deadFor.inMinutes} min',
      tag: 'regional',
    );
  }

  /// Clear the circuit breaker — the static dead-list survives between tests
  /// otherwise, and a backend marked dead in one would silently skip the next.
  @visibleForTesting
  static void resetCircuitBreaker() => _deadUntil.clear();

  /// Whether any regional authority might know [stop]. Stops without
  /// coordinates are not guessed at — no answer beats a wrong region's answer.
  static bool servesStop(Station stop) {
    final lat = stop.latitude, lon = stop.longitude;
    if (lat == null || lon == null) return false;
    return regionalProfilesFor(lat, lon).isNotEmpty;
  }

  /// The products worth asking about. Trains are DB's own turf — it publishes
  /// `ezGleis` for them nationwide, and a regional backend disagreeing about a
  /// Gleis would be noise, not news.
  static bool coversProduct(String? product) =>
      product == 'bus' || product == 'tram' || product == 'ferry';

  /// HAFAS stop ids, keyed by the DB stop we looked them up from. Held for the
  /// process: a stop's HAFAS id does not change, and re-resolving it would be
  /// one request per Reiseplan view.
  final Map<String, String?> _locations = {};
  final Map<String, Future<String?>> _locationsInflight = {};

  /// Departure boards, keyed by HAFAS id + 15-minute bucket. One board answers
  /// every leg at that stop.
  final Map<String, List<RegionalDeparture>> _boards = {};
  final Map<String, Future<List<RegionalDeparture>>> _boardsInflight = {};

  Future<Map<String, dynamic>?> _call(
    RegionalProfile profile,
    String method,
    Map<String, dynamic> req,
  ) async {
    final body = {
      'lang': 'de',
      'svcReqL': [
        {'cfg': const <String, dynamic>{}, 'meth': method, 'req': req},
      ],
      'client': {
        'id': profile.clientId,
        'type': profile.clientType,
        if (profile.clientName != null) 'name': profile.clientName,
        'v': _clientVersion,
      },
      'ver': _protocolVersion,
      'auth': {'type': 'AID', 'aid': profile.aid},
    };
    try {
      final res = await _client
          .post(
            Uri.parse(profile.endpoint),
            headers: const {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
              'User-Agent': _userAgent,
            },
            body: utf8.encode(json.encode(body)),
          )
          .timeout(_timeout);
      if (res.statusCode != 200) {
        AppLog.log(
          '${profile.id} $method HTTP ${res.statusCode}',
          tag: 'regional',
        );
        // A 5xx / gateway error is the endpoint being down, not this one call
        // being wrong — take it out of rotation so the next leg is instant.
        if (res.statusCode >= 500) _markDead(profile);
        return null;
      }
      final data =
          json.decode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      final svc = (data['svcResL'] as List<dynamic>?)?.firstOrNull;
      if (svc is! Map<String, dynamic> || svc['err'] != 'OK') {
        AppLog.log(
          '${profile.id} $method err ${svc is Map ? svc['err'] : '?'}',
          tag: 'regional',
        );
        return null;
      }
      return svc['res'] as Map<String, dynamic>?;
    } catch (e) {
      // Timeout, DNS failure, connection refused — the endpoint is unreachable,
      // so stop trying it for a while instead of eating a timeout per leg.
      AppLog.log('${profile.id} $method failed: $e', tag: 'regional');
      _markDead(profile);
      return null;
    }
  }

  /// The HAFAS id for [stop], by name and confirmed by coordinates.
  ///
  /// HAFAS ids are not DB's EVA numbers (Kiel Hbf: 9049076 vs 699275), so the
  /// join is over the name — and then checked against the coordinate, because a
  /// name alone matches "Kiel Hbf/Kaistraße" just as happily.
  Future<String?> _locationIdFor(RegionalProfile profile, Station stop) {
    final key = '${profile.id}/${stop.id.isNotEmpty ? stop.id : stop.name}';
    if (_locations.containsKey(key)) return Future.value(_locations[key]);
    return _locationsInflight[key] ??= _resolveLocation(profile, key, stop);
  }

  Future<String?> _resolveLocation(
    RegionalProfile profile,
    String key,
    Station stop,
  ) async {
    final res = await _call(profile, 'LocMatch', {
      'input': {
        'loc': {'type': 'S', 'name': '${stop.name}?'},
        'maxLoc': 8,
        'field': 'S',
      },
    });
    final locs =
        ((res?['match'] as Map<String, dynamic>?)?['locL'] as List<dynamic>?) ??
        const [];
    String? best;
    double bestMetres = double.infinity;
    for (final l in locs.whereType<Map<String, dynamic>>()) {
      final extId = l['extId'] as String?;
      final crd = l['crd'] as Map<String, dynamic>?;
      if (extId == null || crd == null) continue;
      // HAFAS coordinates are integer micro-degrees.
      final lat = (crd['y'] as num?)?.toDouble();
      final lon = (crd['x'] as num?)?.toDouble();
      if (lat == null || lon == null) continue;
      final d = _metres(stop.latitude!, stop.longitude!, lat / 1e6, lon / 1e6);
      if (d < bestMetres) {
        bestMetres = d;
        best = extId;
      }
    }
    // 300 m: the same stop as seen by two datasets, never the next one along.
    final resolved = bestMetres <= 300 ? best : null;
    AppLog.log(
      '${profile.id} loc "${AppLog.pii(stop.name)}" → '
      '${resolved == null ? 'kein Treffer' : AppLog.pii(resolved, 'ID')}'
      '${resolved != null ? ' (${bestMetres.round()} m)' : ''}',
      tag: 'regional',
    );
    _locations[key] = resolved;
    _locationsInflight.remove(key);
    return resolved;
  }

  // ---- EFA / Mentz -------------------------------------------------------
  //
  // Same two steps as HAFAS under different names: resolve the stop, then read
  // its departure board. The board carries `plannedPlatformName` next to
  // `platformName`, which is exactly the pair this whole service exists for.

  Future<String?> _efaStopId(RegionalProfile profile, Station stop) {
    final key = '${profile.id}/${stop.id.isNotEmpty ? stop.id : stop.name}';
    if (_locations.containsKey(key)) return Future.value(_locations[key]);
    return _locationsInflight[key] ??= _resolveEfaStop(profile, key, stop);
  }

  Future<String?> _resolveEfaStop(
    RegionalProfile profile,
    String key,
    Station stop,
  ) async {
    final data = await _efaGet(profile, 'XML_STOPFINDER_REQUEST', {
      'name_sf': stop.name,
      'type_sf': 'any',
      'coordOutputFormat': 'WGS84[DD.ddddd]',
    });
    final locs = (data?['locations'] as List<dynamic>?) ?? const [];
    String? best;
    var bestMetres = double.infinity;
    for (final l in locs.whereType<Map<String, dynamic>>()) {
      final id = l['id'] as String?;
      if (id == null) continue;
      final coord = l['coord'];
      // EFA hands coordinates back as [lat, lon] in WGS84 decimal degrees.
      if (coord is List && coord.length >= 2) {
        final lat = (coord[0] as num?)?.toDouble();
        final lon = (coord[1] as num?)?.toDouble();
        if (lat != null && lon != null) {
          final d = _metres(stop.latitude!, stop.longitude!, lat, lon);
          if (d < bestMetres) {
            bestMetres = d;
            best = id;
          }
          continue;
        }
      }
      // No coordinate: only acceptable if nothing better turns up.
      best ??= id;
    }
    final resolved = (bestMetres <= 300 || bestMetres == double.infinity)
        ? best
        : null;
    AppLog.log(
      '${profile.id} efa stop "${AppLog.pii(stop.name)}" → '
      '${resolved == null ? 'nichts' : AppLog.pii(resolved, 'ID')}',
      tag: 'regional',
    );
    _locations[key] = resolved;
    _locationsInflight.remove(key);
    return resolved;
  }

  Future<List<RegionalDeparture>> _efaBoard(
    RegionalProfile profile,
    String stopId,
    DateTime around,
  ) {
    final bucket = around.millisecondsSinceEpoch ~/ (15 * 60 * 1000);
    final key = '${profile.id}/$stopId@$bucket';
    final cached = _boards[key];
    if (cached != null) return Future.value(cached);
    return _boardsInflight[key] ??= _fetchEfaBoard(
      profile,
      key,
      stopId,
      around,
    );
  }

  Future<List<RegionalDeparture>> _fetchEfaBoard(
    RegionalProfile profile,
    String key,
    String stopId,
    DateTime around,
  ) async {
    final from = around.subtract(const Duration(minutes: 5));
    final data = await _efaGet(profile, 'XML_DM_REQUEST', {
      'name_dm': stopId,
      'type_dm': 'stop',
      'mode': 'direct',
      'useRealtime': '1',
      'limit': '60',
      'itdDate': '${from.year}${_two(from.month)}${_two(from.day)}',
      'itdTime': '${_two(from.hour)}${_two(from.minute)}',
    });
    final list = parseEfaBoard(data);
    AppLog.log(
      '${profile.id} efa board ${AppLog.pii(stopId, 'ID')}: ${list.length} departures, '
      '${list.where((d) => d.moved).length} moved',
      tag: 'regional',
    );
    _boards[key] = list;
    _boardsInflight.remove(key);
    return list;
  }

  Future<Map<String, dynamic>?> _efaGet(
    RegionalProfile profile,
    String path,
    Map<String, String> params,
  ) async {
    final uri = Uri.parse('${profile.endpoint}/$path').replace(
      queryParameters: {
        'outputFormat': 'rapidJSON',
        'version': '10.2.10.139',
        ...params,
      },
    );
    try {
      final res = await _client
          .get(
            uri,
            headers: const {
              'Accept': 'application/json',
              'User-Agent': _userAgent,
            },
          )
          .timeout(_timeout);
      if (res.statusCode != 200) {
        AppLog.log(
          '${profile.id} $path HTTP ${res.statusCode}',
          tag: 'regional',
        );
        if (res.statusCode >= 500) _markDead(profile);
        return null;
      }
      return json.decode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    } catch (e) {
      AppLog.log('${profile.id} $path failed: $e', tag: 'regional');
      _markDead(profile);
      return null;
    }
  }

  /// EFA `XML_DM_REQUEST` (rapidJSON) → departures. Exposed for tests.
  static List<RegionalDeparture> parseEfaBoard(Map<String, dynamic>? data) {
    if (data == null) return const [];
    final events = data['stopEvents'];
    if (events is! List) return const [];
    final out = <RegionalDeparture>[];
    for (final e in events.whereType<Map<String, dynamic>>()) {
      final loc = e['location'];
      final props = loc is Map<String, dynamic> ? loc['properties'] : null;
      final p = props is Map<String, dynamic> ? props : const {};
      final transport = e['transportation'];
      final t = transport is Map<String, dynamic> ? transport : const {};
      final dest = t['destination'];
      final planned = DateTime.tryParse(
        e['departureTimePlanned'] as String? ?? '',
      );
      out.add(
        RegionalDeparture(
          line: ((t['number'] ?? t['name']) as String? ?? '').trim(),
          direction:
              (dest is Map<String, dynamic>
                      ? dest['name'] as String? ?? ''
                      : '')
                  .trim(),
          // EFA timestamps are UTC ("…Z"); the board is matched in local time.
          plannedTime: planned == null
              ? null
              : planned.toLocal().hour * 60 + planned.toLocal().minute,
          plannedPlatform:
              _efaText(p['plannedPlatformName']) ?? _efaText(p['platformName']),
          livePlatform: _efaText(p['platformName']) ?? _efaText(p['platform']),
          notes: _efaNotes(e['infos']),
        ),
      );
    }
    return out;
  }

  static String? _efaText(Object? v) {
    if (v is! String) return null;
    final t = v.trim();
    return t.isEmpty ? null : t;
  }

  /// The operator's own disruption headlines for a departure.
  static List<String> _efaNotes(Object? infos) {
    if (infos is! List) return const [];
    final out = <String>[];
    for (final i in infos.whereType<Map<String, dynamic>>()) {
      final head =
          _efaText(i['subtitle']) ??
          _efaText(i['title']) ??
          _efaText(i['content']);
      if (head == null || out.contains(head)) continue;
      // These run long; the row shows a headline, not an essay.
      out.add(head.length > 120 ? '${head.substring(0, 117)}…' : head);
    }
    return out;
  }

  /// The departure board at [extId] around [around].
  Future<List<RegionalDeparture>> _board(
    RegionalProfile profile,
    String extId,
    DateTime around,
  ) {
    final bucket = around.millisecondsSinceEpoch ~/ (15 * 60 * 1000);
    final key = '${profile.id}/$extId@$bucket';
    final cached = _boards[key];
    if (cached != null) return Future.value(cached);
    return _boardsInflight[key] ??= _fetchBoard(profile, key, extId, around);
  }

  Future<List<RegionalDeparture>> _fetchBoard(
    RegionalProfile profile,
    String key,
    String extId,
    DateTime around,
  ) async {
    // Start the board a few minutes early so a bus running late is still on it.
    final from = around.subtract(const Duration(minutes: 5));
    final res = await _call(profile, 'StationBoard', {
      'type': 'DEP',
      'date': _date(from),
      'time': _time(from),
      'stbLoc': {'extId': extId},
      'maxJny': 80,
    });
    final list = parseBoard(res);
    AppLog.log(
      '${profile.id} board ${AppLog.pii(extId, 'ID')}: ${list.length} departures, '
      '${list.where((d) => d.moved).length} moved',
      tag: 'regional',
    );
    _boards[key] = list;
    _boardsInflight.remove(key);
    return list;
  }

  /// HAFAS `StationBoard` response → departures. Exposed for tests.
  static List<RegionalDeparture> parseBoard(Map<String, dynamic>? res) {
    if (res == null) return const [];
    final common = res['common'];
    final prodRaw = common is Map<String, dynamic> ? common['prodL'] : null;
    final prodL = prodRaw is List<dynamic> ? prodRaw : const [];
    final himRaw = common is Map<String, dynamic> ? common['himL'] : null;
    final himL = himRaw is List<dynamic> ? himRaw : const [];
    final jnyRaw = res['jnyL'];
    final out = <RegionalDeparture>[];
    for (final j
        in (jnyRaw is List<dynamic> ? jnyRaw : const [])
            .whereType<Map<String, dynamic>>()) {
      final stop = j['stbStop'] as Map<String, dynamic>?;
      if (stop == null) continue;
      final prodX = j['prodX'];
      final prod = (prodX is int && prodX >= 0 && prodX < prodL.length)
          ? prodL[prodX] as Map<String, dynamic>?
          : null;
      out.add(
        RegionalDeparture(
          line: (prod?['name'] as String? ?? '').trim(),
          direction: (j['dirTxt'] as String? ?? '').trim(),
          plannedTime: _hhmmss(stop['dTimeS'] as String?),
          plannedPlatform: _platform(stop, 'S'),
          livePlatform: _platform(stop, 'R'),
          notes: _himHeads(himL, [j['msgL'], stop['msgL']]),
        ),
      );
    }
    return out;
  }

  /// The headlines of the disruption messages hung on a departure — this is
  /// where the operator says WHY the bay moved ("Sperrung Bussteig B1 am
  /// Hauptbahnhof"). Deduped: HAFAS links the same message from several places.
  static List<String> _himHeads(List<dynamic> himL, List<dynamic> msgLists) {
    final out = <String>[];
    for (final msgs in msgLists) {
      if (msgs is! List<dynamic>) continue;
      for (final m in msgs.whereType<Map<String, dynamic>>()) {
        final x = m['himX'];
        if (x is! int || x < 0 || x >= himL.length) continue;
        final him = himL[x];
        if (him is! Map<String, dynamic>) continue;
        final head = (him['head'] as String? ?? '').trim();
        if (head.isEmpty || out.contains(head)) continue;
        out.add(head);
      }
    }
    return out;
  }

  /// Both HAFAS spellings: the flat `dPlatfS`/`dPlatfR` and the newer
  /// `dPltfS`/`dPltfR` object with a `txt`.
  static String? _platform(Map<String, dynamic> stop, String suffix) {
    final flat = stop['dPlatf$suffix'];
    if (flat is String && flat.trim().isNotEmpty) return flat.trim();
    final obj = stop['dPltf$suffix'];
    if (obj is Map<String, dynamic>) {
      final txt = obj['txt'];
      if (txt is String && txt.trim().isNotEmpty) return txt.trim();
    }
    return null;
  }

  /// Where the bus for [line] towards [towards] really leaves from, when that
  /// differs from the timetable — otherwise null, and nothing changes.
  ///
  /// [plannedDeparture] is matched against the board's scheduled time (not the
  /// live one): that is the value both sides agree on however late the bus is.
  Future<PlatformCorrection?> platformCorrection({
    required Station stop,
    required String? line,
    required String? towards,
    required DateTime plannedDeparture,
    String? product,
    String? dbPlatform,
  }) async {
    final lat = stop.latitude, lon = stop.longitude;
    if (lat == null || lon == null) return null;
    if (product != null && !coversProduct(product)) return null;

    // Most local authority first: a city network carries bay-level detail its
    // state-wide neighbour does not. The first one that both knows the stop and
    // has this departure answers; the rest are never asked.
    //
    // Bounded twice over — a dead backend is skipped outright (the breaker),
    // and the whole loop stops at [_budget] so a couple of slow ones can't add
    // up to a spinner that outlives the glance.
    final deadline = DateTime.now().add(_budget);
    for (final profile in regionalProfilesFor(lat, lon)) {
      if (_isDead(profile)) continue;
      if (DateTime.now().isAfter(deadline)) {
        AppLog.log(
          'regional budget aufgebraucht, Rest übersprungen',
          tag: 'regional',
        );
        break;
      }
      final extId = profile.backend == RegionalBackend.efa
          ? await _efaStopId(profile, stop)
          : await _locationIdFor(profile, stop);
      if (extId == null) continue;
      final board = profile.backend == RegionalBackend.efa
          ? await _efaBoard(profile, extId, plannedDeparture)
          : await _board(profile, extId, plannedDeparture);
      if (board.isEmpty) continue;
      final hit = matchDeparture(
        board,
        line: line,
        towards: towards,
        plannedDeparture: plannedDeparture,
        source: profile.label,
        dbPlatform: dbPlatform,
      );
      if (hit != null) return hit;
    }
    return null;
  }

  /// The correction for one ride out of a board. Exposed for tests, which is
  /// where the matching rules actually live.
  ///
  /// Time first (a bay is per departure, not per line), then the line, then the
  /// destination as a tiebreak — a stop can have the same line leaving in two
  /// directions from two bays within the same minute.
  static PlatformCorrection? matchDeparture(
    List<RegionalDeparture> board, {
    String? line,
    String? towards,
    required DateTime plannedDeparture,
    Duration tolerance = const Duration(minutes: 2),
    String source = 'Verbund',
    String? dbPlatform,
  }) {
    final wantedLine = _lineKey(line);
    final wantedTo = _placeKey(towards);
    final minutes = plannedDeparture.hour * 60 + plannedDeparture.minute;

    // Every same-line departure within tolerance, with its minute distance.
    // NOT filtered to `moved`: a closed bay with no live replacement yet isn't
    // "moved", but still carries a warning we want to surface.
    final near = <({RegionalDeparture d, int diff})>[];
    for (final d in board) {
      final t = d.plannedTime;
      if (t == null) continue;
      if (wantedLine != null && _lineKey(d.line) != wantedLine) continue;
      var diff = (t - minutes).abs();
      // Around midnight the board wraps; 23:58 and 00:01 are three minutes apart.
      if (diff > 720) diff = 1440 - diff;
      if (diff > tolerance.inMinutes) continue;
      near.add((d: d, diff: diff));
    }
    if (near.isEmpty) return null;

    // Time first. An exact-minute departure wins over a neighbour a minute off —
    // that is what tells "22 → Suchsdorf 09:39" apart from "22 → Schwentinental
    // 09:38" WITHOUT depending on the destination label agreeing between two
    // backends: DB calls this ride "Rungholtplatz", NAH.SH calls it "Suchsdorf",
    // and a direction filter would then throw the right departure away.
    final best = near.map((e) => e.diff).reduce(math.min);
    var pool = [
      for (final e in near)
        if (e.diff == best) e.d,
    ];

    // Only if the exact time still leaves more than one (two lines-22 in the
    // same minute) does the destination break the tie — and a differing label
    // then just means "can't tell", never a hard "no".
    if (pool.length > 1 && wantedTo != null) {
      final byDir = pool
          .where((d) => _directionMatches(d.direction, wantedTo))
          .toList();
      if (byDir.length == 1) pool = byDir;
    }
    if (pool.length != 1) return null;
    return _correctionOf(pool.first, source, dbPlatform);
  }

  /// The message that names the bay the bus left, when there is one — at Kiel
  /// Hbf "Sperrung Bussteig B1 am Hauptbahnhof", which is the difference between
  /// "why is it B2 now" and a bare change.
  static String? _bestNote(RegionalDeparture d) {
    final bay = d.plannedPlatform?.toLowerCase();
    if (bay != null) {
      for (final n in d.notes) {
        if (n.toLowerCase().contains(bay)) return n;
      }
    }
    return d.notes.isEmpty ? null : d.notes.first;
  }

  static PlatformCorrection? _correctionOf(
    RegionalDeparture d,
    String source,
    String? dbPlatform,
  ) {
    if (d.moved) {
      return (
        // What DB itself says, when we know it — that is the value the rider
        // sees everywhere else in the app, and the one this contradicts.
        planned: dbPlatform ?? d.plannedPlatform!,
        live: d.livePlatform!,
        note: _bestNote(d),
        source: source,
        closed: false,
      );
    }
    // Not moved, but a construction notice names the planned bay as closed.
    // The realtime replacement only shows up near departure, while this notice
    // is planned and present days ahead — so we can still warn the rider that
    // the bay their trip is booked from is shut, even without the new bay yet.
    final closure = _closureNote(d);
    if (closure != null) {
      final planned = dbPlatform ?? d.plannedPlatform;
      if (planned != null) {
        return (
          planned: planned,
          live: planned,
          note: closure,
          source: source,
          closed: true,
        );
      }
    }
    return null;
  }

  /// A notice on [d] that says [d]'s own planned bay is closed, or null. Both
  /// halves have to hold: a closure word AND the bay's own code named in the
  /// text, so "Sperrung Bussteig B1" only fires for the departure planned from
  /// B1, not for every bus at the station.
  static String? _closureNote(RegionalDeparture d) {
    final bay = d.plannedPlatform;
    if (bay == null) return null;
    final bayRe = RegExp(
      r'(^|\D)' + RegExp.escape(bay) + r'(\D|$)',
      caseSensitive: false,
    );
    for (final n in d.notes) {
      final low = n.toLowerCase();
      final closed =
          low.contains('sperr') ||
          low.contains('gesperrt') ||
          low.contains('entfäll') ||
          low.contains('nicht bedient') ||
          low.contains('kann nicht');
      if (closed && bayRe.hasMatch(n)) return n;
    }
    return null;
  }

  /// Whether a board entry heads where the rider does. Prefix either way, since
  /// the two sources spell the same place differently often enough
  /// ("Suchsdorf" vs "Kiel Suchsdorf, Wendeschleife").
  static bool _directionMatches(String boardDirection, String wanted) {
    final d = _placeKey(boardDirection);
    if (d == null) return false;
    return d == wanted || d.startsWith(wanted) || wanted.startsWith(d);
  }

  /// "Bus 22" / "22" / "bus22" all mean line 22.
  static String? _lineKey(String? s) {
    if (s == null) return null;
    final t = s
        .toUpperCase()
        .replaceAll(RegExp(r'\b(BUS|TRAM|STR|FÄHRE|FAEHRE)\b'), '')
        .replaceAll(RegExp(r'[\s.\-_/]'), '');
    return t.isEmpty ? null : t;
  }

  static String? _placeKey(String? s) {
    if (s == null) return null;
    final head = s.split(',').first;
    final t = head.toLowerCase().replaceAll(RegExp(r'[^a-z0-9äöüß]'), '');
    return t.isEmpty ? null : t;
  }

  static String _date(DateTime t) => '${t.year}${_two(t.month)}${_two(t.day)}';
  static String _time(DateTime t) => '${_two(t.hour)}${_two(t.minute)}00';
  static String _two(int v) => v.toString().padLeft(2, '0');

  /// HAFAS "HHMMSS" → minutes since midnight. A leading day offset ("1093900",
  /// the day after) is tolerated by reading the last six digits.
  static int? _hhmmss(String? s) {
    if (s == null || s.length < 6) return null;
    final t = s.substring(s.length - 6);
    final h = int.tryParse(t.substring(0, 2));
    final m = int.tryParse(t.substring(2, 4));
    if (h == null || m == null) return null;
    return h * 60 + m;
  }

  static double _metres(double lat1, double lon1, double lat2, double lon2) {
    final dy = (lat1 - lat2) * 111320.0;
    final dx = (lon1 - lon2) * 111320.0 * math.cos(lat1 * math.pi / 180.0);
    return math.sqrt(dx * dx + dy * dy);
  }
}

/// One departure off the NAH.SH board.
class RegionalDeparture {
  final String line;
  final String direction;

  /// Scheduled departure as minutes since midnight.
  final int? plannedTime;

  final String? plannedPlatform;
  final String? livePlatform;

  /// Headlines of the operator's disruption messages for this departure.
  final List<String> notes;

  const RegionalDeparture({
    required this.line,
    required this.direction,
    required this.plannedTime,
    required this.plannedPlatform,
    required this.livePlatform,
    this.notes = const [],
  });

  /// This departure has been moved to a different platform — a real move, not
  /// the same one described more precisely.
  ///
  /// Some backends "change" `7` to `7 D-G` or `11` to `11 B-C`: that is the
  /// carriage sector being filled in, and at Köln Hbf it accounts for 31 of 76
  /// departures. Reporting those as a platform change would bury the one that
  /// really moved in noise the rider must then ignore.
  bool get moved {
    final planned = plannedPlatform, live = livePlatform;
    if (planned == null || live == null || planned == live) return false;
    return !_sameTrack(planned, live);
  }

  /// Whether two platform strings name the same track, one just with sectors.
  static bool _sameTrack(String a, String b) {
    final ta = _trackOf(a), tb = _trackOf(b);
    return ta.isNotEmpty && ta == tb;
  }

  /// The track part of a platform label: "7 D-G" → "7", "11 B-C" → "11",
  /// "5 Süd" → "5SÜD" (a different platform, not a sector), "6a" → "6A".
  static String _trackOf(String s) {
    final t = s.trim().toUpperCase();
    // Leading number plus a letter STUCK to it ("6a", "3a") — a letter after a
    // space is a sector ("7 D"), which is a different thing entirely.
    final m = RegExp(r'^(\d+[A-Z]?)\b').firstMatch(t);
    if (m == null) return t.replaceAll(RegExp(r'\s+'), '');
    final head = m.group(1)!.replaceAll(RegExp(r'\s+'), '');
    final rest = t.substring(m.end).trim();
    // Sector suffixes are letters and ranges of them: "D-G", "B-C", "A".
    if (rest.isEmpty || RegExp(r'^[A-Z](\s*-\s*[A-Z])?$').hasMatch(rest)) {
      return head;
    }
    // Anything else ("Süd", "Ost") names a different platform.
    return '$head${rest.replaceAll(RegExp(r'\s+'), '')}';
  }
}
