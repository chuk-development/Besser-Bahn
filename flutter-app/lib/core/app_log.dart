import 'dart:async';

import 'package:flutter/foundation.dart';

/// Lightweight global debug log.
///
/// Both prints to the console (visible in `flutter run` / logcat) and keeps a
/// ring buffer that the in-app Debug-Log screen renders live. No Riverpod ref
/// needed, so services can log too.
class AppLog {
  AppLog._();

  static const _max = 400;

  /// Live buffer the debug screen listens to.
  static final ValueNotifier<List<String>> messages =
      ValueNotifier<List<String>>(const []);

  static void log(String message, {String tag = ''}) {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final ms = now.millisecond.toString().padLeft(3, '0');
    final ts = '${two(now.hour)}:${two(now.minute)}:${two(now.second)}.$ms';
    final line = tag.isEmpty ? '$ts  $message' : '$ts  [$tag] $message';
    debugPrint(plain(line));
    final next = [...messages.value, line];
    messages.value = next.length > _max
        ? next.sublist(next.length - _max)
        : next;
  }

  /// Running count per distinct message, for [logCollapsed].
  static final Map<String, int> _counts = {};

  /// Log a message that may repeat thousands of times (e.g. a map tile that
  /// keeps failing offline). Instead of one line per occurrence — which buries
  /// every other log and makes debugging impossible — we keep a running count
  /// and only emit the line at a geometric cadence: ×1,2,3,4,5, then 25,50,75…,
  /// then every 100. So the log reads "… (×3)", "… (×50)" instead of an endless
  /// identical wall.
  static void logCollapsed(String message, {String tag = ''}) {
    final n = (_counts[message] ?? 0) + 1;
    _counts[message] = n;
    final emit = n <= 5 || (n < 100 && n % 25 == 0) || n % 100 == 0;
    if (emit) log('$message  (×$n)', tag: tag);
  }

  /// Install a [FlutterError.onError] filter that collapses the noisy map-tile /
  /// image-load errors (failed raster tile fetches et al.) into a single counted
  /// [logCollapsed] line and swallows their multi-line stack dump, while passing
  /// every OTHER framework error through untouched. Call once in main().
  ///
  /// These dumps come straight from Flutter's image-resource error reporter (not
  /// our per-layer `errorTileCallback`), so the only place to catch them all is
  /// here. Without this a flaky/offline connection floods the console with the
  /// identical tile-load exception, drowning out everything useful.
  // --- Tile-health timeline ------------------------------------------------
  static int _tileTotal = 0;
  static int _tileWindow = 0;
  static String _tileHost = '';
  static Timer? _tileTimer;
  static int _tileBurstStartMs = 0;
  static final Stopwatch _tileClock = Stopwatch()..start();

  /// True while the base map is PAUSED because the tile host(s) are
  /// hammering-unreachable. Every map watches this and drops its tile layers
  /// (vector AND raster) so neither can keep firing thousands of doomed
  /// requests/sec and choke the whole connection. It flips back after a short
  /// cooldown to probe whether the host has recovered.
  static final ValueNotifier<bool> tilesPaused = ValueNotifier<bool>(false);
  static Timer? _pauseTimer;

  /// Record one map-tile fetch failure on a 2-second TIMELINE instead of per
  /// tile. This is the diagnostic that shows the burst-then-recover pattern:
  ///   [tiles] 412 failed in 2s (tiles.openfreemap.org) — 412 total
  ///   [tiles] 380 failed in 2s (tiles.openfreemap.org) — 792 total
  ///   [tiles] recovered after 792 failures over 6s
  /// A burst that clears the moment the prefetch finishes = the connection is
  /// being starved by the scrape, not slow internet.
  static void tileError(String raw) {
    _tileTotal++;
    _tileWindow++;
    final h = _hostOf(raw);
    if (h.isNotEmpty) _tileHost = h;
    if (_tileBurstStartMs == 0) {
      _tileBurstStartMs = _tileClock.elapsedMilliseconds;
    }
    _tileTimer ??= Timer.periodic(
      const Duration(seconds: 2),
      (_) => _tileTick(),
    );
    // Pause ONLY on a true flood — the Linux socket-exhaustion storm was
    // 3000-4000 fails/2s; normal tile churn (zoom loads many tiles, a few blip)
    // must never trip it, or the map needlessly goes blank. High threshold,
    // short probe.
    if (!tilesPaused.value && _tileWindow >= 250) {
      tilesPaused.value = true;
      log('tile flood ($_tileWindow/2s) → pausing base map 4s', tag: 'tiles');
      _pauseTimer?.cancel();
      _pauseTimer = Timer(const Duration(seconds: 4), () {
        _tileWindow = 0;
        tilesPaused.value = false; // probe whether tiles are back
      });
    }
  }

