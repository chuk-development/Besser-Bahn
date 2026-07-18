import 'package:besser_bahn/services/oauth_browser.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dev.chuk.betterbahn/oauth');

  setUp(() {
    OAuthBrowser.showWebView = (_, _, _) async => null;
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    OAuthBrowser.resetShowWebView();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('Android runs the login in the in-app WebView', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    String? shownUrl;
    String? shownScheme;
    OAuthBrowser.showWebView = (url, scheme, _) async {
      shownUrl = url;
      shownScheme = scheme;
      return 'dbnav://dbnavigator.bahn.de/login/success?code=abc';
    };
    // The Custom Tab is the fallback and must stay untouched here — DB's
    // schemes are shared with DB Navigator, which is the whole point (#35).
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async {
          fail('the Custom Tab must not be used while the WebView works');
        });

    final result = await OAuthBrowser.authenticate(
      url: 'https://accounts.bahn.de/auth',
      callbackUrlScheme: 'dbnav',
    );

    expect(result, contains('code=abc'));
    expect(shownUrl, 'https://accounts.bahn.de/auth');
    expect(shownScheme, 'dbnav');
  });

  test('backing out of the WebView reports a cancellation', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    OAuthBrowser.showWebView = (_, _, _) async => null;

    expect(
      OAuthBrowser.authenticate(
        url: 'https://accounts.bahn.de/auth',
        callbackUrlScheme: 'dbnav',
      ),
      throwsA(isA<OAuthCanceled>()),
    );
  });

  test('a broken WebView falls back to the Custom Tab', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    OAuthBrowser.showWebView = (_, _, _) async =>
        throw PlatformException(code: 'NO_WEBVIEW');
    MethodCall? received;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          received = call;
          return 'besserbahn://login?code=xyz';
        });

    final result = await OAuthBrowser.authenticate(
      url: 'https://traewelling.de/oauth/authorize',
      callbackUrlScheme: 'besserbahn',
    );

    expect(result, contains('code=xyz'));
    expect(received?.method, 'authenticate');
  });

  test('the Custom Tab fallback rejects an empty result', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    OAuthBrowser.showWebView = (_, _, _) async =>
        throw PlatformException(code: 'NO_WEBVIEW');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => null);

    expect(
      OAuthBrowser.authenticate(
        url: 'https://example.com/auth',
        callbackUrlScheme: 'besserbahn',
      ),
      throwsA(isA<PlatformException>()),
    );
  });
}
