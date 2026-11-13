// Shared plumbing for every check: HTTP over dart:io, /mob pacing, retries,
// fixtures and the check registry.
//
// Why dart:io and not Python: Akamai in front of DB fingerprints the TLS
// handshake, not the headers. On 2026-11-13 it started to refuse curl_cffi's
// Chrome fingerprint on /mob while the app (dart:io) kept working, so the
// Python health check reported 22 broken APIs that were fine. A probe on the
// app's own TLS stack sees exactly what the app sees.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// Per-request timeout (the Python script used 20 s).
const timeout = Duration(seconds: 20);

const dbnavUa = 'DBNavigator/Android/26.9.0';
const mobHost = 'app.services-bahn.de';

/// The /mob backend rate-limits per client: ~10 requests in ~6 s trip a block
/// that lasts minutes (and `Retry-After` lies about it). So consecutive /mob
/// requests stay this far apart — across processes too, see [_paceMob].
const mobMinInterval = Duration(seconds: 2);
const maxRetries = 3;

// --- Errors -----------------------------------------------------------------

/// The endpoint answered, but the shape we rely on is gone.
class CheckError implements Exception {
  final String message;
  CheckError(this.message);
  @override
  String toString() => message;
}

/// The check can't run here (a precondition is missing). Reported, never a
/// failure: it says nothing about the API.
class SkipCheck implements Exception {
  final String message;
  SkipCheck(this.message);
  @override
  String toString() => message;
}

/// Non-2xx status where the caller demanded success (requests' HTTPError).
class HttpError implements Exception {
  final int status;
  final String body;
  final Uri url;
  HttpError(this.status, this.body, this.url);
  @override
  String toString() {
    final b = body.length > 80 ? body.substring(0, 80) : body;
    return 'HTTP Error $status: $b';
  }
}

/// Transport failure (DNS, connect, timeout) — requests' RequestException.
class RequestException implements Exception {
  final String message;
  RequestException(this.message);
  @override
  String toString() => message;
}

// --- Response ---------------------------------------------------------------

class Resp {
  final Uri url;
  final int status;
  final Map<String, String> headers; // lower-case keys
  final List<int> bodyBytes;
  Resp(this.url, this.status, this.headers, this.bodyBytes);

  String? _text;
  String get text => _text ??= utf8.decode(bodyBytes, allowMalformed: true);

  dynamic json() => jsonDecode(text);

  /// `json()` as a map, or a [CheckError] naming [what] when it isn't one.
  Map<String, dynamic> jsonMap([String what = 'response']) {
    final j = json();
    if (j is Map<String, dynamic>) return j;
    throw CheckError('$what is not a JSON object');
  }

  bool get ok => status >= 200 && status < 300;

  /// Throws [HttpError] on 4xx/5xx, like requests' `raise_for_status`.
  void raiseForStatus() {
    if (status >= 400) throw HttpError(status, text, url);
  }

  String? header(String name) => headers[name.toLowerCase()];
}

// --- HTTP -------------------------------------------------------------------

final HttpClient _client = HttpClient()
  ..connectionTimeout = timeout
  // dart:io's own default UA ("Dart/x (dart:io)") is what the app sends where it
  // sets none; every DB call sets one explicitly anyway.
  ..autoUncompress = true;

/// Builds a URL with optional query parameters (values are stringified;
/// a list value repeats the key, like requests does).
Uri buildUri(String url, [Map<String, dynamic>? query]) {
  final base = Uri.parse(url);
  if (query == null || query.isEmpty) return base;
  final parts = <String>[];
  if (base.hasQuery && base.query.isNotEmpty) parts.add(base.query);
  query.forEach((k, v) {
    if (v == null) return;
    final values = v is Iterable ? v : [v];
    for (final one in values) {
      parts.add(
        '${Uri.encodeQueryComponent(k)}=${Uri.encodeQueryComponent('$one')}',
      );
    }
  });
  return base.replace(query: parts.join('&'));
}

