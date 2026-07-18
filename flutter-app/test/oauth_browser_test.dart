import 'package:besser_bahn/services/oauth_browser.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dev.chuk.betterbahn/oauth');

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'Android sends OAuth requests through the classic Custom Tab bridge',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      MethodCall? received;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            received = call;
            return 'dbnav://dbnavigator.bahn.de/login/success?code=abc';
          });

      final result = await OAuthBrowser.authenticate(
        url: 'https://accounts.bahn.de/auth',
        callbackUrlScheme: 'dbnav',
      );

      expect(result, contains('code=abc'));
      expect(received?.method, 'authenticate');
      expect(received?.arguments, {
        'url': 'https://accounts.bahn.de/auth',
        'callbackUrlScheme': 'dbnav',
      });
    },
  );

  test('Android rejects an empty native callback result', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
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
