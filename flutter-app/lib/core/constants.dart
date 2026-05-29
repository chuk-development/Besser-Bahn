class ApiConstants {
  ApiConstants._();

  /// Public HAFAS REST API (no auth needed, 100 req/min)
  static const hafasBaseUrl = 'https://v6.db.transport.rest';

  /// Deutsche Bahn internal web API (no auth needed)
  static const dbWebApiBaseUrl = 'https://www.bahn.de/web/api';

  /// DB international web API
  static const dbIntlApiBaseUrl = 'https://int.bahn.de/web/api';

  /// User-Agent mimicking a browser
  static const userAgent =
      'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Mobile Safari/537.36';

  /// Default results per query
  static const defaultResults = 6;

  /// Rate limit delay between sequential API calls (ms)
  static const defaultDelayMs = 400;
}

/// Träwelling (traewelling.de) — public-transit check-in & social network.
///
/// The app is registered as a **public OAuth2 client** (no client secret):
/// Authorization Code + PKCE. The `clientId` is therefore safe to ship.
///
/// The provider only accepts a secure https redirect, so it points at our own
/// `prediction-service` (`bahn.chuk.dev/oauth/callback`), which serves a tiny
/// page that bounces the response into the [callbackScheme] custom scheme that
/// `flutter_web_auth_2` captures.
class TraewellingConstants {
  TraewellingConstants._();

  static const baseUrl = 'https://traewelling.de';
  static const apiBaseUrl = '$baseUrl/api/v1';

  static const authorizeUrl = '$baseUrl/oauth/authorize';
  static const tokenUrl = '$baseUrl/oauth/token';

  /// Public OAuth client id (Settings → Your applications → "Besser Bahn").
  static const clientId = '336';

  /// Registered redirect — must match the OAuth app exactly.
  static const redirectUrl = 'https://bahn.chuk.dev/oauth/callback';

  /// Custom scheme the bounce page redirects into; captured natively.
  static const callbackScheme = 'besserbahn';

  /// Granted scopes. '*' = full access (matches Träwelling's default).
  static const scopes = '*';
}

class AppConstants {
  AppConstants._();

  static const appName = 'Bessere Bahn';
  static const appVersion = '2.0.0';

  /// Major German stations (EVA numbers) for train number lookup fallback
  static const majorStations = {
    'Berlin Hbf': '8011160',
    'Hamburg Hbf': '8002549',
    'München Hbf': '8000261',
    'Frankfurt(Main)Hbf': '8000105',
    'Köln Hbf': '8000207',
    'Stuttgart Hbf': '8000096',
    'Düsseldorf Hbf': '8000085',
    'Hannover Hbf': '8000152',
    'Mannheim Hbf': '8000244',
    'Nürnberg Hbf': '8000284',
  };
}
