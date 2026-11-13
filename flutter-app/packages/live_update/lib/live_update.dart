import 'package:flutter/services.dart';

/// One leg of the journey as one segment of the Live Update's progress bar.
class LiveUpdateSegment {
  /// Planned minutes — the segment's share of the whole bar.
  final int minutes;

  /// ARGB, as Android wants it.
  final int color;

  const LiveUpdateSegment({required this.minutes, required this.color});

  Map<String, Object> toMap() => {'minutes': minutes, 'color': color};
}

/// Mirror of `Notification.SEMANTIC_STYLE_*` (Android 17).
///
/// The system, not the app, picks the actual colour — amber for [caution], red
/// for [danger] — which is why this is a meaning and not an ARGB value. Ignored
/// below Android 17, and the text has to read correctly without it.
abstract final class LiveUpdateSemantic {
  static const int unspecified = 0;
  static const int info = 1;
  static const int safe = 2;
  static const int caution = 3;
  static const int danger = 4;
}

/// One of the (at most three) figures the Android 17 `MetricStyle` template
/// shows — on the always-on display too, which no other template does.
class LiveUpdateMetric {
  final String label;
  final String kind;
  final int number;
  final String? text;
  final String? unit;
  final int semantic;

  const LiveUpdateMetric._({
    required this.label,
    required this.kind,
    this.number = 0,
    this.text,
    this.unit,
    this.semantic = LiveUpdateSemantic.unspecified,
  });

  /// A number with an optional unit — "12 min" late, "3" stops to go.
  const LiveUpdateMetric.count({
    required String label,
    required int value,
    String? unit,
    int semantic = LiveUpdateSemantic.unspecified,
  }) : this._(
         label: label,
         kind: 'count',
         number: value,
         unit: unit,
         semantic: semantic,
       );

  /// Free text — a station name. Keep it short; the template gives each metric
  /// an equal third of the width regardless of content.
  const LiveUpdateMetric.text({
    required String label,
    required String value,
    int semantic = LiveUpdateSemantic.unspecified,
  }) : this._(label: label, kind: 'text', text: value, semantic: semantic);

  /// A wall-clock time, rendered by the system in the rider's own format.
  LiveUpdateMetric.clock({
    required String label,
    required DateTime value,
    int semantic = LiveUpdateSemantic.unspecified,
  }) : this._(
         label: label,
         kind: 'clock',
         number: value.hour * 60 + value.minute,
         semantic: semantic,
       );

  Map<String, Object?> toMap() => {
    'label': label,
    'kind': kind,
    'number': number,
    'text': text,
    'unit': unit,
    'semantic': semantic,
  };
}

/// Which template to build. [auto] takes the richest one the device has.
enum LiveUpdateStyle {
  auto,
  progress,
  metric;

  String get wire => name;
}

/// What the system did with the Live Update we posted.
class LiveUpdateResult {
  /// Whether it is really being promoted — the status-bar chip. False means
  /// "post the ordinary notification too", not "something broke".
  final bool promoted;

  /// The template that was actually built: `metric`, `progress`, or `none`
  /// where the platform channel was not there at all.
  final String style;

  const LiveUpdateResult({required this.promoted, required this.style});

  static const none = LiveUpdateResult(promoted: false, style: 'none');
}

/// Android 16 "Live Updates" — the running trip as a status-bar chip that stays
/// expanded on the lock screen, the treatment navigation apps get.
///
/// Everything here is best-effort and silent: on anything below Android 16 QPR1,
/// with the promotion switched off, or on an OEM that refuses it, [post] returns
/// [LiveUpdateResult.promoted] false and the caller keeps using ordinary
/// notifications. Nothing throws.
class LiveUpdate {
  LiveUpdate._();

  static const _channel = MethodChannel('dev.chuk.betterbahn/live_update');

  static void Function()? _onDismissed;
  static void Function(String tripKey)? _onTripTapped;
  static bool _listening = false;