/// One raw round trip. Note: dart:io follows redirects only for GET/HEAD —
/// [followRedirects] has no effect on a POST, which then returns the 3xx. That
/// is exactly what the app (package:http on dart:io) sees, so it stays.
/// [body] may be a String, bytes, or a Map (sent as
/// `application/x-www-form-urlencoded`, like requests' `data=dict`).
Future<Resp> _raw(
  String method,
  Uri uri, {
  Map<String, String>? headers,
  Object? body,
  Duration? timeoutOverride,
  bool followRedirects = true,
}) async {
  final t = timeoutOverride ?? timeout;
  try {
    return await () async {
      final req = await _client.openUrl(method, uri);
      req.followRedirects = followRedirects;
      req.maxRedirects = 10;
      headers?.forEach(
        (k, v) => req.headers.set(k, v, preserveHeaderCase: true),
      );
      List<int>? bytes;
      if (body is String) {
        bytes = utf8.encode(body);
      } else if (body is List<int>) {
        bytes = body;
      } else if (body is Map) {
        bytes = utf8.encode(
          body.entries
              .map(
                (e) =>
                    '${Uri.encodeQueryComponent('${e.key}')}='
                    '${Uri.encodeQueryComponent('${e.value}')}',
              )
              .join('&'),
        );
        if (headers == null ||
            !headers.keys.any((k) => k.toLowerCase() == 'content-type')) {
          req.headers.set('Content-Type', 'application/x-www-form-urlencoded');
        }
      }
      if (bytes != null) {
        // A length, not chunked: some edges answer chunked POSTs with 405.
        req.contentLength = bytes.length;
        req.add(bytes);
      }
      final res = await req.close();
      final out = <int>[];
      await for (final chunk in res) {
        out.addAll(chunk);
      }
      final h = <String, String>{};
      res.headers.forEach((k, v) => h[k.toLowerCase()] = v.join(', '));
      return Resp(uri, res.statusCode, h, out);
    }().timeout(t);
  } on TimeoutException {
    throw RequestException('timeout after ${t.inSeconds}s: ${uri.host}');
  } on SocketException catch (e) {
    throw RequestException('${e.message} (${uri.host})');
  } on HandshakeException catch (e) {
    throw RequestException('TLS: ${e.message} (${uri.host})');
  } on HttpException catch (e) {
    throw RequestException('${e.message} (${uri.host})');
  }
}

/// Keeps consecutive /mob requests [mobMinInterval] apart — across every
/// process on this machine, via a locked stamp file next to the package. Two
/// runs at once (or a run while the app is being tested) used to add up to a
/// self-inflicted 429 block that then read as "API changed".
Future<void> _paceMob() async {
  final f = File('${packageDir.path}/.mob_pace');
  final raf = await f.open(mode: FileMode.append);
  try {
    await raf.lock(FileLock.blockingExclusive);
    await raf.setPosition(0);
    final len = await raf.length();
    final raw = len > 0 ? utf8.decode(await raf.read(len)).trim() : '';
    final last = int.tryParse(raw) ?? 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    final wait = last + mobMinInterval.inMilliseconds - now;
    if (wait > 0) await Future<void>.delayed(Duration(milliseconds: wait));
    await raf.truncate(0);
    await raf.setPosition(0);
    await raf.writeString('${DateTime.now().millisecondsSinceEpoch}');
    await raf.flush();
  } finally {
    await raf.unlock();
    await raf.close();
  }
}

Future<Resp> _withRetry(
  String method,
  Uri uri, {
  Map<String, String>? headers,
  Object? body,
  Duration? timeoutOverride,
  bool followRedirects = true,
}) async {
  late Resp r;
  for (var attempt = 0; attempt <= maxRetries; attempt++) {
    if (uri.host == mobHost) await _paceMob();
    r = await _raw(
      method,
      uri,
      headers: headers,
      body: body,
      timeoutOverride: timeoutOverride,
      followRedirects: followRedirects,
    );
    if (r.status != 429 || attempt == maxRetries) return r;
    // Retry-After is unreliable here (says 5 s during a minutes-long block):
    // back off geometrically and take whichever is longer.
    final ra = int.tryParse(r.header('retry-after') ?? '') ?? 0;
    final wait = min(max(ra, 15 * (attempt + 1)), 60);
    await Future<void>.delayed(Duration(seconds: wait));
  }
  return r;
}

