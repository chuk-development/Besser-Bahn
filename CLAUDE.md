# Besser-Bahn

Premium Deutsche-Bahn companion app. Flutter app in `flutter-app/`, self-hosted
delay-prediction API in `prediction-service/`, API probes in `api-tests/`.

## Workflow — ALWAYS commit & push after changes

After every change that leaves the working tree in a good state (code compiles /
`flutter analyze` clean), **commit and push immediately**:

```
git add -A && git commit -m "<conventional message>" && git push
```

- Use Conventional Commits (`feat:`, `fix:`, `docs:`, `chore:`…).
- Don't wait to batch unrelated work — commit each logical change as it lands.
- **Never commit secrets**: Android signing keys / upload key
  (`android/*.jks`, `*.keystore`, `encrypted_upload_key.zip`,
  `upload_certificate.pem`, `pepk.jar`), `key.properties`. These are gitignored —
  keep them that way.

## Network / endpoints — health-check discipline

`api-tests/healthcheck/` (Dart, runs on `dart:io` — the app's own TLS stack)
probes every upstream endpoint the app depends on and asserts the response still
has the shape we parse. One file per group in `lib/checks/`, shared HTTP/pacing
in `lib/src/core.dart`. Daily GitHub Action: `.github/workflows/api-health.yml`
(opens an issue on failure). There is no Python in the repo any more.

- **At the start of every session that touches network/data code, run it first**
  (`cd api-tests/healthcheck && dart run bin/healthcheck.dart`, filter with
  `--only <text>` / `--group <file>`). If a hard check fails, an upstream
  endpoint changed — investigate and switch/fix the endpoint *before* doing other
  work, don't build on a broken API.
- **Whenever you add or change networking** (a new endpoint, media type, request
  shape, or response parsing), **add or extend a check in `api-tests/healthcheck/lib/checks/`** to
  cover it, and run the script to confirm it passes.
- Soft checks (`soft=True`) warn instead of fail — use for known-flaky sources
  (e.g. the public HAFAS mirror).

## Repo hygiene

Only Flutter app code, the prediction service, api-tests, and docs belong in the
repo. Do **not** commit dev artifacts: screenshots (`screenshot-*.png`), tool
caches (`.playwright-mcp/`), signing keys. They're gitignored — keep them out.

## Architecture notes

- Data layer prefers the **DB Vendo backend** (`app.services-bahn.de/mob`, the
  DB Navigator app's API) over the bahn.de website (Akamai-blocked) and the
  public HAFAS mirror (`v6.db.transport.rest`, unreliable/down).
- Route map geometry comes from `GET /mob/zuglauf/{id}` (`zuglauf.v2+json`) —
  the exact track polyline DB draws on its own map. Cached per physical route in
  `lib/core/polyline_cache.dart`.
- New app structure lives under `flutter-app/lib/screens/`,
  `providers/` (Riverpod), `router/` (GoRouter), `services/`.
- **DB orders carry no price.** `GET /mob/auftrag/.../kundenwunsch/...` has no
  price field (checked in the DB Navigator APK: `StandardInfosModel`,
  `ReiseInfosModel`, `KatalogInfosModel`). The only source is the printed
  ticket HTML → `DbTicket.priceFromTicketHtml` (best effort, null when the
  ticket prints none). Local saved trips only have the search price.
- **„Ticket hinzufügen“ ist nicht im Konto.** DB Navigator lädt ein fremdes
  Ticket mit `POST /mob/auftrag/{nr}/manuellLaden` (Body `{"nachname": …}`,
  ohne Login, Media `auftraege.v11`) und speichert es NUR auf dem Gerät
  (Tabelle `manuellGeladeneAuftragsinfos`). Darum taucht es weder in
  `reisenuebersicht` noch auf einem zweiten Gerät auf. Die Antwort enthält
  jedes Ticket komplett (`auftragsbezogeneReisen[]`, gleiche Form wie
  `GET …/kundenwunsch`). Der mitgelieferte `anonymerZugriff.accessToken`
  bringt bei `GET …/kundenwunsch` nur `403 TOKEN`; wir laden zum
  Aktualisieren einfach neu per Nachname (`ManualOrdersController`,
  Speicher: Secure Storage `db_manual_orders_v1`, bleibt nach Logout).
  Fehler stehen in `details.typ` (`AUFTRAG_NICHT_GEFUNDEN`,
  `AUFTRAG_LOGIN_REQUIRED`, …). Mit curl kommt `452 OPS_BLOCKED`
  (Akamai sperrt den TLS-Fingerabdruck), mit `dart:io` geht es.
- **Akamai prüft den TLS-Fingerabdruck, nicht die Header.** Seit 2026-11-13
  sperrt es auf `/mob` (bahnhofstafel, angebote/*) Chrome-artige Clients
  (`curl_cffi` chrome, curl) mit `452 OPS_BLOCKED`; `dart:io` kommt durch.
  Darum ist der Healthcheck in Dart. Probe-Requests von Hand: auch mit Dart
  machen, sonst sieht man eine Sperre, die die App nicht hat.
- **`dart:io` folgt bei POST keiner Weiterleitung.** BVG und NAH.SH sind
  2026-11 auf `*.hafas.cloud` umgezogen (307); die App blieb am 307 hängen,
  Python folgte und meldete grün. Neue Gates: `bvg.hafas.cloud/apps/gate`,
  `nahsh.hafas.cloud/gate`.
- **BahnBonus-Nummer** kommt im normalen Login mit: `bbStatus.loyaltyNumber`.
  Dafür ist kein zweiter BahnBonus-Login nötig (der gilt nur für CO₂).
- **Karten-Performance messen:** `flutter-app/tool/map_bench` (README dort).
  Emulator mit `-gpu host`, sonst SwiftShader und wertlose Raster-Zeiten. Die
  bahnhof.de-Etagenkarte darf unter Zoom 14 nie Kacheln laden (`_IndoorLayer`
  in `app_map.dart`); sonst lädt flutter_map z14-Kacheln für den ganzen
  Ausschnitt (ICE-Streckenkarte: 1,4 GB RAM, Absturz, App lahm nach Zurück).
- **Störungen unterwegs (2026-11-13):** Der Live-Tracker
  (`live_trip_provider.dart`) sucht bei „Halt entfällt“ oder verpasstem
  Anschluss selbst den Ersatz (`_offerReplacement`, `pickReplacement`) und
  pusht „Nimm RE2 21:04 Gl. 6 → an 21:24“. Fortschritt immer über
  `withLiveTimes()` (gespeicherte Zeiten sind veraltet). Fahrgastrechte-Regeln
  je Ticket in `core/disruption_rights.dart` (Quellen im Kopf der Datei),
  Karte `widgets/rights_now_card.dart`. Ersatzbus/„Zug beginnt hier“:
  `legHints()` in `connection_detail_screen.dart`.
- **`flutter test` flakes:** a few files fail with `Unable to connect to
  flutter_tester process: WebSocketException` on a full parallel run. That is
  the runner, not the test — rerun those files alone before you debug.
- **Träwelling symbol on each train in the connection view** (`_LegSection` →
  `TrainDetailView.headerAction`, tooltip „In Träwelling einchecken“). Commit
  `fcfeb9c` dropped it together with the redundant „Weitere Abfahrten“ button.
  Auto-check-in on save only runs when that setting is on. The symbol is the
  documented per-leg check-in (#108). Do not remove it when cleaning header
  buttons. The Zugnummer screen has its own copy in the search row.
