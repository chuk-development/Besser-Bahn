import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';

import '../core/app_log.dart';
import '../router/app_router.dart';
import '../screens/auth/oauth_webview_screen.dart';

/// Raised when the user backs out of a login instead of completing it.
class OAuthCanceled implements Exception {
  const OAuthCanceled();
  @override
  String toString() => 'OAuthCanceled';
}

/// Opens OAuth and returns the provider's callback URL.
///
/// On Android the login runs in an in-app WebView. DB's registered redirects
/// (`dbnav://`, `bahnbonus://`) are also claimed by DB Navigator and the
/// BahnBonus app, so handing such a redirect to the system makes Android ask
/// the user which app should continue the login — mid-login, which reads as a
/// bug (#35). A WebView catches the redirect itself, so the system is never
/// asked. DB accepts no redirect we could own instead: its Keycloak rejects
/// foreign schemes and its edge WAF rejects the loopback redirect that Keycloak
/// would otherwise allow (asserted by `check_db_oauth_authorize_page`).
///
/// If the WebView cannot run, this falls back to the Custom Tab bridge, whose
/// callback still arrives via `OAuthCallbackActivity` — one app-chooser tap,
/// but a working login.
class OAuthBrowser {
  static const _androidChannel = MethodChannel('dev.chuk.betterbahn/oauth');

  /// Overridable so tests can drive the flow without a real WebView.
  @visibleForTesting
  static Future<String?> Function(
    String authUrl,
    String callbackUrlScheme,
    String title,
  )
  showWebView = _pushWebView;

  /// Puts [showWebView] back to the real implementation after a test.
  @visibleForTesting
  static void resetShowWebView() => showWebView = _pushWebView;

  /// Throws if the app has no navigator yet, which sends [authenticate] to the
  /// Custom Tab like any other WebView failure.
  static Future<String?> _pushWebView(
    String authUrl,
    String callbackUrlScheme,
    String title,
  ) {
    final context = rootNavigatorKey.currentContext;
    if (context == null) {
      throw StateError('no navigator to show the login on');
    }
    return Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => OAuthWebViewScreen(
          authUrl: authUrl,
          callbackUrlScheme: callbackUrlScheme,
          title: title,
        ),
      ),
    );
  }

  static Future<String> authenticate({
    required String url,
    required String callbackUrlScheme,
    String title = 'Anmeldung',
  }) async {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      try {
        final result = await showWebView(url, callbackUrlScheme, title);
        if (result == null) throw const OAuthCanceled();
        return result;
      } on OAuthCanceled {
        rethrow;
      } catch (e) {
        // A WebView that refuses to run (missing System WebView, no navigator
        // yet, a provider that blocks it) must not mean "no login at all".
        AppLog.log('webview login failed, using custom tab ($e)', tag: 'oauth');
      }
      return _authenticateInCustomTab(
        url: url,
        callbackUrlScheme: callbackUrlScheme,
      );
    }

    return FlutterWebAuth2.authenticate(
      url: url,
      callbackUrlScheme: callbackUrlScheme,
    );
  }

  static Future<String> _authenticateInCustomTab({
    required String url,
    required String callbackUrlScheme,
  }) async {
    final result = await _androidChannel.invokeMethod<String>('authenticate', {
      'url': url,
      'callbackUrlScheme': callbackUrlScheme,
    });
    if (result == null) {
      throw PlatformException(
        code: 'FAILED',
        message: 'Authentication returned no callback URL',
      );
    }
    return result;
  }
}