Future<Resp> get(
  String url, {
  Map<String, String>? headers,
  Map<String, dynamic>? query,
  Duration? timeout,
  bool followRedirects = true,
}) => _withRetry(
  'GET',
  buildUri(url, query),
  headers: headers,
  timeoutOverride: timeout,
  followRedirects: followRedirects,
);

Future<Resp> post(
  String url, {
  Map<String, String>? headers,
  Map<String, dynamic>? query,
  Object? body,
  Duration? timeout,
  bool followRedirects = true,
}) => _withRetry(
  'POST',
  buildUri(url, query),
  headers: headers,
  body: body,
  timeoutOverride: timeout,
  followRedirects: followRedirects,
);

/// Any other verb (HEAD, PUT, DELETE, OPTIONS …).
Future<Resp> request(
  String method,
  String url, {
  Map<String, String>? headers,
  Map<String, dynamic>? query,
  Object? body,
  Duration? timeout,
  bool followRedirects = true,
}) => _withRetry(
  method,
  buildUri(url, query),
  headers: headers,
  body: body,
  timeoutOverride: timeout,
  followRedirects: followRedirects,
);

/// POST a JSON body to /mob with the Navigator header set.
Future<Resp> mobPost(String path, String media, Object body) => post(
  'https://$mobHost/mob/$path',
  headers: vendoHeaders(media),
  body: jsonEncode(body),
);

/// GET from /mob with the Navigator header set.
Future<Resp> mobGet(String path, String media, {Map<String, dynamic>? query}) =>
    get(
      'https://$mobHost/mob/$path',
      headers: vendoHeaders(media)..remove('Content-Type'),
      query: query,
    );

// --- Headers ----------------------------------------------------------------

final _rng = Random.secure();

