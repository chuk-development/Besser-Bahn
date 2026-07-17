import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:webview_flutter/webview_flutter.dart';

/// Live [WebViewController]s for the BahnCard's HTML views, kept for the
/// process lifetime.
///
/// Every `_BahnCardHtml` state used to build its own controller and feed it the
/// whole ~283 KB document again — so re-opening the Kontrollansicht, or any
/// rebuild that recreated the widget, paid for a fresh browser instance and a
/// fresh base64 parse of a payload that had not changed. Same idea as
/// `_tripCache` in the connection detail screen: the source is immutable for the
/// life of the card, so what we build from it can be too.
///
/// Bounded by construction — at most one entry per (view, card) and a real
/// account has one or two BahnCards. [clear] drops them on logout: a controller
/// holds the previous holder's rendered card and must not outlive the session.
class BahnCardWebViewCache {
  BahnCardWebViewCache._();

  static final Map<String, WebViewController> _cache = {};

  /// The controller for [key], built with [create] on first use.
  static WebViewController putIfAbsent(
          String key, WebViewController Function() create) =>
      _cache[key] ??= create();

  static void clear() => _cache.clear();

  /// How many controllers are alive — for tests.
  @visibleForTesting
  static int get length => _cache.length;
}
