import 'dart:convert';
import 'dart:math';
import 'package:http/http.dart' as http;

import '../core/app_log.dart';
import '../models/seat_map.dart';

/// Client for the DB Navigator graphical seat display (`/mob/gsd`).
///
/// `gsd_v3` is a server-rendered page: the seat data we want is in a
/// `<script id="ssr_data">` JSON blob. The request needs neither auth nor
/// cookies — the seat reservation status is keyed on train number + the
/// boarding/alighting EVA + planned times. The booking `zugfahrtKey` is
/// ignored by the backend (verified empirically), so we drive it from a
/// train run's leg data directly.
///
/// Coach geometry (seat positions) comes from `/mob/gsd/api/wagentypen/{typ}`
/// and is cached per coach type for the session.
class SeatMapService {
  final http.Client _client = http.Client();
  final _rng = Random();
  final Map<String, CoachLayout?> _layoutCache = {};

  static const _base = 'https://app.services-bahn.de/mob/gsd';
  static const _ua = 'DBNavigator/Android/26.9.0';

  /// Only these long-distance products carry a reservable seat plan in RIFF.
  static const reservableProducts = {'ICE', 'IC', 'EC', 'ECE', 'IRE'};

  /// Fetch the seat map for one segment of a train run.
  ///
  /// [fahrtNr] is the bare train number (e.g. "1703"). [abfahrtEva]/[ankunftEva]
  /// are station EVA numbers; [abfahrtZeit]/[ankunftZeit] the *planned* local
  /// times at those stops. Returns null when the backend has no plan for this
  /// train (regional trains, sold-out inventory, or a bad segment).
  Future<SeatMap?> fetchSeatMap({
    required String fahrtNr,
    required String abfahrtEva,
    required DateTime abfahrtZeit,
    required String ankunftEva,
    required DateTime ankunftZeit,
    bool firstClass = false,
    String inventarsystem = 'RIFF',
  }) async {
    final data = {
      'buchungskontext': {
        'quellSystem': 'SIMA',
        'buchungsKontextId': _uuid(),
        'buchungsKontextDaten': {
          'zugnummer': fahrtNr,
          // zugfahrtKey is ignored by the backend; send empty.
          'zugfahrtKey': '',
          'abfahrtHalt': {
            'locationId': abfahrtEva,
            'abfahrtZeit': _localNaive(abfahrtZeit),
          },
          'ankunftHalt': {
            'locationId': ankunftEva,
            'ankunftZeit': _localNaive(ankunftZeit),
          },
          'inventarsystem': inventarsystem,
          'platzbedarfe': [
            {
              'platzprofilCode': 'StandardEinzelperson',
              'anzahl': 1.0,
              'klasse': firstClass ? 'KLASSE_1' : 'KLASSE_2',
            },
          ],
        },
      },
      'correlationID': '${_uuid()}_${_uuid()}',
      'lang': 'de',
      'theme': 'app',
    };

    final url =
        '$_base/gsd_v3?data=${Uri.encodeQueryComponent(jsonEncode(data))}';
    AppLog.log(
      'seat map zug ${AppLog.pii(fahrtNr, 'Zug')} '
      '${AppLog.pii(abfahrtEva, 'ID')}→${AppLog.pii(ankunftEva, 'ID')} '
      'klasse=${firstClass ? 1 : 2}',
      tag: 'gsd',
    );
    // The gsd page is served behind an edge that intermittently answers a 200
    // WITHOUT the ssr_data blob (or a 5xx) — a single miss then reads to the
    // user as "kein Sitzplatz verfügbar" although the train has seats. Retry a
    // couple of times before giving up (#seat).
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        final res = await _client
            .get(Uri.parse(url), headers: const {'User-Agent': _ua})
            .timeout(const Duration(seconds: 15));
        if (res.statusCode != 200) {
          AppLog.log(
            'gsd_v3 HTTP ${res.statusCode} (try ${attempt + 1})',
            tag: 'gsd',
          );
          continue;
        }
        final ssr = _extractSsr(utf8.decode(res.bodyBytes));
        if (ssr == null) {
          AppLog.log('gsd_v3 no ssr_data (try ${attempt + 1})', tag: 'gsd');
          continue;
        }
        final map = SeatMap.fromSsr(ssr);
        AppLog.log(
          'seat map: ${map.coaches.length} coaches, '
          '${map.totalFree}/${map.totalSeats} free',
          tag: 'gsd',
        );
        return map.isEmpty ? null : map;
      } catch (e) {
        AppLog.log('seat map failed (try ${attempt + 1}): $e', tag: 'gsd');
      }
    }
    return null;
  }

  /// Physical layout for a coach type, cached per type for the session.
  Future<CoachLayout?> fetchLayout(String wagentyp) async {
    if (_layoutCache.containsKey(wagentyp)) return _layoutCache[wagentyp];
    try {
      final url = '$_base/api/wagentypen/${Uri.encodeComponent(wagentyp)}';
      final res = await _client
          .get(Uri.parse(url), headers: const {'User-Agent': _ua})
          .timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) {
        AppLog.log('wagentyp $wagentyp HTTP ${res.statusCode}', tag: 'gsd');
        return _layoutCache[wagentyp] = null;
      }
      final json =
          jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      return _layoutCache[wagentyp] = CoachLayout.fromJson(json);
    } catch (e) {
      AppLog.log('wagentyp $wagentyp failed ($e)', tag: 'gsd');
      return _layoutCache[wagentyp] = null;
    }
  }

  /// Fetch all coach layouts for a seat map in parallel, returning the map with
  /// each coach's [SeatCoach.layout] attached where available.
  Future<SeatMap> attachLayouts(SeatMap map) async {
    final coaches = await Future.wait(
      map.coaches.map((c) async {
        final layout = await fetchLayout(c.wagentyp);
        return c.withLayout(layout);
      }),
    );
    return SeatMap(coaches: coaches);
  }

  /// Extract and decode the `<script id="ssr_data">…</script>` JSON.
  Map<String, dynamic>? _extractSsr(String html) {
    final m = RegExp(
      r"id='ssr_data'\s*>(.*?)</script>",
      dotAll: true,
    ).firstMatch(html);
    if (m == null) return null;
    try {
      return jsonDecode(m.group(1)!) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  /// Local time without an offset suffix, as the booking flow sends
  /// (`2026-05-29T21:45:00`).
  String _localNaive(DateTime dt) =>
      dt.toLocal().toIso8601String().split('.').first;

  String _uuid() {
    final b = List<int>.generate(16, (_) => _rng.nextInt(256));
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    String hex(int x) => x.toRadixString(16).padLeft(2, '0');
    final s = b.map(hex).join();
    return '${s.substring(0, 8)}-${s.substring(8, 12)}-${s.substring(12, 16)}'
        '-${s.substring(16, 20)}-${s.substring(20)}';
  }

  void dispose() => _client.close();
}