String uuid4() {
  final b = List<int>.generate(16, (_) => _rng.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final s = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${s.substring(0, 8)}-${s.substring(8, 12)}-${s.substring(12, 16)}'
      '-${s.substring(16, 20)}-${s.substring(20)}';
}

String corrId() => '${uuid4()}_${uuid4()}';

/// Exactly what `VendoService._headers` sends.
Map<String, String> vendoHeaders(String media) => {
  'Accept': media,
  'Content-Type': media,
  'Accept-Language': 'de',
  'User-Agent': dbnavUa,
  'X-App-Version': '26.9.0',
  'X-Correlation-ID': corrId(),
};

/// A plain mobile-Chrome header set for bahn.de web endpoints.
Map<String, String> browserHeaders() => {
  'User-Agent':
      'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/125.0.0.0 Mobile Safari/537.36',
  'Accept': 'application/json',
  'Accept-Language': 'de-DE,de;q=0.9',
};

// --- Fixtures ---------------------------------------------------------------

const kiel = '8000199';
const berlinHbf = '8011160';
const koelnHbf = '8000207';

const kielLoc =
    'A=1@O=Kiel Hbf@X=10131976@Y=54314982@U=80@L=8000199@'
    'p=1779908603@i=U×008001304@';
const berlinLoc =
    'A=1@O=Berlin Hbf@X=13369549@Y=52525589@U=80@L=8011160@'
    'p=1779908603@i=U×008065969@';
const hamburgLoc =
    'A=1@O=Hamburg Hbf@X=10006909@Y=53552733@U=80@L=8002549@'
    'i=U×008001071@';

/// An ICE trunk route that also carries a dense RE/RB service — the case where
/// an ["ALL"] search returns nothing but ICEs (see checkVendoVerkehrsmittel).
const munichLoc = 'A=1@O=München Hbf@X=11558339@Y=48140229@U=80@L=8000261@';
const augsburgLoc = 'A=1@O=Augsburg Hbf@X=10885802@Y=48365456@U=80@L=8000013@';

/// Berlin → Braunschweig: the ICE stops there and rides on to München. The
/// split scope check (#22) needs a route whose train clearly outlives the
/// journey.
const braunschweigLoc =
    'A=1@O=Braunschweig Hbf@X=10540293@Y=52252218@U=80@'
    'L=8000049@i=U×008013240@';

const bahnhofstafelMedia = 'application/x.db.vendo.mob.bahnhofstafeln.v2+json';
const zuglaufMedia = 'application/x.db.vendo.mob.zuglauf.v2+json';
const auftragMedia = 'application/x.db.vendo.mob.auftraege.v11+json';

String two(int v) => v.toString().padLeft(2, '0');
String ymd(DateTime d) => '${d.year}-${two(d.month)}-${two(d.day)}';
String hhmm(DateTime d) => '${two(d.hour)}:${two(d.minute)}';

/// POST /mob/bahnhofstafel/{abfahrt|ankunft} — the departure/arrival board.
/// Returns the positions list (each carries a `zuglaufId`).
Future<List<dynamic>> vendoBoard(String eva, {bool arrivals = false}) async {
  final now = DateTime.now();
  final r = await mobPost(
    'bahnhofstafel/${arrivals ? 'ankunft' : 'abfahrt'}',
    bahnhofstafelMedia,
    {
      'anfrageZeit': hhmm(now),
      'datum': ymd(now),
      'ursprungsBahnhofId': eva,
      'verkehrsmittel': ['ALL'],
    },
  );
  r.raiseForStatus();
  final key = arrivals
      ? 'bahnhofstafelAnkunftPositionen'
      : 'bahnhofstafelAbfahrtPositionen';
  return (r.jsonMap()[key] as List?) ?? const [];
}

// --- Repo paths -------------------------------------------------------------

/// `api-tests/healthcheck/` — this package.
final Directory packageDir = () {
  // bin/healthcheck.dart → package root. Works for `dart run` and for a
  // compiled snapshot run from the package directory.
  final script = Platform.script.toFilePath();
  var dir = File(script).parent;
  for (var i = 0; i < 4; i++) {
    if (File('${dir.path}/pubspec.yaml').existsSync() &&
        File(
          '${dir.path}/pubspec.yaml',
        ).readAsStringSync().contains('besser_bahn_healthcheck')) {
      return dir;
    }
    dir = dir.parent;
  }
  return Directory.current;
}();

/// The repository root.
Directory get repoRoot => packageDir.parent.parent;

/// A file of the Flutter app, path relative to `flutter-app/`.
File appFile(String relPath) => File('${repoRoot.path}/flutter-app/$relPath');

// --- Small helpers ----------------------------------------------------------

/// `m[key]` as a map, or an empty one.
Map<String, dynamic> mapOf(dynamic m, String key) {
  final v = m is Map ? m[key] : null;
  return v is Map<String, dynamic> ? v : <String, dynamic>{};
}

/// `m[key]` as a list, or an empty one.
List<dynamic> listOf(dynamic m, String key) {
  final v = m is Map ? m[key] : null;
  return v is List ? v : const [];
}

/// Maps in a list, skipping anything else.
List<Map<String, dynamic>> maps(dynamic list) => list is List
    ? list.whereType<Map<String, dynamic>>().toList()
    : const <Map<String, dynamic>>[];

/// Text shortened to [n] characters, for messages.
String clip(Object? s, [int n = 200]) {
  final t = '$s';
  return t.length > n ? t.substring(0, n) : t;
}

// --- Registry ---------------------------------------------------------------

typedef CheckFn = Future<String> Function();

class Check {
  final String name;
  final CheckFn run;

  /// Soft checks warn instead of fail (known-flaky sources, or ones that need
  /// the right train on the board right now).
  final bool soft;

  /// Which group file it lives in (for `--group`).
  final String group;

  const Check(this.name, this.run, {this.soft = false, required this.group});
}
