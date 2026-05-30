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
    debugPrint(line);
    final next = [...messages.value, line];
    messages.value =
        next.length > _max ? next.sublist(next.length - _max) : next;
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
  /// image-load errors (FMTC `noConnectionDuringFetch` et al.) into a single
  /// counted [logCollapsed] line and swallows their multi-line stack dump, while
  /// passing every OTHER framework error through untouched. Call once in main().
  ///
  /// These dumps come straight from Flutter's image-resource error reporter (not
  /// our per-layer `errorTileCallback`), so the only place to catch them all is
  /// here. Without this a flaky/offline connection floods the console with the
  /// identical FMTCBrowsingError, drowning out everything useful.
  static bool _installed = false;
  static void installErrorCollapsing() {
    if (_installed) return;
    _installed = true;

    final prev = FlutterError.onError;
    FlutterError.onError = (details) {
      final ex = details.exceptionAsString();
      final isTile = details.library == 'image resource service' ||
          ex.contains('FMTCBrowsingError') ||
          ex.contains('Failed to load the tile');
      if (isTile) {
        logCollapsed(ex.split('\n').first.trim(), tag: 'tiles');
        return;
      }
      (prev ?? FlutterError.presentError)(details);
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
      if (message == last) {
        count++;
        if (count == 3 || count == 10 || count == 50 || count % 200 == 0) {
          original('  ⤷ (same line ×$count)', wrapWidth: wrapWidth);
        }
        return;
      }
      if (count > 1) {
        original('  ⤷ previous line repeated ×$count total',
            wrapWidth: wrapWidth);
      }
      last = message;
      count = 1;
      original(message, wrapWidth: wrapWidth);
    };
  }

  /// Run [action], logging how long it took (ms) with [label]. Logs failures
  /// with their elapsed time too, then rethrows — so the debug log shows
  /// exactly which network call is slow or hanging.
  static Future<T> timed<T>(String label, Future<T> Function() action,
      {String tag = ''}) async {
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
}
