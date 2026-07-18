import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';

/// Opens OAuth and returns the provider's callback URL.
///
/// Android uses a classic Custom Tab so custom-scheme redirects also dismiss
/// the browser on Chrome < 141. Other platforms keep their native
/// flutter_web_auth_2 implementation.
class OAuthBrowser {
  static const _androidChannel = MethodChannel('dev.chuk.betterbahn/oauth');

  static Future<String> authenticate({
    required String url,
    required String callbackUrlScheme,
  }) async {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      final result = await _androidChannel.invokeMethod<String>(
        'authenticate',
        {'url': url, 'callbackUrlScheme': callbackUrlScheme},
      );
      if (result == null) {
        throw PlatformException(
          code: 'FAILED',
          message: 'Authentication returned no callback URL',
        );
      }
      return result;
    }

    return FlutterWebAuth2.authenticate(
      url: url,
      callbackUrlScheme: callbackUrlScheme,
    );
  }
}
