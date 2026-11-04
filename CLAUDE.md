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

`api-tests/healthcheck.py` probes every upstream endpoint the app depends on and
asserts the response still has the shape we parse.

- **At the start of every session that touches network/data code, run it first**
  (`cd api-tests && python3 healthcheck.py`). If a hard check fails, an upstream
  endpoint changed — investigate and switch/fix the endpoint *before* doing other
  work, don't build on a broken API.
- **Whenever you add or change networking** (a new endpoint, media type, request
  shape, or response parsing), **add or extend a check in `healthcheck.py`** to
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
- **`flutter test` flakes:** a few files fail with `Unable to connect to
  flutter_tester process: WebSocketException` on a full parallel run. That is
  the runner, not the test — rerun those files alone before you debug.
- **Träwelling symbol on each train in the connection view** (`_LegSection` →
  `TrainDetailView.headerAction`, tooltip „In Träwelling einchecken“). Commit
  `fcfeb9c` dropped it together with the redundant „Weitere Abfahrten“ button.
  Auto-check-in on save only runs when that setting is on. The symbol is the
  documented per-leg check-in (#108). Do not remove it when cleaning header
  buttons. The Zugnummer screen has its own copy in the search row.