  static void _tileTick() {
    if (_tileWindow > 0) {
      log(
        '$_tileWindow failed in 2s '
        '(${_tileHost.isEmpty ? "?" : _tileHost}) — $_tileTotal total',
        tag: 'tiles',
      );
      _tileWindow = 0;
    } else {
      final secs = ((_tileClock.elapsedMilliseconds - _tileBurstStartMs) / 1000)
          .round();
      log('recovered after $_tileTotal failures over ${secs}s', tag: 'tiles');
      _tileTimer?.cancel();
      _tileTimer = null;
      _tileTotal = 0;
      _tileBurstStartMs = 0;
    }
  }

  /// Pull the host out of a socket/tile error string for the timeline label.
  static String _hostOf(String s) {
    final m = RegExp(r'(?:address = |uri=https?://)([^,:/\s]+)').firstMatch(s);
    return m?.group(1) ?? '';
  }

  /// True for the noisy map-tile / tile-network errors we collapse (raster tile
  /// fetch misses plus the raw socket/host-lookup failures vector_map_tiles
  /// throws when a tile host is unreachable). Kept narrow so real errors still
  /// surface.
  static bool _isTileNoise(String s) =>
      s.contains(
        'HTTP request failed, statusCode',
      ) || // NetworkImageLoadException
      s.contains('Failed to load the tile') ||
      s.contains('openfreemap') ||
      s.contains('cartocdn') ||
      s.contains('Failed host lookup') ||
      s.contains('Network is unreachable') ||
      (s.contains('SocketException') && s.contains('tiles')) ||
      s.contains('Connection failed');