  static void _listen() {
    if (_listening) return;
    _listening = true;
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onDismissed':
          _onDismissed?.call();
        case 'onTripTapped':
          final key = call.arguments;
          if (key is String && key.isNotEmpty) _onTripTapped?.call(key);
      }
      return null;
    });
  }

  /// Called when the rider swipes the Live Update away.
  ///
  /// Worth wiring: without it the next poll posts the thing straight back and
  /// the app is arguing with them once a minute.
  static set onDismissed(void Function()? callback) {
    _onDismissed = callback;
    _listen();
  }

  /// Called when the rider taps the Live Update while the app is running. The
  /// argument is the `tripKey` given to [post]. A tap that cold-starts the app
  /// is read with [takeLaunchTripKey] instead.
  static set onTripTapped(void Function(String tripKey)? callback) {
    _onTripTapped = callback;
    _listen();
  }

  /// The trip key the app was started with from a tap on the Live Update, or
  /// null. Returns it once.
  static Future<String?> takeLaunchTripKey() async {
    try {
      return await _channel.invokeMethod<String>('takeLaunchTripKey');
    } catch (_) {
      return null;
    }
  }

  /// Whether this device will really promote the notification.
  ///
  /// Not a version check: the APIs shipped in Android 16.0 but the system UI
  /// only arrived with 16 QPR1, and the rider can switch promotion off per app.
  static Future<bool> isSupported() async {
    try {
      return await _channel.invokeMethod<bool>('isSupported') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Whether the device has the Android 17 `MetricStyle` template.
  static Future<bool> hasMetricStyle() async {
    try {
      return await _channel.invokeMethod<bool>('hasMetricStyle') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Whether the Live Update we posted is being promoted right now — only
  /// knowable after posting, and what decides whether an ordinary notification
  /// is still needed.
  static Future<bool> isPromoted() async {
    try {
      return await _channel.invokeMethod<bool>('isPromoted') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Post or update the trip's Live Update.
  ///
  /// [progressMinutes] counts from the start of the journey, in the same units
  /// as the segments' lengths. [transferPoints] are the same scale — a marker on
  /// the bar at every change. [eta] drives the system's own countdown and is
  /// ignored when it is not far enough in the future: Android skips an update
  /// whose `when` has already passed.
  ///
  /// [metrics] are only rendered on Android 17, where they replace the progress
  /// bar with the `MetricStyle` template; below that they are ignored and the
  /// bar is what the rider sees. [criticalMetric] indexes the one the system may
  /// show on its own when there is no room for three.
  static Future<LiveUpdateResult> post({
    required String title,
    required String text,
    required List<LiveUpdateSegment> segments,
    required int progressMinutes,
    List<int> transferPoints = const [],
    String? chipText,
    String? subText,
    String? nowbarPrimary,
    String? nowbarSecondary,
    String? chipExpandedText,
    DateTime? eta,
    int transferColor = 0xFFF29D38,
    String smallIcon = 'ic_stat_besserbahn',
    List<LiveUpdateMetric> metrics = const [],
    int criticalMetric = -1,
    int titleSemantic = LiveUpdateSemantic.unspecified,
    LiveUpdateStyle style = LiveUpdateStyle.auto,
    String? tripKey,
  }) async {
    try {
      final result = await _channel.invokeMapMethod<String, Object?>('post', {
        'title': title,
        'text': text,
        'chipText': chipText,
        'subText': subText,
        'nowbarPrimary': nowbarPrimary,
        'nowbarSecondary': nowbarSecondary,
        'chipExpandedText': chipExpandedText,
        'segments': [for (final s in segments) s.toMap()],
        'points': transferPoints,
        'transferColor': transferColor,
        'progress': progressMinutes,
        'etaEpochMillis': eta?.millisecondsSinceEpoch,
        'smallIcon': smallIcon,
        'metrics': [for (final m in metrics) m.toMap()],
        'criticalMetric': criticalMetric,
        'titleSemantic': titleSemantic,
        'style': style.wire,
        'tripKey': tripKey,
      });
      if (result == null) return LiveUpdateResult.none;
      return LiveUpdateResult(
        promoted: result['promoted'] as bool? ?? false,
        style: result['style'] as String? ?? 'none',
      );
    } catch (_) {
      return LiveUpdateResult.none;
    }
  }

  static Future<void> cancel() async {
    try {
      await _channel.invokeMethod<void>('cancel');
    } catch (_) {
      /* nothing to cancel */
    }
  }
}
