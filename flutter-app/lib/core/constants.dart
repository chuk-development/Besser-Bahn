class ApiConstants {
  ApiConstants._();

  /// Public HAFAS REST API (no auth needed, 100 req/min)
  static const hafasBaseUrl = 'https://v6.db.transport.rest';

  /// Deutsche Bahn internal web API (no auth needed)
  static const dbWebApiBaseUrl = 'https://www.bahn.de/web/api';

  /// DB international web API
  static const dbIntlApiBaseUrl = 'https://int.bahn.de/web/api';

  /// User-Agent mimicking a browser.
  ///
  /// Deliberately *not* identifying: DB's Akamai edge blocks non-browser
  /// clients. For APIs that require the opposite — an honest, identifiable
  /// client — use [AppConstants.userAgent] instead (see #34).
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

/// Deutsche Bahn account login (the same OAuth the DB Navigator app uses).
///
/// Authorization Code + PKCE against DB's Keycloak realm `db`. The client
/// `kf_mobile` is the **public** DB Navigator mobile client — no secret, safe
/// to ship. The redirect is the app-scheme `dbnav://…/login/success` that the
/// real app registers; `flutter_web_auth_2` captures it via the `dbnav`
/// scheme (registered in AndroidManifest). `offline_access` yields a
/// long-lived (~180 day) refresh token; the access token lives only 5 min.
///
/// All personal data (profile, BahnCards, BahnBonus, booked tickets) is read
/// from the authenticated DB Navigator backend `app.services-bahn.de/mob`
/// with `Authorization: Bearer <access_token>`.
class DbAccountConstants {
  DbAccountConstants._();

  static const realmBase =
      'https://accounts.bahn.de/auth/realms/db/protocol/openid-connect';
  static const authorizeUrl = '$realmBase/auth';
  static const tokenUrl = '$realmBase/token';
  static const logoutUrl = '$realmBase/logout';

  /// Public DB Navigator mobile client id (not a secret).
  static const clientId = 'kf_mobile';

  /// App-scheme redirects the DB login bounces into (success / cancel).
  static const redirectUrl = 'dbnav://dbnavigator.bahn.de/login/success';
  static const cancelUrl = 'dbnav://dbnavigator.bahn.de/login/back';

  /// Custom scheme `flutter_web_auth_2` listens on (AndroidManifest).
  static const callbackScheme = 'dbnav';

  /// `offline_access` → refresh token; rest mirror the DB Navigator app.
  static const scope = 'offline_access';

  /// Mobile backend base (same as VendoService, but authenticated here).
  static const mobBase = 'https://app.services-bahn.de/mob';

  /// BahnBonus' personal CO₂ statistics. This is the same authenticated
  /// service the official BahnBonus app uses for its current-year balance.
  static const bahnbonusCo2Base =
      'https://apis.deutschebahn.com/db/apis/bahnbonus/co2-service/v1';

  /// OAuth client used by the official BahnBonus app. CO₂ deliberately does
  /// not accept DB Navigator's `kf_mobile` bearer, even for the same account.
  static const bahnbonusOAuthClientId = 'fe_bb_app';
  static const bahnbonusRedirectUrl = 'bahnbonus://authentication/redirect';
  static const bahnbonusCallbackScheme = 'bahnbonus';
  static const bahnbonusScope = 'openid offline_access self-impersonation';

  // Public app credentials shipped with the BahnBonus Android client. They
  // identify the calling app at DB's API gateway; the user's OAuth bearer is
  // still required separately and is what authorizes access to personal data.
  static const bahnbonusClientId = 'b4ceb052260d1df18955c9769f2f6ee1';
  static const bahnbonusApiKey = 'af42968e4445cf550ad06f8b114f0cda';

  // Per-endpoint vendo media types (exact-matched by the DB edge).
  static const profileMedia = 'application/x.db.vendo.mob.kundenkonto.v7+json';
  static const bahnbonusMedia = 'application/x.db.vendo.mob.bahnbonus.v1+json';
  static const bahncardsMedia =
      'application/x.db.vendo.mob.emobilebahncards.v2+json';
  static const reisenMedia =
      'application/x.db.vendo.mob.reisenuebersicht.v7+json';
  static const auftragMedia = 'application/x.db.vendo.mob.auftraege.v11+json';
  static const kciMedia = 'application/x.db.vendo.mob.kci.v3+json';

  /// Saved "Meine Reisen" tracked trips (`POST/GET/DELETE /mob/reisen`).
  static const freieReisenMedia =
      'application/x.db.vendo.mob.freiereisen.v5+json';

  /// Bahnhof-Favoriten (GET /mob/kundendatensatz/{id}/favoriten).
  static const favoritenMedia = 'application/x.db.vendo.mob.favoriten.v1+json';

  /// Customer contingents (abos like the Deutschland-Ticket) —
  /// GET /mob/kundenkontingente.
  static const kundenkontingenteMedia =
      'application/x.db.vendo.mob.kundenkontingente.v1+json';
}

class AppConstants {
  AppConstants._();

  static const appName = 'Bessere Bahn';

  /// App version, without the build number.
  ///
  /// Must match the `version:` line in `pubspec.yaml` — `test/app_version_test`
  /// fails the build when the two drift apart. That test is the reason this can
  /// stay a plain const instead of pulling in `package_info_plus`: it is baked
  /// in at compile time, needs no plugin channel (so it also works in tests and
  /// on desktop), yet cannot silently go stale. It had gone stale before — it
  /// read 2.0.0 while pubspec was already at 2.1.0 (#34).
  static const appVersion = '2.2.0-rc.2';

  /// Honest, identifying User-Agent for APIs that require one.
  ///
  /// Träwelling answers HTTP 403 "No identifiable User-Agent provided" to a
  /// missing UA *and* to generic library UAs (measured: `Dart/x (dart:io)`,
  /// `curl/x`, `python-requests/x` are all rejected). Their API guidelines ask
  /// for an app name + contact URL, so send exactly that rather than a browser
  /// UA that would merely sneak past the filter (#34).
  static const userAgent =
      'BesserBahn/$appVersion (+https://github.com/chuk-development/Besser-Bahn)';

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