  static bool _installed = false;
  static void installErrorCollapsing() {
    if (_installed) return;
    _installed = true;

    final prev = FlutterError.onError;
    FlutterError.onError = (details) {
      final ex = details.exceptionAsString();
      if (_isTileNoise(ex)) {
        tileError(ex);
        return;
      }
      (prev ?? FlutterError.presentError)(details);
    };

    // vector_map_tiles fetches its tiles in async gaps and lets network errors
    // (Connection failed / Failed host lookup / Network unreachable) escape as
    // UNHANDLED zone errors — they bypass FlutterError.onError AND debugPrint,
    // so the Dart VM dumps each one with a full stack trace (the remaining
    // wall). Catch them here, collapse to one counted line, and mark handled.
    // Anything that isn't tile/network noise is passed through untouched.
    final prevPlatform = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = (error, stack) {
      final s = error.toString();
      if (_isTileNoise(s)) {
        tileError(s);
        return true; // handled — don't dump the stack
      }
      // vector_map_tiles cancels in-flight tile-render jobs when tiles scroll
      // out of view — benign, but surfaces as an unhandled 'Cancelled' with a
      // long executor stack. Swallow quietly (NOT counted as a tile failure).
      if (s == 'Cancelled' &&
          (stack.toString().contains('vector_map_tiles') ||
              stack.toString().contains('executor_lib'))) {
        return true;
      }
      return prevPlatform?.call(error, stack) ?? false;
    };

    // Catch-all for the CONSOLE: anything printed (flutter_map tile errors,
    // framework dumps, plugins) goes through `debugPrint`. We wrap it so a run
    // of the IDENTICAL line collapses into the first print + a periodic count,
    // instead of an endless identical wall that buries everything and can't be
    // scrolled past. AppLog's own lines carry a millisecond timestamp so they're
    // never identical back-to-back → they print normally.
    final original = debugPrint;
    String? last;
    var count = 0;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message == null) {
        original(null, wrapWidth: wrapWidth);
        return;
      }
      // Tile-network noise NEVER reaches the console raw — no matter which path
      // printed it. It's folded into the quiet 2-second [tiles] timeline only.
      if (_isTileNoise(message)) {
        tileError(message);
        return;
      }
      if (message == last) {
        count++;
        if (count == 3 || count == 10 || count == 50 || count % 200 == 0) {
          original('  ⤷ (same line ×$count)', wrapWidth: wrapWidth);
        }
        return;
      }
      if (count > 1) {
        original(
          '  ⤷ previous line repeated ×$count total',
          wrapWidth: wrapWidth,
        );
      }
      last = message;
      count = 1;
      original(message, wrapWidth: wrapWidth);
    };
  }

  /// Run [action], logging how long it took (ms) with [label]. Logs failures
  /// with their elapsed time too, then rethrows — so the debug log shows
  /// exactly which network call is slow or hanging.
  static Future<T> timed<T>(
    String label,
    Future<T> Function() action, {
    String tag = '',
  }) async {
    final sw = Stopwatch()..start();
    try {
      final result = await action();
      log('$label ✓ ${sw.elapsedMilliseconds}ms', tag: tag);
      return result;
    } catch (e) {
      log('$label ✗ ${sw.elapsedMilliseconds}ms ($e)', tag: tag);
      rethrow;
    }
  }

  static void clear() => messages.value = const [];

  // --- Personal data (#103) -------------------------------------------------
  //
  // People paste this log into public GitHub issues. Station names, trip keys,
  // coordinates and account numbers say where someone lives and travels, so
  // the Debug-Log can hide them. Call sites wrap such values in [pii]; the
  // buffer keeps the value between invisible markers, [plain] drops the
  // markers, [redact] swaps each value for a numbered placeholder. The same
  // value always gets the same number, so "Halt 1 → Halt 2, then Halt 2
  // failed" still reads as one story. A regex pass after that catches what no
  // call site marked (IDs and coordinates inside exception texts and URLs).

  static const _open = '\u{E000}';
  static const _sep = '\u{E001}';
  static const _close = '\u{E002}';
  static final _marked = RegExp('$_open([^$_sep]*)$_sep([^$_close]*)$_close');

  /// Mark [value] as personal data of the given [kind] ('Halt', 'Kunde', …).
  /// Use it inside the message string: `log('search ${pii(from.name)}')`.
  static String pii(Object? value, [String kind = 'Halt']) =>
      '$_open$kind$_sep$value$_close';

  /// [line] as written, markers removed.
  static String plain(String line) =>
      line.replaceAllMapped(_marked, (m) => m.group(2)!);

  /// [lines] with every personal value replaced. [tokens] keeps the numbering
  /// stable across calls — pass one map for one export.
  static List<String> redact(
    List<String> lines, [
    Map<String, String>? tokens,
  ]) {
    final seen = tokens ?? <String, String>{};
    final perKind = <String, int>{};
    for (final t in seen.values) {
      final kind = t.substring(1, t.lastIndexOf(' '));
      perKind[kind] = (perKind[kind] ?? 0) + 1;
    }
    String token(String kind, String value) =>
        seen.putIfAbsent('$kind\u0000$value', () {
          final n = (perKind[kind] ?? 0) + 1;
          perKind[kind] = n;
          return '‹$kind $n›';
        });
    return [
      for (final line in lines)
        _scrub(
          line.replaceAllMapped(
            _marked,
            (m) => m.group(2)!.trim().isEmpty
                ? m.group(2)!
                : token(m.group(1)!, m.group(2)!),
          ),
        ),
    ];
  }

  // Safety net for values no call site marked. Order matters: the HAFAS
  // location id first (it holds name, coordinates and EVA number in one), the
  // bare numbers last.
  static final _scrubbers = <(RegExp, String)>[
    // A=1@O=Berlin Hbf@X=13369549@Y=52525589@L=8011160@…
    (RegExp(r'A=\d+@(?:[A-Za-z]+=[^@]*@)+'), '‹Ort›'),
    (RegExp(r'eyJ[\w-]+\.[\w-]+\.[\w-]+'), '‹Token›'),
    (RegExp(r'[\w.+-]+@[\w-]+\.[\w.-]+'), '‹E-Mail›'),
    // Query strings carry station ids, coordinates and dates.
    (RegExp(r'(https?://[^\s?"]+)\?[^\s"]+'), r'$1?‹…›'),
    // lat/lon: at least four decimals, so versions and seconds stay.
    (RegExp(r'-?\b\d{1,3}\.\d{4,}'), '‹Koord›'),
    // EVA numbers, customer, order and trip numbers.
    (RegExp(r'\b\d{6,}\b'), '‹Nr›'),
  ];

  static String _scrub(String line) {
    // Keep the timestamp; it is when the app ran, not where the user went.
    final cut = line.startsWith(RegExp(r'\d\d:\d\d:\d\d\.\d{3}  ')) ? 14 : 0;
    var rest = line.substring(cut);
    for (final (re, to) in _scrubbers) {
      rest = rest.replaceAllMapped(re, (m) {
        return to.replaceAllMapped(
          RegExp(r'\$(\d)'),
          (g) => m.group(int.parse(g.group(1)!)) ?? '',
        );
      });
    }
    return line.substring(0, cut) + rest;
  }
}
