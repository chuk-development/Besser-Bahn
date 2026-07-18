#!/usr/bin/env python3
"""
Besser-Bahn API health check.

Probes every upstream endpoint the app depends on and asserts the response
still has the shape we parse. Run it to find out *fast* when Deutsche Bahn
changes or removes an endpoint.

Two ways to run:
    python3 healthcheck.py            # human-readable table, exit 1 on failure
    pytest healthcheck.py             # CI / assertion mode

Zero hard deps beyond `requests`. `curl_cffi` is OPTIONAL: only the bahn.de
wagenreihung checks need it (Akamai TLS-fingerprints plain `requests` there and
403s it, while the app itself gets 200) — without it those checks SKIP.

Endpoint map (see app code in flutter-app/lib/services/):
  bahn.de GET endpoints      -> autocomplete, departures, train run. Not bot-gated.
  app.services-bahn.de /mob  -> DB Navigator backend: location + journey+PRICES (v9).
                                Replaces the Akamai-blocked website journey POST.
  bahnhof.de /{slug}/karte   -> indoor station map (RSC GeoJSON).
  v*.db.transport.rest       -> community HAFAS mirror, historically flaky.
  www.bahn.de angebote/fahrplan POST -> Akamai-blocked (OPS_BLOCKED) from non-browser;
                                we assert it STAYS blocked so a change is noticed.
"""
from __future__ import annotations

import collections
import json
import math
import re
import base64
import struct
import pathlib
import sys
import time
import urllib.parse
import uuid
from datetime import date, datetime, timedelta, timezone

import requests

TIMEOUT = 20
DBNAV_UA = "DBNavigator/Android/26.9.0"

# The /mob backend rate-limits per client, answering with 429 +
# {"domain":"MOB","code":"RETRY"} and a Retry-After (~18s). This script fires
# dozens of requests back to back, so it reliably trips that limit on itself:
# every check after roughly the eighth failed with 429 and the run reported
# "6 hard checks FAILED — an API likely changed" while nothing had changed.
# A health check that cries wolf is worse than none, so honour Retry-After and
# back off, exactly as the app now does (#14).
# Retrying alone is NOT enough: once tripped, the limit stays on for minutes
# (measured: ~4 min of solid 429s, while `Retry-After` claims 5s — the header
# lies about a sustained block). Firing ~10 requests in ~6s is enough to
# trigger it, so the fix is to not trip it: pace requests to the /mob host.
MOB_HOST = "app.services-bahn.de"
MOB_MIN_INTERVAL = 2.0  # seconds between consecutive /mob requests
MAX_RETRIES = 3
_last_mob_call = 0.0
_raw_get, _raw_post = requests.get, requests.post


def _pace(url: str) -> None:
    """Keep consecutive /mob requests MOB_MIN_INTERVAL apart. Other hosts
    (bahnhof.de, Overpass, …) are untouched."""
    global _last_mob_call
    if MOB_HOST not in str(url):
        return
    gap = time.monotonic() - _last_mob_call
    if gap < MOB_MIN_INTERVAL:
        time.sleep(MOB_MIN_INTERVAL - gap)
    _last_mob_call = time.monotonic()


def _with_retry(fn):
    def wrapped(url, *args, **kwargs):
        for attempt in range(MAX_RETRIES + 1):
            _pace(url)
            r = fn(url, *args, **kwargs)
            if r.status_code != 429 or attempt == MAX_RETRIES:
                return r
            # Retry-After is unreliable here (says 5s during a minutes-long
            # block), so back off geometrically and take whichever is longer.
            wait = max(int(r.headers.get("Retry-After") or 0), 15 * (attempt + 1))
            time.sleep(min(wait, 60))
        return r
    return wrapped


def _get(*args, **kwargs):
    return _with_retry(_raw_get)(*args, **kwargs)


def _post(*args, **kwargs):
    return _with_retry(_raw_post)(*args, **kwargs)

# Known stations used as fixtures.
KIEL = "8000199"
BERLIN_HBF = "8011160"
KOELN_HBF = "8000207"

# Vendo (DB Navigator) location ids — stable HAFAS strings.
KIEL_LOC = ("A=1@O=Kiel Hbf@X=10131976@Y=54314982@U=80@L=8000199@"
            "p=1779908603@i=U×008001304@")
BERLIN_LOC = ("A=1@O=Berlin Hbf@X=13369549@Y=52525589@U=80@L=8011160@"
              "p=1779908603@i=U×008065969@")
HAMBURG_LOC = ("A=1@O=Hamburg Hbf@X=10006909@Y=53552733@U=80@L=8002549@"
               "i=U×008001071@")
# An ICE trunk route that also carries a dense RE/RB service — the case where
# an ["ALL"] search returns nothing but ICEs (see check_vendo_verkehrsmittel).
MUNICH_LOC = "A=1@O=München Hbf@X=11558339@Y=48140229@U=80@L=8000261@"
AUGSBURG_LOC = "A=1@O=Augsburg Hbf@X=10885802@Y=48365456@U=80@L=8000013@"
# Berlin → Braunschweig: the ICE stops there and rides on to München. The split
# scope check (#22) needs a route whose train clearly outlives the journey.
BRAUNSCHWEIG_LOC = ("A=1@O=Braunschweig Hbf@X=10540293@Y=52252218@U=80@"
                    "L=8000049@i=U×008013240@")


def _corr_id() -> str:
    return f"{uuid.uuid4()}_{uuid.uuid4()}"


def _browser_headers() -> dict:
    return {
        "User-Agent": ("Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 "
                       "(KHTML, like Gecko) Chrome/125.0.0.0 Mobile Safari/537.36"),
        "Accept": "application/json",
        "Accept-Language": "de-DE,de;q=0.9",
    }


# Akamai in front of www.bahn.de fingerprints the TLS handshake, not the
# headers: `requests` gets a flat 403 OPS_BLOCKED on the wagenreihung endpoint
# no matter what User-Agent it sends, while the app's own dart:io client and any
# real browser get 200. So a `requests` 403 here is NOT evidence the endpoint
# died — checking it that way just cries wolf forever. curl_cffi replays a real
# Chrome fingerprint and sees what the app sees.
#
# Optional import on purpose: this file promises zero hard deps beyond
# `requests` (see module docstring). Without curl_cffi the wagenreihung checks
# skip instead of lying.
try:  # pragma: no cover - env dependent
    from curl_cffi import requests as _curl_cffi_requests
except ImportError:  # pragma: no cover
    _curl_cffi_requests = None


class _SkipCheck(Exception):
    """Check can't run here (missing optional dep) — reported, not failed."""


def _wagenreihung_get(params: dict):
    """GET the vehicle-sequence endpoint the way the APP reaches it."""
    if _curl_cffi_requests is None:
        raise _SkipCheck("curl_cffi not installed (pip install curl_cffi) — "
                         "plain requests is TLS-fingerprinted by Akamai")
    return _curl_cffi_requests.get(
        "https://www.bahn.de/web/api/reisebegleitung/wagenreihung/vehicle-sequence",
        params=params, impersonate="chrome124", timeout=TIMEOUT)


def _wagenreihung(category: str, number, eva: str, when: datetime):
    """The train's coach sequence at ONE stop, or None when unserved (404)."""
    r = _wagenreihung_get({
        "administrationId": "80", "category": category,
        "date": f"{when.year}-{when.month:02d}-{when.day:02d}",
        "evaNumber": eva, "number": str(number),
        "time": when.astimezone(timezone.utc).isoformat().replace("+00:00", "Z"),
    })
    if r.status_code == 404:
        return None
    r.raise_for_status()
    return r.json()


BAHNHOFSTAFEL_MEDIA = "application/x.db.vendo.mob.bahnhofstafeln.v2+json"
ZUGLAUF_MEDIA = "application/x.db.vendo.mob.zuglauf.v2+json"


def _vendo_board(eva: str, arrivals: bool = False) -> list:
    """POST /mob/bahnhofstafel/{abfahrt|ankunft} — the departure/arrival board
    that replaced the Akamai-blocked bahn.de `reiseloesung/abfahrten`. Returns
    the positions list (each carries a `zuglaufId` for the train run)."""
    now = datetime.now()
    body = {
        "anfrageZeit": now.strftime("%H:%M"),
        "datum": now.strftime("%Y-%m-%d"),
        "ursprungsBahnhofId": eva,
        "verkehrsmittel": ["ALL"],
    }
    path = "ankunft" if arrivals else "abfahrt"
    r = _post(
        f"https://app.services-bahn.de/mob/bahnhofstafel/{path}",
        headers=_vendo_headers(BAHNHOFSTAFEL_MEDIA),
        data=json.dumps(body), timeout=TIMEOUT,
    )
    r.raise_for_status()
    key = ("bahnhofstafelAnkunftPositionen" if arrivals
           else "bahnhofstafelAbfahrtPositionen")
    return r.json().get(key, [])


def _vendo_headers(media: str) -> dict:
    return {
        "Accept": media,
        "Content-Type": media,
        "Accept-Language": "de",
        "User-Agent": DBNAV_UA,
        "X-App-Version": "26.9.0",
        "X-Correlation-ID": _corr_id(),
    }


class CheckError(AssertionError):
    """Raised when an endpoint responds but the shape we rely on is gone."""


# --------------------------------------------------------------------------
# Individual checks. Each returns a short detail string on success or raises.
# --------------------------------------------------------------------------

def check_bahn_web_api_blocked() -> str:
    """The bahn.de website `reiseloesung/*` GET API (orte/abfahrten/ankuenfte/
    fahrt) is Akamai bot-blocked (OPS_BLOCKED) as of 2026-07-09 — the app moved
    off it onto the DB Vendo `/mob` backend. Assert it STAYS blocked so we
    notice (and could simplify) if DB ever reopens it. Soft: a transient 200
    shouldn't fail CI."""
    now = datetime.now()
    r = _get(
        "https://www.bahn.de/web/api/reiseloesung/abfahrten",
        params={"datum": now.strftime("%Y-%m-%d"),
                "zeit": now.strftime("%H:%M:00"),
                "ortExtId": KOELN_HBF, "mitVias": "false"},
        headers=_browser_headers(), timeout=TIMEOUT,
    )
    if r.status_code == 403 or "OPS_BLOCKED" in r.text:
        return "reiseloesung still Akamai-blocked (expected) — app uses vendo"
    raise CheckError(
        f"reiseloesung/abfahrten returned {r.status_code} (no longer blocked?) "
        "— the bahn.de web API may be usable again")


def check_vendo_departures() -> str:
    """POST /mob/bahnhofstafel/abfahrt — the departure board (replaces the
    blocked bahn.de abfahrten). Powers the Abfahrtstafel + train-by-number."""
    pos = _vendo_board(KOELN_HBF, arrivals=False)
    if not pos:
        raise CheckError("no departure positions")
    e = pos[0]
    for key in ("zuglaufId", "abgangsDatum"):
        if key not in e:
            raise CheckError(f"departure position missing '{key}'")
    if not e.get("mitteltext") and not e.get("kurztext"):
        raise CheckError("departure position has no line text")
    return (f"{len(pos)} departures, first '{e.get('mitteltext', '?')}' → "
            f"{e.get('richtung', '?')}, zuglaufId len={len(e['zuglaufId'])}")


def check_vendo_board_semantics() -> str:
    """The two board fields the app derives meaning from, rather than shows.

    `produktGattung` decides the IC/EC filter and the drawn train geometry —
    live it reads `IC_EC` (the app long had only the never-sent `EC_IC`, so
    every IC was categorised as regional). And a cancelled row is signalled
    *only* by the realtime note "Halt entfällt"; the board carries no flag, so
    the app matches on text. Both are DB's to change, hence a check.

    Soft on the cancellation note: a board with nothing cancelled is a good
    day, not a broken API.
    """
    gattungen = collections.Counter()
    notes = collections.Counter()
    for eva in (KOELN_HBF, "8011160"):  # Köln, Berlin Hbf
        for p in _vendo_board(eva, arrivals=False):
            g = p.get("produktGattung")
            if g:
                gattungen[g] += 1
            for n in p.get("echtzeitNotizen") or []:
                if isinstance(n, dict) and n.get("text"):
                    notes[n["text"]] += 1

    if not gattungen:
        raise CheckError("no produktGattung on any board row")
    # The app maps these explicitly; anything else silently becomes 'regional'.
    known = {"ICE", "IC_EC", "IR", "RB", "RE", "REGIONAL", "SBAHN", "S",
             "BUS", "SONSTIGE", "UBAHN", "U", "STR", "TRAM", "SCHIFF",
             "IC", "EC", "EC_IC"}
    unknown = {g: c for g, c in gattungen.items() if g not in known}
    if unknown:
        raise CheckError(
            f"unmapped produktGattung {unknown} — _mapProduct would call these "
            "'regional'; add them to the switch")

    cancels = sum(c for t, c in notes.items()
                  if "entfällt" in t.lower() or "fällt aus" in t.lower())
    return (f"{sum(gattungen.values())} rows, gattungen "
            f"{dict(gattungen.most_common(4))}, {cancels} cancelled notes")


def check_vendo_arrivals() -> str:
    """POST /mob/bahnhofstafel/ankunft — the arrival board. Each position adds
    `abgangsOrt` (origin) which the board renders as "von …"."""
    pos = _vendo_board(KOELN_HBF, arrivals=True)
    if not pos:
        raise CheckError("no arrival positions")
    e = pos[0]
    if "ankunftsDatum" not in e or "zuglaufId" not in e:
        raise CheckError("arrival position missing ankunftsDatum/zuglaufId")
    origin = (e.get("abgangsOrt") or {}).get("name", "?")
    return f"{len(pos)} arrivals, first from '{origin}'"


def check_vendo_zuglauf_detail() -> str:
    """GET /mob/zuglauf/{zuglaufId} — the train run that powers the Zugverlauf.
    Replaces the blocked bahn.de `fahrt`. One response carries the stop list
    (halte: ort+coords, ankunft/abgang times, gleis), per-stop `auslastungsInfos`
    (2nd-class load), train-wide `attributNotizen` (bike/accessibility/amenities)
    AND `polylineGroup` (map geometry). Asserts the halte shape; occupancy and
    attributes are best-effort (a stray tram carries neither)."""
    pos = _vendo_board(KOELN_HBF, arrivals=False)
    if not pos:
        raise CheckError("no departures to derive a zuglaufId")
    # Prefer long-distance — likeliest to carry occupancy + amenities.
    zid = next((p["zuglaufId"] for p in pos
                if p.get("produktGattung") in ("ICE", "IC", "EC")),
               pos[0]["zuglaufId"])
    r = _get(
        f"https://app.services-bahn.de/mob/zuglauf/{urllib.parse.quote(zid, safe='')}",
        headers=_vendo_headers(ZUGLAUF_MEDIA), timeout=TIMEOUT,
    )
    r.raise_for_status()
    data = r.json()
    halte = data.get("halte") or []
    if not halte:
        raise CheckError("zuglauf has no halte")
    h0 = halte[0]
    if "ort" not in h0 or "evaNr" not in (h0.get("ort") or {}):
        raise CheckError("zuglauf halt missing ort/evaNr")
    if not any(h.get("abgangsDatum") or h.get("ankunftsDatum") for h in halte):
        raise CheckError("zuglauf halte carry no times")
    # Best-effort shape guards (the app reads these but tolerates absence).
    occ = any(isinstance(h.get("auslastungsInfos"), list) and h["auslastungsInfos"]
              for h in halte)
    attrs = data.get("attributNotizen") or []
    if attrs and not isinstance(attrs, list):
        raise CheckError("attributNotizen is not a list")
    poly = (data.get("polylineGroup") or {}).get("polylineDesc") or []
    extras = []
    if occ:
        extras.append("auslastung✓")
    if attrs:
        extras.append(f"{len(attrs)} attrs")
    if poly:
        extras.append("polyline✓")
    return (f"{len(halte)} stops, {data.get('mitteltext', '?')}"
            + (f" ({', '.join(extras)})" if extras else ""))


def check_vendo_zuglauf_notes() -> str:
    """Diversion signals on the train run (#17). The app reads three things the
    zuglauf parser used to ignore: root `himNotizen` (Bauarbeiten/Streckensperrung),
    root+halt `echtzeitNotizen` ("Umleitung", "Zusatzhalt" — text only, NO `typ`
    key, so matching is on text), and `istZusatzhalt` per halt.

    Asserts the fields still exist and keep their types. Whether any train is
    actually diverted right now is up to the day, so presence of a real
    Umleitung is reported, not required."""
    pos = _vendo_board(KOELN_HBF, arrivals=False)
    if not pos:
        raise CheckError("no departures to derive a zuglaufId")
    zid = next((p["zuglaufId"] for p in pos
                if p.get("produktGattung") in ("ICE", "IC", "EC")),
               pos[0]["zuglaufId"])
    r = _get(
        f"https://app.services-bahn.de/mob/zuglauf/{urllib.parse.quote(zid, safe='')}",
        headers=_vendo_headers(ZUGLAUF_MEDIA), timeout=TIMEOUT,
    )
    r.raise_for_status()
    data = r.json()
    halte = data.get("halte") or []
    if not halte:
        raise CheckError("zuglauf has no halte")

    for key in ("himNotizen", "echtzeitNotizen"):
        if key in data and not isinstance(data[key], list):
            raise CheckError(f"root '{key}' is not a list")
    # istZusatzhalt is sent on every halt; the app defaults it to False, but if
    # it vanished entirely we'd silently stop detecting added stops.
    if not any("istZusatzhalt" in h for h in halte):
        raise CheckError("no halt carries 'istZusatzhalt' — added stops "
                         "can no longer be detected")
    for h in halte:
        if not isinstance(h.get("istZusatzhalt", False), bool):
            raise CheckError("istZusatzhalt is not a bool")

    notes = [n.get("text", "") for n in (data.get("himNotizen") or [])
             + (data.get("echtzeitNotizen") or []) if isinstance(n, dict)]
    for h in halte:
        notes += [n.get("text", "") for n in (h.get("echtzeitNotizen") or [])
                  if isinstance(n, dict)]
    zusatz = sum(1 for h in halte if h.get("istZusatzhalt"))
    detail = f"{len(halte)} stops, {len(notes)} notes, {zusatz} Zusatzhalt"
    if any("umleitung" in n.lower() or "umgeleitet" in n.lower() for n in notes):
        detail += " (live Umleitung!)"
    return detail


def check_vendo_platform_change() -> str:
    """Gleiswechsel: vendo sends the timetabled platform as `gleis` and the
    realtime one as `ezGleis` — the latter ONLY when it differs. The app parses
    both apart (planned vs actual) so a platform change is detectable; parsing
    both from `gleis` silently swallowed every Gleiswechsel (#16).

    Soft: whether any train is rerouted to another platform right now is up to
    the day. Absence of `ezGleis` across a whole board is normal-ish; the point
    is to notice if the FIELD NAME disappears while changes still happen."""
    pos = _vendo_board(KOELN_HBF, arrivals=False)
    if not pos:
        raise CheckError("no departures to inspect for platform changes")
    if not any("gleis" in p for p in pos):
        raise CheckError("no departure carries 'gleis' — planned platform gone")
    changed = [p for p in pos
               if p.get("ezGleis") and p.get("ezGleis") != p.get("gleis")]
    if not changed:
        return (f"{len(pos)} departures, no live Gleiswechsel right now "
                "(field intact, nothing to compare)")
    e = changed[0]
    return (f"{len(changed)}/{len(pos)} with Gleiswechsel, e.g. "
            f"'{e.get('mitteltext', '?')}' {e.get('gleis')} → {e['ezGleis']}")


def check_vendo_location() -> str:
    media = "application/x.db.vendo.mob.location.v3+json"
    r = _post(
        "https://app.services-bahn.de/mob/location/search",
        headers=_vendo_headers(media),
        data=json.dumps({"locationTypes": ["ALL"], "searchTerm": "Köln Hbf"}),
        timeout=TIMEOUT,
    )
    r.raise_for_status()
    data = r.json()
    if not isinstance(data, list) or not data:
        raise CheckError("expected non-empty list")
    first = data[0]
    for key in ("locationId", "evaNr", "coordinates"):
        if key not in first:
            raise CheckError(f"missing field '{key}'")
    return f"{len(data)} hits, top='{first['name']}' eva={first['evaNr']}"


# Every concrete (non-templated) DB Navigator `/mob` endpoint, extracted from
# the app APK with `apkurl` (see the apk-url-extractor tool). This is the full
# backend surface the official app talks to — most we don't use yet, but probing
# them catches the moment DB removes/renames one (which is how the whole
# reiseloesung API vanished). Regenerate on a DB Navigator update:
#   apkurl <dbnav.xapk> ; jq -r '.apiPaths[]|select(startswith("mob/") and (contains("{")|not))' snapshots/de.hafas.android.db-*.json
MOB_SURFACE = [
    "mob/aboVertragsstatusAnonym", "mob/aboverkauf/bestellanfrage",
    "mob/adressvalidierung", "mob/amp/discovery/v1/nearby",
    "mob/amp/discovery/v1/stations", "mob/amp/discovery/v1/stations/location",
    "mob/amp/discovery/v1/vehicles", "mob/amp/discovery/v1/vehicles/location",
    "mob/amp/discovery/v1/vehicles/lookup", "mob/amp/login/v1/auth",
    "mob/amp/login/v1/token", "mob/amp/navigation/v1/estimations/multimodal",
    "mob/amp/pay-discounts/v1/vouchers", "mob/amp/sharing-booking/v1/bookings",
    "mob/amp/sharing-booking/v1/bookings/latest", "mob/angebote/fahrplan",
    "mob/angebote/recon", "mob/angebote/recon/autonomereservierung",
    "mob/angebote/tagesbestpreis", "mob/angebote/umtausch",
    "mob/angebote/upgrade", "mob/angebote/verbindung/teilen",
    "mob/appversion/check", "mob/auftrag/materialisieren/erstmaterialisierung",
    "mob/auftrag/materialisieren/folgematerialisierung", "mob/auftrag/token",
    "mob/auftrag/upgradeAngebot", "mob/bahnhofstafel/abfahrt",
    "mob/bahnhofstafel/ankunft", "mob/buchungen", "mob/buchungen/abbrechen",
    "mob/buchungen/abschliessen", "mob/buchungen/abschliessen/anonym",
    "mob/buchungen/anonym", "mob/buchungen/storno", "mob/buchungen/umtausch",
    "mob/datalake", "mob/devicetoken", "mob/devicetoken/delete",
    "mob/emobilebahncards", "mob/errorreport", "mob/gsd/gsd_v3",
    "mob/katalog/angebot", "mob/katalog/verbundshop/angebot",
    "mob/kci/reservierungen", "mob/kcidurchfuehren", "mob/konfiguration",
    "mob/kundenkonten/nutzungsbedingungen/akzeptieren",
    "mob/kundenkonten/nutzungsbedingungen/status", "mob/kundenkontingente",
    "mob/location/calculateroute", "mob/location/nearby/bytypes",
    "mob/location/search", "mob/mehrfahrtenkarten", "mob/reisen",
    "mob/reisenuebersicht", "mob/stammdaten", "mob/streckenfavoriten",
    "mob/trip/recon", "mob/trip/weitereabfahrten", "mob/warenkorb",
    "mob/warenkorb/stornooption", "mob/zahlungsart/lastschrift/mandatstext",
    "mob/zahlungsmittel", "mob/zahlungsmittel/bankdetails",
    "mob/zahlungsmittel/legacy", "mob/zuglaeufe/halte/by-abfahrt/wagenreihung",
]


def check_mob_surface() -> str:
    """Reachability sweep over the ENTIRE DB Navigator /mob surface (see
    MOB_SURFACE). POST an empty body to each and flag only the ones that are
    *gone* — 404 (removed/renamed) or OPS_BLOCKED (Akamai). Auth-gated (401),
    wrong-media (415), bad-body (400), wrong-method (405) all count as reachable:
    the endpoint still exists. Soft — a transient blip shouldn't fail CI, but a
    real removal shows up here first. This is the early-warning net that would
    have flagged the reiseloesung shutdown."""
    from concurrent.futures import ThreadPoolExecutor
    media = "application/x.db.vendo.mob.location.v3+json"

    def probe(path: str):
        url = f"https://app.services-bahn.de/{path}"
        # POST first; if the path 404s (some are GET-only → the router 404s an
        # unmatched method+path), re-probe with GET before calling it gone.
        try:
            for method in ("POST", "GET"):
                r = requests.request(method, url, headers=_vendo_headers(media),
                                     data="{}" if method == "POST" else None,
                                     timeout=15)
                if r.status_code == 403 or "OPS_BLOCKED" in r.text:
                    return path, "BLOCKED"
                if r.status_code != 404:
                    return path, "ok"   # reachable (401/400/405/415/200/500…)
            return path, "404"          # both methods 404 → really gone
        except Exception as e:
            return path, f"ERR:{type(e).__name__}"

    gone = []
    with ThreadPoolExecutor(max_workers=8) as ex:
        for path, status in ex.map(probe, MOB_SURFACE):
            if status != "ok":
                gone.append(f"{path}→{status}")
    if gone:
        raise CheckError(f"{len(gone)}/{len(MOB_SURFACE)} mob endpoints NOT "
                         f"reachable: {gone}")
    return f"all {len(MOB_SURFACE)} mob endpoints reachable"


def check_vendo_nearby() -> str:
    """POST /mob/location/nearby/bytypes — stations near a coordinate. The
    coords go inside `area`, and `types`/`operatingSystem` are required (that
    shape is why the older /mob/location/nearby guesses all 400'd). Response:
    {fahrplanAuskunftLocations: [...]}."""
    media = "application/x.db.vendo.mob.location.v3+json"
    body = {
        "area": {"coordinates": {"latitude": 50.9427, "longitude": 6.9586},
                 "radius": 2000},
        "maxResults": 5, "operatingSystem": "ANDROID",
        "products": ["ALL"], "types": ["ST"],
    }
    r = _post(
        "https://app.services-bahn.de/mob/location/nearby/bytypes",
        headers=_vendo_headers(media), data=json.dumps(body), timeout=TIMEOUT,
    )
    r.raise_for_status()
    locs = r.json().get("fahrplanAuskunftLocations", [])
    if not locs:
        raise CheckError("no nearby locations")
    first = locs[0]
    for key in ("evaNr", "name", "coordinates"):
        if key not in first:
            raise CheckError(f"nearby location missing '{key}'")
    return f"{len(locs)} nearby, closest '{first['name']}' ({first.get('distance')}m)"


def check_vendo_journey() -> str:
    """The important one: journeys WITH prices, replaces website fahrplan."""
    media = "application/x.db.vendo.mob.verbindungssuche.v9+json"
    body = {
        "autonomeReservierung": False,
        "einstiegsTypList": ["STANDARD"],
        "fahrverguenstigungen": {
            "deutschlandTicketVorhanden": False,
            "nurDeutschlandTicketVerbindungen": False,
        },
        "klasse": "KLASSE_2",
        "reiseHin": {"wunsch": {
            "abgangsLocationId": KIEL_LOC,
            "alternativeHalteBerechnung": True,
            "verkehrsmittel": ["ALL"],
            "zeitWunsch": {
                "reiseDatum": datetime.now().astimezone().isoformat(),
                "zeitPunktArt": "ABFAHRT",
            },
            "zielLocationId": BERLIN_LOC,
        }},
        "reisendenProfil": {"reisende": [{
            "ermaessigungen": ["KEINE_ERMAESSIGUNG KLASSENLOS"],
            "reisendenTyp": "ERWACHSENER",
        }]},
        "reservierungsKontingenteVorhanden": False,
    }
    r = _post(
        "https://app.services-bahn.de/mob/angebote/fahrplan",
        headers=_vendo_headers(media), data=json.dumps(body), timeout=TIMEOUT,
    )
    r.raise_for_status()
    conns = r.json().get("verbindungen", [])
    if not conns:
        raise CheckError("no verbindungen returned")
    c = conns[0]
    legs = c["verbindung"]["verbindungsAbschnitte"]
    if not legs:
        raise CheckError("verbindung has no verbindungsAbschnitte")
    # price is best-effort (some legs are price-less), so only soft-check.
    price = (c.get("angebote", {}).get("preise", {})
             .get("gesamt", {}).get("ab", {}).get("betrag"))
    price_txt = f", ab {price} EUR" if price is not None else ", no price"
    # Disruption-note containers the app reads (himNotizen / echtzeitNotizen,
    # at leg and stop level) must still be lists when present — the leg
    # disruption banner parses {text: ...} out of them.
    # Cancellation: a dropped stop carries `ersatzhaltNotiz` whose `typ` is
    # GECANCELT ("Halt entfällt") — vendo_service reads exactly that path to
    # flag JourneyLeg/LegStopover.cancelled, so guard its shape if present.
    ersatz_seen = False
    for leg in legs:
        for fld in ("himNotizen", "echtzeitNotizen"):
            if fld in leg and not isinstance(leg[fld], list):
                raise CheckError(f"leg {fld} is not a list")
        for h in leg.get("halte", []):
            if "himNotizen" in h and not isinstance(h["himNotizen"], list):
                raise CheckError("halt himNotizen is not a list")
            ez = h.get("ersatzhaltNotiz")
            if ez is not None:
                ersatz_seen = True
                if not isinstance(ez, dict) or "typ" not in ez:
                    raise CheckError("ersatzhaltNotiz lacks a 'typ' field")
    ez_txt = ", ersatzhaltNotiz shape ok" if ersatz_seen else ""
    return f"{len(conns)} journeys, first has {len(legs)} legs{price_txt}{ez_txt}"


def check_vendo_split_scope() -> str:
    """Split-ticket scope (#22): a leg's `halte` must be exactly the stretch the
    rider travels, while /mob/zuglauf answers with the WHOLE train run.

    The split candidates are built from the leg (utils/split_stops.dart), and
    the connection-detail screen may hand over its cached run — which is then
    cut down to the leg via the boarding/alighting `evaNr`. Two things have to
    hold for that, and both are asserted here on Berlin Hbf → Braunschweig Hbf,
    where the ICE carries on to München long after the rider gets off:

      * the leg's halte stop AT the destination (they did not, in #22's
        screenshot: it offered Berlin → Hildesheim on a Braunschweig trip),
      * the leg's halte are a contiguous slice of the run's halte, keyed on
        evaNr — otherwise the trim can't find the leg in the run and the app
        silently falls back to the leg's own stops.
    """
    media = "application/x.db.vendo.mob.verbindungssuche.v9+json"
    when = (datetime.now().astimezone() + timedelta(days=1)).replace(
        hour=9, minute=0, second=0, microsecond=0)
    body = {
        "autonomeReservierung": False,
        "einstiegsTypList": ["STANDARD"],
        "fahrverguenstigungen": {"deutschlandTicketVorhanden": False,
                                 "nurDeutschlandTicketVerbindungen": False},
        "klasse": "KLASSE_2",
        "reiseHin": {"wunsch": {
            "abgangsLocationId": BERLIN_LOC,
            "alternativeHalteBerechnung": True,
            "verkehrsmittel": ["HOCHGESCHWINDIGKEITSZUEGE"],
            "zeitWunsch": {"reiseDatum": when.isoformat(),
                           "zeitPunktArt": "ABFAHRT"},
            "zielLocationId": BRAUNSCHWEIG_LOC,
        }},
        "reisendenProfil": {"reisende": [
            {"ermaessigungen": ["KEINE_ERMAESSIGUNG KLASSENLOS"],
             "reisendenTyp": "ERWACHSENER"}]},
        "reservierungsKontingenteVorhanden": False,
    }
    r = _post("https://app.services-bahn.de/mob/angebote/fahrplan",
              headers=_vendo_headers(media), data=json.dumps(body),
              timeout=TIMEOUT)
    r.raise_for_status()
    conns = r.json().get("verbindungen", [])
    if not conns:
        raise CheckError("no Berlin → Braunschweig connections")

    # First direct ICE leg that carries a run id — that's the #22 case.
    for c in conns:
        legs = c["verbindung"]["verbindungsAbschnitte"]
        if len(legs) != 1:
            continue
        leg = legs[0]
        zid = leg.get("zuglaufId") or leg.get("risZuglaufId")
        if zid:
            break
    else:
        raise CheckError("no direct ICE leg with a zuglaufId")

    leg_ids = [h["ort"]["evaNr"] for h in leg["halte"]]
    if leg_ids[-1] != "8000049":
        raise CheckError(
            f"leg halte end at {leg['halte'][-1]['ort']['name']}, not the "
            "searched destination Braunschweig Hbf — the leg is NOT leg-scoped")

    r = _get(
        f"https://app.services-bahn.de/mob/zuglauf/{urllib.parse.quote(zid, safe='')}",
        headers=_vendo_headers(ZUGLAUF_MEDIA), timeout=TIMEOUT)
    r.raise_for_status()
    run_ids = [h["ort"]["evaNr"] for h in r.json().get("halte") or []]
    if not run_ids:
        raise CheckError("zuglauf has no halte")
    if leg_ids[0] not in run_ids or leg_ids[-1] not in run_ids:
        raise CheckError("leg boarding/alighting evaNr absent from its own "
                         "zuglauf — the trim to the ridden section can't key "
                         "on evaNr any more")
    board = run_ids.index(leg_ids[0])
    alight = run_ids.index(leg_ids[-1], board)
    if run_ids[board:alight + 1] != leg_ids:
        raise CheckError(f"leg halte are not a contiguous slice of the run: "
                         f"leg={leg_ids} vs run[{board}:{alight + 1}]="
                         f"{run_ids[board:alight + 1]}")
    past = len(run_ids) - 1 - alight
    return (f"{leg.get('mitteltext')}: leg {len(leg_ids)} halte == run"
            f"[{board}:{alight + 1}], run has {len(run_ids)} ({past} past the "
            "rider's destination)")


def check_vendo_earlier_alight() -> str:
    """Rescue option B (#26): get off earlier and go another way.

    The feature rests on two properties of the journey search, and both fail
    silently rather than loudly if DB changes them — the app would just stop
    offering rescues, or worse, offer ones timed off the timetable while the
    train is an hour down.

      * a leg's intermediate `halte` carry their own arrival, with the realtime
        one in `ezAnkunftsZeitpunkt`/`ezAnkunftsDatum` where it exists. The app
        picks candidate exits by LIVE arrival (utils/earlier_alight.dart —
        `AlightStop.arrival`); a plan-only halt list makes that impossible.
      * an intermediate halt's `ort` is usable as a search origin: the whole
        fan-out is one search per earlier stop, keyed on the halt's own
        locationId/evaNr. If those stop round-tripping, every candidate search
        returns nothing and option B quietly disappears.

    Kiel → Berlin, whose ICE/IC legs have plenty of intermediate stops.
    """
    media = "application/x.db.vendo.mob.verbindungssuche.v9+json"
    when = (datetime.now().astimezone() + timedelta(days=1)).replace(
        hour=9, minute=0, second=0, microsecond=0)

    def search(from_loc: str, to_loc: str, at) -> list:
        body = {
            "autonomeReservierung": False,
            "einstiegsTypList": ["STANDARD"],
            "fahrverguenstigungen": {"deutschlandTicketVorhanden": False,
                                     "nurDeutschlandTicketVerbindungen": False},
            "klasse": "KLASSE_2",
            "reiseHin": {"wunsch": {
                "abgangsLocationId": from_loc,
                "alternativeHalteBerechnung": True,
                "verkehrsmittel": ["ALL"],
                "zeitWunsch": {"reiseDatum": at.isoformat(),
                               "zeitPunktArt": "ABFAHRT"},
                "zielLocationId": to_loc,
            }},
            "reisendenProfil": {"reisende": [
                {"ermaessigungen": ["KEINE_ERMAESSIGUNG KLASSENLOS"],
                 "reisendenTyp": "ERWACHSENER"}]},
            "reservierungsKontingenteVorhanden": False,
        }
        r = _post("https://app.services-bahn.de/mob/angebote/fahrplan",
                  headers=_vendo_headers(media), data=json.dumps(body),
                  timeout=TIMEOUT)
        r.raise_for_status()
        return r.json().get("verbindungen", [])

    conns = search(KIEL_LOC, BERLIN_LOC, when)
    if not conns:
        raise CheckError("no Kiel → Berlin connections")

    # A train leg with intermediate stops = one you could get off early from.
    for c in conns:
        for leg in c["verbindung"]["verbindungsAbschnitte"]:
            if leg.get("typ") == "FUSSWEG":
                continue
            if len(leg.get("halte") or []) >= 3:
                break
        else:
            continue
        break
    else:
        raise CheckError("no train leg with intermediate halte — the app has "
                         "no earlier stop to offer as an exit")

    halte = leg["halte"]
    # Intermediate stops only: the first has no arrival (you board there) and
    # the last is the planned change, which is never an "earlier" exit.
    inner = halte[1:-1]
    timed = [h for h in inner
             if h.get("ankunftsZeitpunkt") or h.get("ankunftsDatum")]
    if not timed:
        raise CheckError(
            "no intermediate halt carries an arrival time — picking an exit by "
            "live arrival is impossible")
    ez = sum(1 for h in inner
             if h.get("ezAnkunftsZeitpunkt") or h.get("ezAnkunftsDatum"))

    # The exit must be usable as the origin of the next search.
    exit_halt = timed[-1]
    ort = exit_halt.get("ort") or {}
    loc_id = ort.get("locationId")
    if not loc_id:
        raise CheckError(f"halt {ort.get('name')} has no locationId — it can't "
                         "be searched from")
    onward = search(loc_id, BERLIN_LOC,
                    datetime.now().astimezone() + timedelta(days=1, hours=11))
    if not onward:
        raise CheckError(f"no onward connections from the intermediate halt "
                         f"{ort.get('name')} — option B would find nothing")

    return (f"{leg.get('mitteltext')}: {len(inner)} intermediate halte "
            f"({len(timed)} with arrival, {ez} with realtime); "
            f"{ort.get('name')} → Berlin re-searchable ({len(onward)} conns)")


def check_vendo_verkehrsmittel() -> str:
    """The `verkehrsmittel` filter must be honoured server-side.

    Vendo returns a small window of the *best* connections, so on an ICE trunk
    route like München–Augsburg an ["ALL"] search is 100% ICE even though REs
    run every few minutes. Filtering client-side therefore yields an empty
    list (issue #18) — the modes have to travel with the request.

    Asserts the enum values (from the DB Navigator's `VerkehrsmittelModel`)
    are still accepted and actually change the result set.
    """
    media = "application/x.db.vendo.mob.verbindungssuche.v9+json"
    nah = ["NAHVERKEHRSONSTIGEZUEGE", "SBAHNEN", "BUSSE", "UBAHN",
           "STRASSENBAHN", "SCHIFFE", "ANRUFPFLICHTIGEVERKEHRE"]
    fern = ["HOCHGESCHWINDIGKEITSZUEGE", "INTERCITYUNDEUROCITYZUEGE",
            "INTERREGIOUNDSCHNELLZUEGE"]

    def gattungen(vm: list) -> list:
        body = {
            "autonomeReservierung": False,
            "einstiegsTypList": ["STANDARD"],
            "fahrverguenstigungen": {
                "deutschlandTicketVorhanden": False,
                "nurDeutschlandTicketVerbindungen": False,
            },
            "klasse": "KLASSE_2",
            "reiseHin": {"wunsch": {
                "abgangsLocationId": MUNICH_LOC,
                "alternativeHalteBerechnung": True,
                "verkehrsmittel": vm,
                "zeitWunsch": {
                    "reiseDatum": (datetime.now().astimezone()
                                   + timedelta(days=1)).replace(
                                       hour=9, minute=0).isoformat(),
                    "zeitPunktArt": "ABFAHRT",
                },
                "zielLocationId": AUGSBURG_LOC,
            }},
            "reisendenProfil": {"reisende": [{
                "ermaessigungen": ["KEINE_ERMAESSIGUNG KLASSENLOS"],
                "reisendenTyp": "ERWACHSENER",
            }]},
            "reservierungsKontingenteVorhanden": False,
        }
        r = _post(
            "https://app.services-bahn.de/mob/angebote/fahrplan",
            headers=_vendo_headers(media), data=json.dumps(body),
            timeout=TIMEOUT,
        )
        if r.status_code == 400:
            raise CheckError(
                f"verkehrsmittel {vm} rejected (400) — enum changed, "
                "re-extract VerkehrsmittelModel from the Navigator APK")
        r.raise_for_status()
        out = []
        for c in r.json().get("verbindungen", []):
            for ab in c["verbindung"]["verbindungsAbschnitte"]:
                if ab.get("typ") == "FAHRZEUG":
                    out.append(ab.get("kurztext") or "?")
        return out

    nah_g = gattungen(nah)
    if not nah_g:
        raise CheckError("Nahverkehr-only search returned no legs")
    if any(g.startswith("ICE") for g in nah_g):
        raise CheckError(f"Nahverkehr-only search leaked Fernverkehr: {nah_g}")

    fern_g = gattungen(fern)
    if not fern_g:
        raise CheckError("Fernverkehr-only search returned no legs")
    if not any(g.startswith("IC") for g in fern_g):
        raise CheckError(f"Fernverkehr-only search has no IC*/ICE: {fern_g}")

    return (f"filter honoured — Nah={sorted(set(nah_g))} "
            f"Fern={sorted(set(fern_g))}")


def check_vendo_search_options() -> str:
    """The search options must be honoured server-side (#19).

    `maxUmstiege`, `minUmstiegsdauer` and `viaLocations` are the difference
    between *searching* for a connection the rider can make and filtering holes
    into a list we already fetched — the transfer profile can only warn about a
    5-minute change it was handed, it can't ask for a better one.

    Each is measured against a baseline on the same route rather than just
    asserting a 200: the backend answers an unknown wunsch field by ignoring
    it, so "not rejected" would prove nothing. Note it also answers an
    impossible constraint with an empty list, not an error — hence the app's
    relax-and-retry.
    """
    media = "application/x.db.vendo.mob.verbindungssuche.v9+json"
    # Köln→München: enough one-change options for a cap to bite, and it has
    # both direct ICEs and a natural via (Frankfurt).
    koeln = "A=1@O=Köln Hbf@X=6958730@Y=50943029@U=80@L=8000207@"
    frankfurt = "A=1@O=Frankfurt(Main)Hbf@X=8663785@Y=50107149@U=80@L=8000105@"

    def search(**wunsch) -> list:
        w = {
            "abgangsLocationId": koeln,
            "alternativeHalteBerechnung": True,
            "verkehrsmittel": ["ALL"],
            "zeitWunsch": {
                "reiseDatum": (datetime.now().astimezone() + timedelta(days=2))
                .replace(hour=9, minute=0, second=0, microsecond=0).isoformat(),
                "zeitPunktArt": "ABFAHRT",
            },
            "zielLocationId": MUNICH_LOC,
        }
        w.update(wunsch)
        body = {
            "autonomeReservierung": False,
            "einstiegsTypList": ["STANDARD"],
            "fahrverguenstigungen": {
                "deutschlandTicketVorhanden": False,
                "nurDeutschlandTicketVerbindungen": False,
            },
            "klasse": "KLASSE_2",
            "reiseHin": {"wunsch": w},
            "reisendenProfil": {"reisende": [{
                "ermaessigungen": ["KEINE_ERMAESSIGUNG KLASSENLOS"],
                "reisendenTyp": "ERWACHSENER",
            }]},
            "reservierungsKontingenteVorhanden": False,
        }
        r = _post(
            "https://app.services-bahn.de/mob/angebote/fahrplan",
            headers=_vendo_headers(media), data=json.dumps(body),
            timeout=TIMEOUT,
        )
        if r.status_code == 400:
            raise CheckError(f"wunsch {list(wunsch)} rejected (400) — field "
                             "renamed? re-extract from the Navigator APK")
        r.raise_for_status()
        out = []
        for c in r.json().get("verbindungen", []):
            legs = [a for a in c["verbindung"]["verbindungsAbschnitte"]
                    if a.get("typ") == "FAHRZEUG"]
            gaps = []
            for a, b in zip(legs, legs[1:]):
                gaps.append(int((datetime.fromisoformat(b["abgangsDatum"])
                                 - datetime.fromisoformat(a["ankunftsDatum"])
                                 ).total_seconds() // 60))
            stops = {a.get("abgangsOrt", {}).get("name") for a in legs}
            stops |= {a.get("ankunftsOrt", {}).get("name") for a in legs}
            out.append({"umst": len(legs) - 1, "gaps": gaps, "stops": stops})
        return out

    base = search()
    if not base:
        raise CheckError("baseline search returned no verbindungen")

    direct = search(maxUmstiege=0)
    if not direct:
        raise CheckError("maxUmstiege=0 returned nothing (route has ICEs)")
    if any(c["umst"] > 0 for c in direct):
        raise CheckError(
            f"maxUmstiege=0 ignored: {[c['umst'] for c in direct]} changes")

    slack = search(minUmstiegsdauer=40)
    if not slack:
        raise CheckError("minUmstiegsdauer=40 returned nothing")
    tight = [g for c in slack for g in c["gaps"] if g < 40]
    if tight:
        raise CheckError(f"minUmstiegsdauer=40 ignored: gaps {tight} min")

    # A via is *passed through*, not necessarily changed at — assert the route
    # touches it, which is the promise the option makes.
    via = search(viaLocations=[{"locationId": frankfurt}])
    if not via:
        raise CheckError("viaLocations returned nothing")
    via_stay = search(viaLocations=[{"locationId": frankfurt,
                                     "minUmstiegsdauer": 60}])
    if not via_stay:
        raise CheckError("viaLocations with own minUmstiegsdauer returned "
                         "nothing")
    if not any("Frankfurt(Main)Hbf" in c["stops"] for c in via_stay):
        raise CheckError("per-via minUmstiegsdauer dropped the via itself")

    base_min = min((g for c in base for g in c["gaps"]), default=None)
    return (f"honoured — baseline {len(base)} conns (min gap {base_min} min), "
            f"maxUmstiege=0 → {len(direct)} direct, minUmstiegsdauer=40 → "
            f"min gap {min((g for c in slack for g in c['gaps']), default='—')}"
            f", via → {len(via)} conns / with 60-min stay {len(via_stay)}")


def check_vendo_transfer_info() -> str:
    """DB's own transfer facts, which we used to re-derive or miss (#20.6).

    Two shapes, and the difference matters:

    - a walk BETWEEN stations (Köln Messe/Deutz → …Gl.11-12) carries
      `verfuegbareZeit` (the window, seconds) next to `abschnittsDauer` (the
      walk itself) and `distanz`;
    - a change WITHIN one station carries neither, and `abschnittsDauer` is
      the whole window again.

    vendo_service therefore only reads `abschnittsDauer` as a walk when
    `verfuegbareZeit` sits beside it. If DB ever started sending
    `verfuegbareZeit` on same-station changes too, that rule would start
    inventing walk times — so assert the pairing, not just the presence.

    `weiterfahrtAmGleichenBahnsteig` rides on the FUSSWEG leg (true also for
    Gleis 4 → 5 on one island platform) and is what stops the transfer profile
    warning about the easiest change DB can offer.
    """
    media = "application/x.db.vendo.mob.verbindungssuche.v9+json"
    kiel_augsburg = (
        "A=1@O=Kiel Hbf@X=10131976@Y=54314982@U=80@L=8000199@",
        "A=1@O=Augsburg Hbf@X=10885802@Y=48365456@U=80@L=8000013@",
    )
    body = {
        "autonomeReservierung": False,
        "einstiegsTypList": ["STANDARD"],
        "fahrverguenstigungen": {
            "deutschlandTicketVorhanden": False,
            "nurDeutschlandTicketVerbindungen": False,
        },
        "klasse": "KLASSE_2",
        "reiseHin": {"wunsch": {
            "abgangsLocationId": kiel_augsburg[0],
            "alternativeHalteBerechnung": True,
            "verkehrsmittel": ["ALL"],
            "zeitWunsch": {
                "reiseDatum": (datetime.now().astimezone() + timedelta(days=2))
                .replace(hour=8, minute=0, second=0, microsecond=0).isoformat(),
                "zeitPunktArt": "ABFAHRT",
            },
            "zielLocationId": kiel_augsburg[1],
        }},
        "reisendenProfil": {"reisende": [{
            "ermaessigungen": ["KEINE_ERMAESSIGUNG KLASSENLOS"],
            "reisendenTyp": "ERWACHSENER",
        }]},
        "reservierungsKontingenteVorhanden": False,
    }
    r = _post(
        "https://app.services-bahn.de/mob/angebote/fahrplan",
        headers=_vendo_headers(media), data=json.dumps(body), timeout=TIMEOUT,
    )
    r.raise_for_status()
    conns = r.json().get("verbindungen", [])
    if not conns:
        raise CheckError("no verbindungen returned")

    walks = same_platform = paired = 0
    adjacent_trains = 0
    for c in conns:
        legs = c["verbindung"]["verbindungsAbschnitte"]
        for a, b in zip(legs, legs[1:]):
            if a.get("typ") == "FAHRZEUG" and b.get("typ") == "FAHRZEUG":
                # Every transfer is modelled as a FUSSWEG leg; if that ever
                # changes, the flag has to be read off the train instead.
                adjacent_trains += 1
        for a in legs:
            if a.get("typ") != "FUSSWEG":
                continue
            walks += 1
            wf = a.get("weiterfahrtAmGleichenBahnsteig")
            if wf is not None and not isinstance(wf, bool):
                raise CheckError("weiterfahrtAmGleichenBahnsteig is not a bool")
            if wf:
                same_platform += 1
            vz, dauer = a.get("verfuegbareZeit"), a.get("abschnittsDauer")
            if vz is None:
                continue
            paired += 1
            if not isinstance(vz, int) or not isinstance(dauer, int):
                raise CheckError("verfuegbareZeit/abschnittsDauer not ints "
                                 "(seconds expected)")
            # The invariant the parser leans on: where DB gives both, the walk
            # fits inside the window. If they were ever equal on a same-station
            # change, "X min Weg" would be a window mislabelled as a walk.
            if dauer > vz:
                raise CheckError(
                    f"walk ({dauer}s) longer than the window ({vz}s) — "
                    "verfuegbareZeit is not the transfer window any more")

    if not walks:
        raise CheckError("no FUSSWEG legs — transfers are modelled elsewhere "
                         "now, the same-platform flag moved with them")
    if adjacent_trains:
        raise CheckError(f"{adjacent_trains} train→train transfers with no "
                         "FUSSWEG leg — read the flag off the train too")
    return (f"{walks} transfers: {same_platform} same-platform, {paired} with "
            f"verfuegbareZeit+abschnittsDauer paired")


def check_vendo_service_days() -> str:
    """`serviceDays.irregular` still describes the CONNECTION (#20, point 8).

    The app shows this string as "Verkehrstage dieser Verbindung". That is only
    honest while the date you're offered is never a date the string excludes —
    which is exactly what separates it from the zuglauf's `fahrplan.
    tageOhneFahrt`, where every sampled run was bookable on a day inside its
    own "tageOhneFahrt" range (RE 10909 on 18 Jul: "16. bis 23. Jul 2026"), and
    which the app therefore does NOT show.

    Parses the German ranges *here* — never in the app, where the string is
    passed through untouched — so a change in that promise trips this check
    instead of a user reading "fährt nicht" about the train they're sitting on.
    """
    media = "application/x.db.vendo.mob.verbindungssuche.v9+json"
    koeln = "A=1@O=Köln Hbf@X=6958730@Y=50943029@U=80@L=8000207@"
    months = {"Jan": 1, "Feb": 2, "Mär": 3, "Mrz": 3, "Apr": 4, "Mai": 5,
              "Jun": 6, "Jul": 7, "Aug": 8, "Sep": 9, "Okt": 10, "Nov": 11,
              "Dez": 12}

    def nicht_ranges(text: str, year: int):
        """(start, end) dates of every 'nicht …' span in a serviceDays text."""
        out = []
        for chunk in (text or "").split(";"):
            if "nicht" not in chunk:
                continue
            for m in re.finditer(
                    r"(\d{1,2})\.\s*(?:(\w{3})\.?\s*)?(?:(\d{4})\s*)?"
                    r"(?:bis\s*(\d{1,2})\.\s*(?:(\w{3})\.?\s*)?(?:(\d{4}))?)?",
                    chunk.split("nicht", 1)[1]):
                d1, m1, y1, d2, m2, y2 = m.groups()
                mm1 = months.get((m1 or m2 or "")[:3])
                mm2 = months.get((m2 or m1 or "")[:3]) or mm1
                if not (d1 and mm1):
                    continue
                try:
                    out.append((date(int(y1 or y2 or year), mm1, int(d1)),
                                date(int(y2 or y1 or year), mm2, int(d2 or d1))))
                except ValueError:
                    continue
        return out

    checked = with_note = 0
    for offset in (2, 30):
        body = {
            "autonomeReservierung": False,
            "einstiegsTypList": ["STANDARD"],
            "fahrverguenstigungen": {
                "deutschlandTicketVorhanden": False,
                "nurDeutschlandTicketVerbindungen": False,
            },
            "klasse": "KLASSE_2",
            "reiseHin": {"wunsch": {
                "abgangsLocationId": koeln,
                "alternativeHalteBerechnung": True,
                "verkehrsmittel": ["ALL"],
                "zeitWunsch": {
                    "reiseDatum": (datetime.now().astimezone()
                                   + timedelta(days=offset)).replace(
                        hour=9, minute=0, second=0,
                        microsecond=0).isoformat(),
                    "zeitPunktArt": "ABFAHRT",
                },
                "zielLocationId": MUNICH_LOC,
            }},
            "reisendenProfil": {"reisende": [{
                "ermaessigungen": ["KEINE_ERMAESSIGUNG KLASSENLOS"],
                "reisendenTyp": "ERWACHSENER",
            }]},
            "reservierungsKontingenteVorhanden": False,
        }
        r = _post(
            "https://app.services-bahn.de/mob/angebote/fahrplan",
            headers=_vendo_headers(media), data=json.dumps(body),
            timeout=TIMEOUT,
        )
        r.raise_for_status()
        for c in r.json().get("verbindungen", []):
            vb = c["verbindung"]
            days = vb.get("serviceDays") or []
            if not days:
                continue
            if not isinstance(days, list) or not isinstance(days[0], dict):
                raise CheckError("serviceDays is not a list of objects")
            note = (days[0].get("irregular") or "").strip()
            if not note:
                continue
            checked += 1
            with_note += 1
            dep = vb["verbindungsAbschnitte"][0].get("abgangsDatum")
            if not dep:
                continue
            travel = datetime.fromisoformat(dep).date()
            for start, end in nicht_ranges(note, travel.year):
                if start <= travel <= end:
                    raise CheckError(
                        f"connection departs {travel} but its own serviceDays "
                        f"excludes that date ({note!r}) — the string no longer "
                        "describes this connection, stop showing it as "
                        "Verkehrstage")
        time.sleep(2)

    if not with_note:
        raise CheckError("no connection carried serviceDays.irregular — the "
                         "Verkehrstage line can never appear")
    return (f"{with_note} connections with an irregular text, none excluding "
            "its own travel date")


def check_vendo_tagesbestpreis() -> str:
    """The Bestpreis calendar: a whole day of prices in ONE request (#21).

    Same media type and body as /angebote/fahrplan, minus the context. Each
    interval carries `angebotsPreis` and DB's own `istBestpreis`, plus the full
    connections — `kontext` included, which is what lets the app hand them
    straight to the detail/share/split paths instead of re-searching.

    Asserts the parts the app leans on: the interval bounds, that DB flags
    exactly one best interval, and that a connection still carries a kontext.
    """
    media = "application/x.db.vendo.mob.verbindungssuche.v9+json"
    koeln = "A=1@O=Köln Hbf@X=6958730@Y=50943029@U=80@L=8000207@"
    body = {
        "autonomeReservierung": False,
        "einstiegsTypList": ["STANDARD"],
        "fahrverguenstigungen": {
            "deutschlandTicketVorhanden": False,
            "nurDeutschlandTicketVerbindungen": False,
        },
        "klasse": "KLASSE_2",
        "reiseHin": {"wunsch": {
            "abgangsLocationId": koeln,
            "alternativeHalteBerechnung": True,
            "verkehrsmittel": ["ALL"],
            "zeitWunsch": {
                "reiseDatum": (datetime.now().astimezone() + timedelta(days=6))
                .replace(hour=0, minute=0, second=0,
                         microsecond=0).isoformat(),
                "zeitPunktArt": "ABFAHRT",
            },
            "zielLocationId": BERLIN_LOC,
        }},
        "reisendenProfil": {"reisende": [{
            "ermaessigungen": ["KEINE_ERMAESSIGUNG KLASSENLOS"],
            "reisendenTyp": "ERWACHSENER",
        }]},
        "reservierungsKontingenteVorhanden": False,
    }
    r = _post(
        "https://app.services-bahn.de/mob/angebote/tagesbestpreis",
        headers=_vendo_headers(media), data=json.dumps(body), timeout=TIMEOUT,
    )
    r.raise_for_status()
    intervals = r.json().get("tagesbestPreisIntervalle", [])
    if not intervals:
        raise CheckError("no tagesbestPreisIntervalle returned")

    best = 0
    priced = 0
    kontext_seen = False
    for iv in intervals:
        if not iv.get("intervallAb") or not iv.get("intervallBis"):
            raise CheckError("interval without intervallAb/intervallBis — the "
                             "app drops those, the calendar would lose a slot")
        if iv.get("istBestpreis"):
            best += 1
        preis = iv.get("angebotsPreis")
        if preis is not None:
            priced += 1
            if not isinstance(preis.get("betrag"), (int, float)):
                raise CheckError("angebotsPreis.betrag is not a number")
        for c in iv.get("verbindungen", []):
            if c.get("verbindung", {}).get("kontext"):
                kontext_seen = True
            else:
                raise CheckError("a Bestpreis connection has no kontext — "
                                 "detail/share/split would break on it")

    if best != 1:
        raise CheckError(f"{best} intervals flagged istBestpreis (expected "
                         "exactly 1) — the app marks what DB marks")
    if not priced:
        raise CheckError("no interval carried angebotsPreis")
    if not kontext_seen:
        raise CheckError("no connections in any interval")

    cheapest = min(iv["angebotsPreis"]["betrag"] for iv in intervals
                   if iv.get("angebotsPreis") and not iv.get("istTeilpreis"))
    return (f"{len(intervals)} intervals, {priced} priced, best flagged once, "
            f"cheapest {cheapest} EUR")


def check_vendo_stammdaten_drift() -> str:
    """The app's compiled-in `reisende.dart` enums vs. the live master data.

    `GET /mob/stammdaten` is the source these enums were copied from, by hand,
    out of an APK asset. That's the same failure mode as the hardcoded
    `verkehrsmittel: ['ALL']` of #18: a value that can't move when DB moves it.
    This diffs the Dart source itself — not a snapshot of it — so drift shows up
    the day it happens.

    Why the two directions are not treated alike:

    - `reisendenTyp` is a hard fail. We send exactly one per traveller, and a
      renamed one is an immediate break.
    - A BahnCard we ship that vanishes from the master data is a hard fail:
      BahnCards demonstrably move the price (BC50 takes Köln→München from
      153,69 € to 97,35 €), so if one stopped working, riders would silently be
      quoted full fare.
    - Anything else is REPORTED, not failed. The endpoint answers an invented
      `ermaessigungen` key with a 200 and an unchanged price — it ignores what
      it doesn't know. So a de-listed foreign/SBA key is indistinguishable from
      a working one, and failing CI over it would only invite someone to delete
      a working option (see SbaOption.beeintrOhneRolli).
    - Live keys we don't offer are reported too: NL-100 was found exactly that
      way, and it is real money (Köln→Amsterdam 73,99 € → 51,60 €).
    """
    media = "application/x.db.vendo.mob.stammdaten.v6+json"
    r = _get("https://app.services-bahn.de/mob/stammdaten"
             "?operatingSystem=ANDROID&sdtyp=RESOURCE",
             headers=_vendo_headers(media), timeout=40)
    r.raise_for_status()
    data = r.json()

    # `key` already carries the class suffix ("BAHNCARD50 KLASSE_2"), which is
    # exactly the token the app puts in `ermaessigungen`.
    live_erm = {e["key"] for e in data.get("ermaessigungen", [])
                if e.get("key")}
    live_typen = {e["key"] for e in data.get("reisendenTypen", []) if e.get("key")}
    if not live_erm or not live_typen:
        raise CheckError("stammdaten has no ermaessigungen/reisendenTypen — "
                         "shape changed")

    src = (pathlib.Path(__file__).resolve().parent.parent
           / "flutter-app" / "lib" / "models" / "reisende.dart").read_text(
               encoding="utf-8")

    def enum_body(name: str) -> str:
        """The `enum X { ... }` block, so one enum's keys can't leak into another."""
        m = re.search(rf"enum {name} \{{(.*?)^\}}", src, re.S | re.M)
        if not m:
            raise CheckError(f"enum {name} not found in reisende.dart")
        return m.group(1)

    def keys_of(name: str) -> set:
        # First string literal of each enum entry is its vendoKey.
        return {m.group(1) for m in
                re.finditer(r"'([A-Z0-9][A-Z0-9_\- ]*)'", enum_body(name))}

    ours_erm = keys_of("Reduction") | keys_of("SbaOption")
    ours_typen = keys_of("TravelerType")

    if ours_typen != live_typen:
        raise CheckError(
            f"reisendenTyp drift — ours-not-live: {sorted(ours_typen - live_typen)}, "
            f"live-not-ours: {sorted(live_typen - ours_typen)}")

    ours_missing = ours_erm - live_erm
    gone_bahncards = {k for k in ours_missing if k.startswith("BAHNCARD")}
    if gone_bahncards:
        raise CheckError(
            f"BahnCard keys no longer in the master data: {sorted(gone_bahncards)} "
            "— riders holding them would be quoted full fare")

    live_missing = live_erm - ours_erm
    notes = []
    if ours_missing:
        notes.append(f"we still offer {sorted(ours_missing)} (de-listed; the "
                     "endpoint ignores unknown keys, so this is not provably "
                     "broken)")
    if live_missing:
        notes.append(f"not offered by us: {sorted(live_missing)}")
    detail = ("; ".join(notes)) if notes else "no drift"
    return (f"{len(live_erm)} ermaessigungen / {len(live_typen)} reisendenTypen "
            f"live — {detail}")


def check_vendo_calculateroute() -> str:
    """Real walking routing, used for "Fußweg zum Gleis" (#21).

    The app deliberately does NOT send `desiredCoordinateType: WKB`: without it
    the same response carries the polyline as plain `gpsPositions`, so there is
    no WKB decoder in the app at all. This asserts that plain form still comes
    back with a real polyline — and, by decoding the WKB variant here only,
    that the two still agree. If DB ever made the polyline WKB-only, the app
    would silently fall back to straight lines forever; this check is what
    would say so.
    """
    media = "application/x.db.vendo.mob.location.v3+json"
    url = "https://app.services-bahn.de/mob/location/calculateroute"
    # Köln Hbf → ~200 m south. Straight-line ~200 m, real walk ~680 m — the
    # gap that makes the endpoint worth calling.
    points = [
        {"latitude": 50.943029, "longitude": 6.958730},
        {"latitude": 50.941200, "longitude": 6.958730},
    ]

    r = _post(url, headers=_vendo_headers(media),
              data=json.dumps({"gpsPositions": points}), timeout=TIMEOUT)
    if r.status_code == 400:
        raise CheckError("calculateroute rejected {gpsPositions:[{latitude,"
                         "longitude}]} (400) — request shape changed")
    r.raise_for_status()
    d = r.json()
    plain = d.get("gpsPositions") or []
    if len(plain) < 2:
        raise CheckError("no polyline in the plain response — the app has no "
                         "WKB decoder and would draw straight lines forever")
    for p in plain:
        if not isinstance(p.get("latitude"), (int, float)) or \
                not isinstance(p.get("longitude"), (int, float)):
            raise CheckError("gpsPositions entries are not lat/lon numbers")
    distance, traveltime = d.get("distance"), d.get("traveltime")
    if not isinstance(distance, int) or not isinstance(traveltime, int):
        raise CheckError("distance/traveltime missing or not ints (seconds "
                         "and metres expected)")

    # The whole point: routed distance must exceed the crow-flight one.
    straight = 203  # metres between the two points above
    if distance < straight:
        raise CheckError(f"routed distance {distance} m is under the straight "
                         f"line ({straight} m) — not a walking route")

    time.sleep(2)
    r2 = _post(url, headers=_vendo_headers(media),
               data=json.dumps({"gpsPositions": points,
                                "desiredCoordinateType": "WKB"}),
               timeout=TIMEOUT)
    r2.raise_for_status()
    raw = base64.b64decode(r2.json()["wkb"])
    endian = "<" if raw[0] == 1 else ">"
    gtype = struct.unpack_from(endian + "I", raw, 1)[0]
    if gtype != 2:
        raise CheckError(f"WKB geometry type {gtype}, expected 2 (LineString)")
    n = struct.unpack_from(endian + "I", raw, 5)[0]
    if n != len(plain):
        raise CheckError(f"WKB has {n} points but the plain response has "
                         f"{len(plain)} — they no longer agree, and the app "
                         "only reads the plain one")

    return (f"{len(plain)} points, {distance} m / {traveltime}s walking vs "
            f"~{straight} m straight; WKB agrees")


def check_vendo_journey_party() -> str:
    """Advanced "Reisende & Klasse" search: the app lets you build a party of
    multiple passengers (with explicit ages), a bike and a dog, pick 1st class,
    and attach BahnCards / a Schwerbehindertenausweis. Every key here comes from
    the DB Navigator master data (api-tests/db_stammdaten_enums.json). Exercise a
    representative payload — if DB renames a reisendenTyp/ermaessigung enum this
    400s before users hit it.

    Notes proven against the live endpoint: FAHRRAD/HUND are reisendenTyp
    entries with empty ermaessigungen; `alter` is a scalar int per traveller (an
    array → HTTP 400); BahnCard + SBA may be combined in one traveller's list.
    """
    media = "application/x.db.vendo.mob.verbindungssuche.v9+json"
    body = {
        "autonomeReservierung": False,
        "einstiegsTypList": ["STANDARD"],
        "fahrverguenstigungen": {
            "deutschlandTicketVorhanden": False,
            "nurDeutschlandTicketVerbindungen": False,
        },
        # 2nd class: a wheelchair-place SBA (…_MIT_ROLLSTUHL) is not bookable in
        # 1st class — DB rejects that combo with MDA-ERSTE-KLASSE-ROLLSTUHL.
        "klasse": "KLASSE_2",
        "reiseHin": {"wunsch": {
            "abgangsLocationId": KIEL_LOC,
            "alternativeHalteBerechnung": True,
            "verkehrsmittel": ["ALL"],
            "zeitWunsch": {
                "reiseDatum": datetime.now().astimezone().isoformat(),
                "zeitPunktArt": "ABFAHRT",
            },
            "zielLocationId": BERLIN_LOC,
        }},
        "reisendenProfil": {"reisende": [
            {  # adult with BahnCard 25 + Schwerbehindertenausweis (combined)
                "reisendenTyp": "ERWACHSENER",
                "ermaessigungen": [
                    "BAHNCARD25 KLASSE_2",
                    "SBA_BEEINTRAECHTIGUNGEN_MIT_ROLLSTUHL KLASSENLOS",
                ],
                "alter": 40,
            },
            {  # child with an explicit age
                "reisendenTyp": "FAMILIENKIND",
                "ermaessigungen": ["KEINE_ERMAESSIGUNG KLASSENLOS"],
                "alter": 10,
            },
            {"reisendenTyp": "FAHRRAD", "ermaessigungen": []},
            {"reisendenTyp": "HUND", "ermaessigungen": []},
        ]},
        "reservierungsKontingenteVorhanden": False,
    }
    r = _post(
        "https://app.services-bahn.de/mob/angebote/fahrplan",
        headers=_vendo_headers(media), data=json.dumps(body), timeout=TIMEOUT,
    )
    r.raise_for_status()
    conns = r.json().get("verbindungen", [])
    if not conns:
        raise CheckError("party search returned no verbindungen")
    return (f"party (2 pers, bike, dog, BC25+SBA) ok — "
            f"{len(conns)} journeys")


def check_vendo_share() -> str:
    """
    "Reise teilen": POST a connection's full HAFAS recon ctx (verbindung.kontext,
    field GH) to /angebote/verbindung/teilen → backend mints a `vbid` that
    resolves to the EXACT connection. Powers VendoService.shareJourney, which
    builds https://www.bahn.de/buchung/start?vbid=<vbid>. We first search to get
    a fresh kontext (recon strings are time-bound), then share it.
    """
    search_media = "application/x.db.vendo.mob.verbindungssuche.v9+json"
    search_body = {
        "autonomeReservierung": False,
        "einstiegsTypList": ["STANDARD"],
        "fahrverguenstigungen": {
            "deutschlandTicketVorhanden": False,
            "nurDeutschlandTicketVerbindungen": False,
        },
        "klasse": "KLASSE_2",
        "reiseHin": {"wunsch": {
            "abgangsLocationId": KIEL_LOC,
            "alternativeHalteBerechnung": True,
            "verkehrsmittel": ["ALL"],
            "zeitWunsch": {
                "reiseDatum": datetime.now().astimezone().isoformat(),
                "zeitPunktArt": "ABFAHRT",
            },
            "zielLocationId": BERLIN_LOC,
        }},
        "reisendenProfil": {"reisende": [{
            "ermaessigungen": ["KEINE_ERMAESSIGUNG KLASSENLOS"],
            "reisendenTyp": "ERWACHSENER",
        }]},
        "reservierungsKontingenteVorhanden": False,
    }
    sr = _post(
        "https://app.services-bahn.de/mob/angebote/fahrplan",
        headers=_vendo_headers(search_media), data=json.dumps(search_body),
        timeout=TIMEOUT,
    )
    sr.raise_for_status()
    conns = sr.json().get("verbindungen", [])
    if not conns:
        raise CheckError("no verbindungen to share")
    vb = conns[0]["verbindung"]
    recon = vb.get("kontext")
    if not recon or "¶" not in recon:
        raise CheckError("first verbindung carries no recon kontext")

    share_media = "application/x.db.vendo.mob.verbindungteilen.v1+json"
    abschnitte = vb.get("verbindungsAbschnitte", [])
    hd = abschnitte[0].get("abgangsDatum") if abschnitte else None
    share_body = {
        "GH": recon,
        "HD": hd,
        "SO": "Kiel Hbf",
        "ZO": "Berlin Hbf",
    }
    r = _post(
        "https://app.services-bahn.de/mob/angebote/verbindung/teilen",
        headers=_vendo_headers(share_media), data=json.dumps(share_body),
        timeout=TIMEOUT,
    )
    if r.status_code not in (200, 201):
        raise CheckError(f"teilen HTTP {r.status_code}")
    vbid = r.json().get("vbid")
    if not vbid:
        raise CheckError("teilen response has no vbid")
    return f"vbid minted ({vbid[:8]}…) → bahn.de/buchung/start?vbid=…"


def check_vendo_journey_pagination() -> str:
    """
    Earlier/later buttons: the journey response carries frueherContext/
    spaeterContext tokens; replaying one in reiseHin.wunsch.context scrolls the
    window. Verify the token comes back and earlier actually returns earlier
    departures (powers loadEarlier/loadLater in journey_search_provider).
    """
    media = "application/x.db.vendo.mob.verbindungssuche.v9+json"

    def body(context: str | None = None) -> dict:
        wunsch = {
            "abgangsLocationId": KIEL_LOC,
            "alternativeHalteBerechnung": True,
            "verkehrsmittel": ["ALL"],
            "zeitWunsch": {
                "reiseDatum": datetime.now().astimezone().isoformat(),
                "zeitPunktArt": "ABFAHRT",
            },
            "zielLocationId": BERLIN_LOC,
        }
        if context:
            wunsch["context"] = context
        return {
            "autonomeReservierung": False, "einstiegsTypList": ["STANDARD"],
            "fahrverguenstigungen": {"deutschlandTicketVorhanden": False,
                                     "nurDeutschlandTicketVerbindungen": False},
            "klasse": "KLASSE_2", "reiseHin": {"wunsch": wunsch},
            "reisendenProfil": {"reisende": [{
                "ermaessigungen": ["KEINE_ERMAESSIGUNG KLASSENLOS"],
                "reisendenTyp": "ERWACHSENER"}]},
            "reservierungsKontingenteVorhanden": False,
        }

    def first_dep(d: dict):
        c = d.get("verbindungen", [])
        if not c:
            return None
        return c[0]["verbindung"]["verbindungsAbschnitte"][0].get("abgangsDatum")

    url = "https://app.services-bahn.de/mob/angebote/fahrplan"
    base = _post(url, headers=_vendo_headers(media),
                         data=json.dumps(body()), timeout=TIMEOUT)
    base.raise_for_status()
    bd = base.json()
    tok = bd.get("frueherContext")
    if not tok:
        raise CheckError("no frueherContext token in journey response")
    earlier = _post(url, headers=_vendo_headers(media),
                            data=json.dumps(body(tok)), timeout=TIMEOUT)
    earlier.raise_for_status()
    ed = earlier.json()
    b0, e0 = first_dep(bd), first_dep(ed)
    if not e0 or not b0 or e0 >= b0:
        raise CheckError(f"earlier ctx did not return earlier trains "
                         f"(base={b0}, earlier={e0})")
    return f"pagination ok (base {b0[11:16]} -> earlier {e0[11:16]})"


def check_vendo_weitere_abfahrten() -> str:
    """
    "Weitere Abfahrten": alternative trains of one product group on a direct
    segment, anchored on arrival. POST /mob/trip/weitereabfahrten. NB the
    response puts verbindungsAbschnitte DIRECTLY on each connection (no
    `verbindung` wrapper, unlike /angebote/fahrplan) — the app relies on that.
    """
    media = "application/x.db.vendo.mob.verbindungssuche.v9+json"
    # anchor a few hours out so regional trains certainly exist
    ankunft = (datetime.now().astimezone() + timedelta(hours=4)).isoformat()
    body = {"wunsch": {
        "abgangsLocationId": KIEL_LOC,
        "alternativeHalteBerechnung": True,
        "fahrradmitnahme": False,
        "produktGattungen": "RB",
        "zeitWunsch": {"reiseDatum": ankunft, "zeitPunktArt": "ANKUNFT"},
        "zielLocationId": HAMBURG_LOC,
    }}
    r = _post(
        "https://app.services-bahn.de/mob/trip/weitereabfahrten",
        headers=_vendo_headers(media), data=json.dumps(body), timeout=TIMEOUT,
    )
    r.raise_for_status()
    conns = r.json().get("verbindungen", [])
    if not conns:
        raise CheckError("no verbindungen returned")
    c = conns[0]
    # the un-wrapped shape the app's _parseConnection now falls back to
    legs = c.get("verbindungsAbschnitte")
    if not legs:
        raise CheckError("connection has no verbindungsAbschnitte "
                         "(response shape changed)")
    halte = legs[0].get("halte", [])
    if len(halte) < 2:
        raise CheckError("first leg has no halte")
    dep = halte[0].get("abgangsDatum", "")
    return f"{len(conns)} alt departures, first {dep[11:16]} ({len(halte)} halte)"


def check_vendo_train_polyline() -> str:
    """
    GET /mob/zuglauf/{id} — the exact track geometry DB Navigator draws on its
    map (polylineGroup.polylineDesc[].coordinates). Powers the app's route map
    (services/vendo_service.fetchTripPolyline). Id is a vendo `zuglaufId` — here
    taken from the departure board (a vendo leg carries the same string).
    """
    pos = _vendo_board(BERLIN_HBF, arrivals=False)
    if not pos:
        raise CheckError("no departures to derive a zuglaufId")
    jid = pos[0]["zuglaufId"]

    r = _get(
        f"https://app.services-bahn.de/mob/zuglauf/{urllib.parse.quote(jid, safe='')}",
        headers=_vendo_headers(ZUGLAUF_MEDIA), timeout=TIMEOUT,
    )
    r.raise_for_status()
    data = r.json()
    descs = (data.get("polylineGroup") or {}).get("polylineDesc") or []
    pts = [c for d in descs for c in (d.get("coordinates") or [])]
    if not pts:
        raise CheckError("no polylineGroup.polylineDesc coordinates")
    first = pts[0]
    if "latitude" not in first or "longitude" not in first:
        raise CheckError("coordinate missing latitude/longitude")
    return f"{len(pts)} track points (first {first['latitude']},{first['longitude']})"


def check_bahnhof_map() -> str:
    """Indoor station map, fetched the way the app now does it: ask bahnhof.de
    for the RAW RSC flight stream (`RSC: 1` header → `text/x-component`) instead
    of the full HTML page. That stream is ~15-20 % smaller AND not wrapped in
    `self.__next_f.push([...])` chunks, so the app feeds it straight to the poi
    parser (skipping the expensive chunk reassembly) on a background isolate.

    We assert the stream still carries everything StationMapService parses:
    the `poi` object, PLATFORM (Gleis) + PLATFORM_SECTOR_CUBE (A-I sectors)
    categories, the elevator/escalator anchor arrays, and levels/levelInit.
    The HTML document remains the app's fallback; we also confirm it still works.
    """
    rsc_headers = {**_browser_headers(), "Accept": "*/*", "RSC": "1"}
    r = _get("https://www.bahnhof.de/hamburg-hbf/karte",
                     headers=rsc_headers, timeout=TIMEOUT)
    r.raise_for_status()
    ct = r.headers.get("content-type", "")
    if "x-component" not in ct:
        raise CheckError(f"RSC fetch did not return a flight stream (ct={ct})")
    stream = r.text
    # The flight stream must NOT be HTML-wrapped — that's the whole point.
    if "self.__next_f.push" in stream:
        raise CheckError("RSC fetch returned HTML-wrapped chunks, not a raw "
                         "flight stream (app's fast path would no longer apply)")
    if '"poi":{"' not in stream:
        raise CheckError("no embedded poi object in RSC flight stream")
    for cat in ('"PLATFORM"', "PLATFORM_SECTOR_CUBE"):
        if cat not in stream:
            raise CheckError(f"RSC stream missing {cat} category")
    if '"elevator":[' not in stream and '"escalator":[' not in stream:
        raise CheckError("RSC stream missing elevator/escalator anchor arrays")
    if '"levelInit"' not in stream:
        raise CheckError("RSC stream missing levelInit")

    # HTML fallback must still embed the poi data too.
    h = _get("https://www.bahnhof.de/hamburg-hbf/karte",
                     headers=_browser_headers(), timeout=TIMEOUT)
    h.raise_for_status()
    if '"poi\\":{\\"' not in h.text and '"poi":{"' not in h.text:
        raise CheckError("HTML fallback no longer embeds the poi object")
    return (f"RSC flight stream ok ({len(stream)//1024} KB, "
            f"poi+PLATFORM+SECTOR_CUBE+anchors); HTML fallback intact")


def check_bay_departure_link() -> str:
    """
    The station map links a tapped bay/track to live departures by matching the
    map POI's bay label against the departure board's `gleis`. Verify the two
    DB data sources still share a labelling so the match works (the app falls
    back to showing all departures when they don't, so this is a soft check).
    """
    pos = _vendo_board(KIEL, arrivals=False)
    gleise = {e.get("gleis") for e in pos if e.get("gleis")}

    karte = _get("https://www.bahnhof.de/kiel-hbf/karte",
                         headers=_browser_headers(), timeout=TIMEOUT)
    karte.raise_for_status()
    import re as _re
    bays = set(_re.findall(r"\[H\]([0-9A-Za-z]+)", karte.text))

    shared = gleise & bays
    if not shared:
        raise CheckError("no shared bay labels between map and departures "
                         "(app will fall back to all-departures view)")
    return f"{len(shared)} bay labels link map↔departures (e.g. {sorted(shared)[:4]})"


def _norm_gleis(g: str) -> str:
    """Mirror the app: drop the platform section suffix → base track id."""
    import re as _re
    g = g.strip()
    if not g:
        return g
    if _re.match(r"^\d", g):
        return _re.match(r"^\d+", g).group(0)
    return _re.split(r"\s+", g)[0].upper()


def check_gleis_departure_link() -> str:
    """
    Tapping a Gleis on the map links to its departures by matching the POI's
    track number to the board's `gleis`. The board adds a section suffix
    ("6A-C") the map omits ("6"); we normalise both. Verify they still align
    for trains at a big station — this is the universal (non-bus) case.
    """
    pos = _vendo_board("8002549", arrivals=False)  # Hamburg Hbf
    dep_g = {_norm_gleis(e["gleis"]) for e in pos if e.get("gleis")}

    karte = _get("https://www.bahnhof.de/hamburg-hbf/karte",
                         headers=_browser_headers(), timeout=TIMEOUT)
    karte.raise_for_status()
    import re as _re
    # Decode the RSC stream (same as the app) before matching.
    blob = "".join(
        json.loads(s) for s in
        _re.findall(r'self\.__next_f\.push\(\[\d+,("(?:[^"\\]|\\.)*")\]\)',
                    karte.text, _re.S))
    poi_tracks = {_norm_gleis(m) for m in
                  _re.findall(r'"type":"PLATFORM".{0,200}?"name":"([^"]+)"', blob)}
    poi_tracks.discard("")

    shared = dep_g & poi_tracks
    # Most departing tracks should map to a POI track number.
    if len(shared) < 5:
        raise CheckError(f"only {len(shared)} normalised tracks align "
                         f"(dep={sorted(dep_g)[:8]} poi={sorted(poi_tracks)[:8]})")
    return f"{len(shared)} track ids align map↔departures after normalisation"


def check_bahnhof_sitemap() -> str:
    r = _get("https://www.bahnhof.de/sitemap.xml",
                     headers=_browser_headers(), timeout=TIMEOUT)
    r.raise_for_status()
    count = r.text.count("<loc>https://www.bahnhof.de/")
    if count < 4000:
        raise CheckError(f"sitemap only has {count} urls (expected >4000)")
    return f"{count} sitemap urls"


def check_hafas_rest() -> str:
    """Community HAFAS mirror — flaky, treated as a soft/degraded check."""
    r = _get("https://v6.db.transport.rest/locations",
                     params={"query": "Koeln", "results": "1"},
                     headers=_browser_headers(), timeout=TIMEOUT)
    if r.status_code != 200:
        raise CheckError(f"HAFAS mirror down (HTTP {r.status_code})")
    data = r.json()
    if not data:
        raise CheckError("HAFAS mirror returned empty")
    return f"HAFAS mirror up ({data[0].get('name')})"


def check_website_journey_still_blocked() -> str:
    """
    The website journey POST is Akamai bot-blocked from non-browser clients.
    We assert it STAYS blocked — if this starts returning data, we can simplify.
    """
    now = datetime.now()
    body = {
        "abfahrtsHalt": KIEL_LOC, "ankunftsHalt": BERLIN_LOC,
        "anfrageZeitpunkt": now.strftime("%Y-%m-%dT%H:%M"),
        "ankunftSuche": "ABFAHRT", "klasse": "KLASSE_2",
        "produktgattungen": ["ICE", "EC_IC", "IR", "REGIONAL", "SBAHN"],
        "reisende": [{"typ": "ERWACHSENER", "ermaessigungen": [
            {"art": "KEINE_ERMAESSIGUNG", "klasse": "KLASSENLOS"}],
            "alter": [], "anzahl": 1}],
        "schnelleVerbindungen": True,
    }
    r = _post("https://www.bahn.de/web/api/angebote/fahrplan",
                      headers={**_browser_headers(),
                               "Content-Type": "application/json"},
                      data=json.dumps(body), timeout=TIMEOUT)
    if r.status_code == 200 and "verbindungen" in r.text:
        # Not an error — a happy surprise worth flagging.
        raise CheckError("website journey POST now WORKS — consider using it")
    # Any non-200 (OPS_BLOCKED / 403 / 422 / 500) means still unusable, as expected.
    reason = "OPS_BLOCKED" if "OPS_BLOCKED" in r.text else f"HTTP {r.status_code}"
    return f"still unusable as expected ({reason}); use vendo instead"


def check_vendo_seat_map() -> str:
    """Graphical seat display (gsd) — the 'free seats' feature.

    Drives `gsd_v3` straight from a journey leg's train number + boarding/
    alighting EVA + planned times (no auth, no booking zugfahrtKey). Asserts
    the SSR page still carries `ssr_data` with coaches → plaetze {status,
    nummer}, and that the per-coach geometry endpoint still returns elements.
    """
    media = "application/x.db.vendo.mob.verbindungssuche.v9+json"
    body = {
        "autonomeReservierung": False,
        "einstiegsTypList": ["STANDARD"],
        "fahrverguenstigungen": {"deutschlandTicketVorhanden": False,
                                 "nurDeutschlandTicketVerbindungen": False},
        "klasse": "KLASSE_2",
        "reiseHin": {"wunsch": {
            "abgangsLocationId": KIEL_LOC, "alternativeHalteBerechnung": True,
            "verkehrsmittel": ["ALL"],
            "zeitWunsch": {"reiseDatum": datetime.now().astimezone().isoformat(),
                           "zeitPunktArt": "ABFAHRT"},
            "zielLocationId": BERLIN_LOC}},
        "reisendenProfil": {"reisende": [{
            "ermaessigungen": ["KEINE_ERMAESSIGUNG KLASSENLOS"],
            "reisendenTyp": "ERWACHSENER"}]},
        "reservierungsKontingenteVorhanden": False,
    }
    r = _post("https://app.services-bahn.de/mob/angebote/fahrplan",
                      headers=_vendo_headers(media), data=json.dumps(body),
                      timeout=TIMEOUT)
    r.raise_for_status()
    # Collect ALL long-distance legs (ICE/IC/EC) across the results — those carry
    # a seat plan. Not every train exposes a graphical plan though: some units
    # answer gsd_v3 with 409 Conflict. So we try candidates in turn and accept the
    # first that returns a usable plan; only if none do is the endpoint suspect.
    candidates = []
    for c in r.json().get("verbindungen", []):
        for a in c["verbindung"]["verbindungsAbschnitte"]:
            if (a.get("produktGattung") or "").upper() in ("ICE", "IC", "EC", "ECE"):
                candidates.append(a)
    if not candidates:
        raise CheckError("no long-distance leg to derive a seat-map request")

    g = None
    fahrt_nr = ab_eva = an_eva = ab_t = an_t = ""
    tried = 0
    skipped = []
    for leg in candidates:
        fahrt_nr = str(leg.get("zugNummer") or leg.get("verkehrsmittelNummer") or "")
        ab_eva = str(leg["abgangsOrt"].get("evaNr") or "")
        an_eva = str(leg["ankunftsOrt"].get("evaNr") or "")
        # gsd wants naive local time (no offset suffix).
        ab_t = (leg.get("abgangsDatum") or "").split("+")[0]
        an_t = (leg.get("ankunftsDatum") or "").split("+")[0]
        if not (fahrt_nr and ab_eva and an_eva and ab_t and an_t):
            continue
        tried += 1
        data = {"buchungskontext": {"quellSystem": "SIMA", "buchungsKontextId": str(uuid.uuid4()),
                "buchungsKontextDaten": {"zugnummer": fahrt_nr, "zugfahrtKey": "",
                    "abfahrtHalt": {"locationId": ab_eva, "abfahrtZeit": ab_t},
                    "ankunftHalt": {"locationId": an_eva, "ankunftZeit": an_t},
                    "inventarsystem": "RIFF",
                    "platzbedarfe": [{"platzprofilCode": "StandardEinzelperson",
                                      "anzahl": 1.0, "klasse": "KLASSE_2"}]}},
                "correlationID": _corr_id(), "lang": "de", "theme": "app"}
        url = ("https://app.services-bahn.de/mob/gsd/gsd_v3?data="
               + urllib.parse.quote(json.dumps(data, separators=(",", ":"))))
        resp = _get(url, headers={"User-Agent": DBNAV_UA}, timeout=TIMEOUT)
        if resp.status_code == 200 and "id='ssr_data'" in resp.text:
            g = resp
            break
        skipped.append(f"{fahrt_nr}:{resp.status_code}")
    if g is None:
        raise CheckError(
            f"no train exposed a gsd plan across {tried} tried "
            f"(e.g. {', '.join(skipped[:5])})")
    m = re.search(r"id='ssr_data'\s*>(.*?)</script>", g.text, re.S)
    if not m:
        raise CheckError("gsd_v3 page has no ssr_data blob")
    ssr = json.loads(m.group(1))
    coaches = [w for zt in ssr.get("zugfahrt", {}).get("zugteile", [])
               for w in zt.get("wagen", [])]
    if not coaches:
        raise CheckError("gsd ssr_data has no coaches")
    plaetze = coaches[0].get("plaetze", [])
    if not plaetze or "status" not in plaetze[0] or "nummer" not in plaetze[0]:
        raise CheckError("coach plaetze missing status/nummer")
    # DB status enum: 0=NICHT_AUSWAEHLBAR (reserved), 1=AUSWAEHLBAR (free),
    # 2=VORGESCHLAGEN (suggested, also free). So free = status in {1, 2}.
    free = sum(1 for w in coaches for p in w["plaetze"] if p.get("status") in (1, 2))
    total = sum(len(w["plaetze"]) for w in coaches)

    # Per-coach geometry endpoint.
    wtyp = coaches[0].get("wagentyp", "")
    if not wtyp:
        raise CheckError("coach missing wagentyp for geometry lookup")
    w = _get(
        f"https://app.services-bahn.de/mob/gsd/api/wagentypen/{urllib.parse.quote(wtyp)}",
        headers={"User-Agent": DBNAV_UA}, timeout=TIMEOUT)
    w.raise_for_status()
    teile = w.json().get("wagenteile", [])
    if not teile or not teile[0].get("elemente"):
        raise CheckError("wagentyp geometry has no elemente")
    el = teile[0]["elemente"][0]
    if "x" not in el or "y" not in el or "type" not in el:
        raise CheckError("geometry element missing x/y/type")
    return (f"zug {fahrt_nr}: {len(coaches)} coaches, {free}/{total} free, "
            f"geometry ok ({len(teile[0]['elemente'])} elems)")


def check_wagenreihung_split() -> str:
    """Wing-train (Flügelzug) coach data.

    The app now fetches the Wagenreihung for regional trains too (RE/RB), not
    just long-distance, so it can answer the one question the official app
    buries: *which coaches go to my destination* when a train splits. The
    vehicle-sequence endpoint must keep returning per-portion `groups`, each
    with `transport.destination.name` and per-vehicle `platformPosition.sector`.

    Probed on the RE corridor Hamburg → Kiel (the RE7 splits in Neumünster into
    a Kiel and a Flensburg portion). Soft: the splitting service only runs at
    certain times, and the endpoint is occasionally flaky.
    """
    media = "application/x.db.vendo.mob.verbindungssuche.v9+json"
    noon = (datetime.now().astimezone().replace(hour=12, minute=0)
            + timedelta(days=1)).isoformat()
    body = {
        "autonomeReservierung": False, "einstiegsTypList": ["STANDARD"],
        "fahrverguenstigungen": {"deutschlandTicketVorhanden": False,
                                 "nurDeutschlandTicketVerbindungen": False},
        "klasse": "KLASSE_2",
        "reiseHin": {"wunsch": {
            "abgangsLocationId": HAMBURG_LOC, "alternativeHalteBerechnung": True,
            "verkehrsmittel": ["ALL"],
            "zeitWunsch": {"reiseDatum": noon, "zeitPunktArt": "ABFAHRT"},
            "zielLocationId": KIEL_LOC}},
        "reisendenProfil": {"reisende": [{
            "ermaessigungen": ["KEINE_ERMAESSIGUNG KLASSENLOS"],
            "reisendenTyp": "ERWACHSENER"}]},
        "reservierungsKontingenteVorhanden": False,
    }
    r = _post(
        "https://app.services-bahn.de/mob/angebote/fahrplan",
        headers=_vendo_headers(media), data=json.dumps(body), timeout=TIMEOUT)
    r.raise_for_status()
    conns = r.json().get("verbindungen", [])
    leg = None
    for c in conns:
        for a in c["verbindung"]["verbindungsAbschnitte"]:
            if a.get("typ") == "FAHRZEUG" and a.get("kurztext") in (
                    "RE", "RB", "IRE"):
                leg = a
                break
        if leg:
            break
    if leg is None:
        raise CheckError("no RE/RB leg in Hamburg→Kiel results")

    dep = datetime.fromisoformat(leg["abgangsDatum"])
    eva = leg["halte"][0]["ort"].get("evaNr", "8002549")
    seq = _wagenreihung(leg["kurztext"], leg["zugNummer"], eva, dep)
    if seq is None:
        raise CheckError("vehicle-sequence 404 for the RE leg's own origin")
    groups = seq.get("groups", [])
    if not groups:
        raise CheckError("vehicle-sequence returned no groups")

    # The platform-train map (lib/dev/platform_preview + core/platform_train)
    # places each coach to scale by MAPPING the DB metre axis onto the track:
    # it needs platform.sectors[].{start,end} (sector A–I metre ranges) and each
    # vehicle's platformPosition.{start,end,sector}. Assert that shape survives.
    sectors = (seq.get("platform") or {}).get("sectors") or []
    if not sectors or any(
            not isinstance(s.get("start"), (int, float))
            or not isinstance(s.get("end"), (int, float)) for s in sectors):
        raise CheckError("platform.sectors missing numeric start/end metres")
    positioned = [v for g in groups for v in (g.get("vehicles") or [])
                  if isinstance(v.get("platformPosition"), dict)
                  and (v["platformPosition"].get("end", 0)
                       - v["platformPosition"].get("start", 0)) > 0]
    if not positioned:
        raise CheckError("no vehicle has a metre platformPosition (start<end)")
    dests = []
    for g in groups:
        t = g.get("transport")
        if not isinstance(t, dict):
            raise CheckError("group missing 'transport' object")
        d = (t.get("destination") or {}).get("name")
        if d:
            dests.append(d)
    if len(groups) > 1 and len(dests) < 2:
        raise CheckError("split train but group destinations missing")
    tag = " SPLIT→" + "/".join(dests) if len(groups) > 1 else " (solo)"
    return f"{leg['langtext']}: {len(groups)} portion(s){tag}"


def check_wagenreihung_transfer_sectors() -> str:
    """The two facts the transfer section advice stands on (#27, utils/
    transfer_coach_advice.dart). If either dies the app must go quiet, not guess.

    1. The vehicle-sequence endpoint serves a train at an INTERMEDIATE stop,
       keyed by its ARRIVAL time there. The advice needs the arriving train's
       composition at the *transfer* stop; the leg's stop list ends at the
       rider's alight, so the arrival is the only time we have to ask with.
       (Not every train/stop is served — a 404 is normal and means silence.)

    2. Both tracks of ONE island platform report the SAME sector letter→metre
       table. That shared frame is the whole basis for comparing where the two
       trains stop; without it the metres are unrelated axes and the advice
       would be a coin flip. Verified live at Berlin Hbf Gl. 3/4:
           Gleis 3: G 0–97.5 … A 358.8–430.2
           Gleis 4: G 0–97.5 … A 358.8–430.2
       Real island tracks agree within ~2 m; genuinely different platforms are
       far off (Dortmund Gl. 16 vs 11 put sector G's end 51 m apart), which is
       exactly what the app's 15 m frame guard keys on.

    Soft: needs a same-platform transfer to exist in today's search results and
    both trains to be served, so it can legitimately find nothing to measure.
    """
    media = "application/x.db.vendo.mob.verbindungssuche.v9+json"
    when = (datetime.now().astimezone().replace(hour=9, minute=0, second=0,
                                                microsecond=0)
            + timedelta(days=1)).isoformat()
    body = {
        "autonomeReservierung": False, "einstiegsTypList": ["STANDARD"],
        "fahrverguenstigungen": {"deutschlandTicketVorhanden": False,
                                 "nurDeutschlandTicketVerbindungen": False},
        "klasse": "KLASSE_2",
        "reiseHin": {"wunsch": {
            "abgangsLocationId": HAMBURG_LOC, "alternativeHalteBerechnung": True,
            "verkehrsmittel": ["ALL"],
            "zeitWunsch": {"reiseDatum": when, "zeitPunktArt": "ABFAHRT"},
            "zielLocationId": MUNICH_LOC}},
        "reisendenProfil": {"reisende": [{
            "ermaessigungen": ["KEINE_ERMAESSIGUNG KLASSENLOS"],
            "reisendenTyp": "ERWACHSENER"}]},
        "reservierungsKontingenteVorhanden": False,
    }
    r = _post("https://app.services-bahn.de/mob/angebote/fahrplan",
              headers=_vendo_headers(media), data=json.dumps(body),
              timeout=TIMEOUT)
    r.raise_for_status()

    intermediate_ok = None   # fact 1
    frame_note = None        # fact 2
    for c in r.json().get("verbindungen", []):
        legs = [x for x in c["verbindung"]["verbindungsAbschnitte"]
                if x.get("typ") == "FAHRZEUG"]
        for a, b in zip(legs, legs[1:]):
            stop = a["halte"][-1]
            eva = stop["ort"].get("evaNr")
            if not eva or b["halte"][0]["ort"].get("evaNr") != eva:
                continue  # change between two different stations
            arr_t = stop.get("ankunftsDatum")
            dep_t = b["halte"][0].get("abgangsDatum")
            if not arr_t or not dep_t:
                continue
            # Fact 1 — the arriving train, asked for by its arrival here. This
            # stop is mid-run for it, not an origin.
            arr = _wagenreihung(a["kurztext"], a["zugNummer"], eva,
                                datetime.fromisoformat(arr_t))
            if arr is not None and (arr.get("platform") or {}).get("sectors"):
                intermediate_ok = (f"{a['kurztext']} {a['zugNummer']} mid-run @ "
                                   f"{stop['ort'].get('name')} Gl."
                                   f"{arr.get('departurePlatform')}")
            dep = _wagenreihung(b["kurztext"], b["zugNummer"], eva,
                                datetime.fromisoformat(dep_t))
            if arr is None or dep is None:
                continue
            # Fact 2 — only meaningful for two tracks DB itself calls one
            # platform. Vendo hangs that flag on the FUSSWEG before the train.
            same = any(x.get("typ") == "FUSSWEG"
                       and x.get("weiterfahrtAmGleichenBahnsteig")
                       for x in c["verbindung"]["verbindungsAbschnitte"])
            ta = {s["name"]: s for s in (arr.get("platform") or {}).get("sectors", [])}
            tb = {s["name"]: s for s in (dep.get("platform") or {}).get("sectors", [])}
            shared = set(ta) & set(tb)
            if not (same and len(shared) >= 2):
                continue
            worst = max(
                max(abs(ta[k]["start"] - tb[k]["start"]),
                    abs(ta[k]["end"] - tb[k]["end"])) for k in shared)
            gl_a, gl_b = arr.get("departurePlatform"), dep.get("departurePlatform")
            if gl_a != gl_b and worst > 15.0:
                raise CheckError(
                    f"same-platform Gl.{gl_a}/{gl_b} at "
                    f"{stop['ort'].get('name')}: sector tables disagree by "
                    f"{worst:.1f} m (>15 m) — the shared-frame assumption "
                    f"behind #27 no longer holds")
            frame_note = (f"Gl.{gl_a}/{gl_b} @ {stop['ort'].get('name')}: "
                          f"{len(shared)} shared sectors agree within "
                          f"{worst:.1f} m")
            break
        if frame_note:
            break

    if intermediate_ok is None:
        raise CheckError("no train's Wagenreihung served at a transfer stop "
                         "keyed by arrival time (advice would never fire)")
    parts = [f"mid-run sequence ok ({intermediate_ok})"]
    parts.append(frame_note or "no same-platform pair to measure today")
    return "; ".join(parts)


def _delayed_board_trains(eva: str, cats: set, min_delay: int = 5) -> list:
    """Board rows whose realtime departure runs >= min_delay behind the planned
    one. Returns (category, number, planned, live, delay_min, label)."""
    out = []
    for p in _vendo_board(eva):
        cat = (p.get("kurztext") or "").upper().strip()
        if cat not in cats:
            continue
        plan, live = p.get("abgangsDatum"), p.get("ezAbgangsDatum")
        if not plan or not live:
            continue
        dp, dl = datetime.fromisoformat(plan), datetime.fromisoformat(live)
        delay = (dl - dp).total_seconds() / 60
        if delay >= min_delay:
            out.append((cat, p.get("zugnummer"), dp, dl, delay,
                        p.get("mitteltext") or f"{cat} {p.get('zugnummer')}"))
    out.sort(key=lambda x: -x[4])
    return out


def check_wagenreihung_time_key() -> str:
    """WHICH parameter selects the run (#32) — the semantics the app's cache key
    and every call site depend on.

    Measured 2026-07-16: `time` is IGNORED. ICE 205 @ Köln Hbf returned a
    byte-identical body for every time from −12 h to +12 h as long as `date`
    stayed the service date, and 404'd the moment `date` moved by a day. So the
    key is date + category + number + evaNumber.

    That is *why* the app asks with the SCHEDULED time: it derives `date` from
    the same DateTime, so a live time is harmless until a delay pushes it past
    midnight — then it asks for tomorrow's run and gets nothing, exactly when
    the rider needs the Wagenreihung most.

    This check nails both halves down:
      1. a really delayed train answers the SAME for its planned and its live
         time (proves `time` is not the selector — if DB ever made it one, the
         app must go back to caring which time it sends);
      2. the same train on the next day's `date` does NOT return that body
         (proves `date` IS the selector, so deriving it from a live time across
         midnight really is a bug).

    Soft: needs a >=5 min delayed long-distance train on the board right now.
    """
    delayed = []
    for eva in (KOELN_HBF, "8000105"):  # Köln, Frankfurt(Main)Hbf
        delayed += _delayed_board_trains(eva, {"ICE", "IC", "EC"}, min_delay=5)
        if delayed:
            break
    if not delayed:
        raise _SkipCheck("no delayed long-distance train on the board to probe")

    for (cat, num, dp, dl, delay, label) in delayed[:4]:
        r_plan = _wagenreihung_get({
            "administrationId": "80", "category": cat,
            "date": f"{dp.year}-{dp.month:02d}-{dp.day:02d}",
            "evaNumber": eva, "number": str(num),
            "time": dp.astimezone(timezone.utc).isoformat().replace("+00:00", "Z"),
        })
        if r_plan.status_code != 200:
            continue  # this train simply isn't served here — try the next
        r_live = _wagenreihung_get({
            "administrationId": "80", "category": cat,
            "date": f"{dl.year}-{dl.month:02d}-{dl.day:02d}",
            "evaNumber": eva, "number": str(num),
            "time": dl.astimezone(timezone.utc).isoformat().replace("+00:00", "Z"),
        })
        # Same calendar day => `date` is unchanged => must be the same run.
        if dl.date() == dp.date():
            if r_live.status_code != 200:
                raise CheckError(
                    f"{label} +{delay:.0f}min: planned time 200 but live time "
                    f"{r_live.status_code} on the SAME service date — `time` "
                    f"has become a selector; the app's key assumptions (#32) "
                    f"no longer hold")
            # Bodies carry live fields (platform/status), so compare the
            # composition, not the bytes.
            a = [v.get("vehicleID") for g in r_plan.json().get("groups", [])
                 for v in (g.get("vehicles") or [])]
            b = [v.get("vehicleID") for g in r_live.json().get("groups", [])
                 for v in (g.get("vehicles") or [])]
            if a != b:
                raise CheckError(
                    f"{label} +{delay:.0f}min: planned and live time return "
                    f"DIFFERENT compositions ({len(a)} vs {len(b)} cars) — "
                    f"`time` now selects the run (#32)")
        # `date` is the selector: tomorrow's date must not serve this run.
        nxt = dp + timedelta(days=1)
        r_next = _wagenreihung_get({
            "administrationId": "80", "category": cat,
            "date": f"{nxt.year}-{nxt.month:02d}-{nxt.day:02d}",
            "evaNumber": eva, "number": str(num),
            "time": dp.astimezone(timezone.utc).isoformat().replace("+00:00", "Z"),
        })
        date_matters = r_next.status_code != 200
        return (f"{label} +{delay:.0f}min: planned & live time agree "
                f"(time ignored); next-day date -> {r_next.status_code} "
                f"({'date is the selector' if date_matters else 'date tolerated'})")
    raise _SkipCheck("no delayed train that the endpoint actually serves")


def check_wagenreihung_sbahn() -> str:
    """S-Bahnen DO have a Wagenreihung (#33) — the app fetches them.

    They were excluded for years on the premise "S-Bahn hat keine Sequenz".
    Measured 2026-07-16 against the real endpoint (3 departures per network):
    it's per-network and all-or-nothing, not random —

      served  Rhein-Neckar (Heidelberg), Rhein-Ruhr (Essen), Nürnberg, Dresden
      404     Hamburg, Berlin, München, Stuttgart, Rhein-Main

    Note DB's OWN board flag `wagenreihung: true` is NOT evidence: München,
    Stuttgart and Frankfurt set it and then 404. Only the endpoint counts.

    Soft, and deliberately weak: it asserts that SOME S-Bahn network still
    serves sequences, not that any particular one does. A single network
    dropping out is DB's business; all of them dropping out means the `S`
    category earns nothing but wasted requests and should come back out.
    """
    tried = served = 0
    detail = []
    for name, eva in (("Rhein-Neckar", "8000156"),  # Heidelberg Hbf
                      ("Rhein-Ruhr", "8000098"),    # Essen Hbf
                      ("Nürnberg", "8000284")):
        rows = [p for p in _vendo_board(eva)
                if (p.get("kurztext") or "").upper().strip() == "S"
                and p.get("abgangsDatum")]
        for p in rows[:2]:
            tried += 1
            seq = _wagenreihung("S", p.get("zugnummer"), eva,
                                datetime.fromisoformat(p["abgangsDatum"]))
            if not seq or not seq.get("groups"):
                continue
            cars = [v for g in seq["groups"] for v in (g.get("vehicles") or [])]
            positioned = [c for c in cars
                          if isinstance(c.get("platformPosition"), dict)
                          and (c["platformPosition"].get("end", 0)
                               - c["platformPosition"].get("start", 0)) > 0]
            if not positioned:
                # A sequence with no metres is useless to the drawing — the app
                # would fetch it and draw nothing.
                continue
            served += 1
            detail.append(f"{name} {p.get('mitteltext')}: {len(cars)} cars, "
                          f"{len(positioned)} positioned, "
                          f"{len(seq['groups'])} portion(s)")
            break
        if served:
            break
    if not tried:
        raise _SkipCheck("no S-Bahn departures on the boards to probe")
    if not served:
        raise CheckError(
            f"no S-Bahn sequence served across {tried} probes in Rhein-Neckar/"
            f"Rhein-Ruhr/Nürnberg — the `S` category in "
            f"coach_sequence_service.dart now only costs 404s (#33)")
    return "; ".join(detail)


def check_osm_platform_geometry() -> str:
    """OpenStreetMap platform + rail geometry via Overpass — the accurate track
    centre-line the platform train rides (services/osm_platform_service.dart →
    core/osm_rail.dart). The app POSTs the SAME Overpass QL around a station's
    centre: `public_transport=platform` AREA ways carrying a `ref` (the Gleis
    pair, e.g. "7;8") + every `railway=rail` way, asking `out geom;` so each way
    inlines its node coordinates. Assert both shapes survive near Hamburg Hbf.

    Soft: the app soft-fails to the bahnhof.de cube placement if Overpass is
    down, so a missing Overpass degrades gracefully rather than breaking.
    """
    # ~600 m bbox around Hamburg Hbf (10.006909, 53.552733), matching the app.
    lat, lon, r = 53.552733, 10.006909, 600.0
    d_lat = r / 111320.0
    d_lon = r / (111320.0 * math.cos(math.radians(lat)))
    bbox = f"{lat - d_lat},{lon - d_lon},{lat + d_lat},{lon + d_lon}"
    # Platforms come as tagged WAYS (Hamburg "7;8") or multipolygon RELATIONS
    # whose ref holds the Gleis pair (Kiel "3;4"); the app fetches both.
    ql = ("[out:json][timeout:25];("
          f'way["public_transport"="platform"]["ref"]({bbox});'
          f'relation["public_transport"="platform"]["ref"]({bbox});'
          f'way["railway"="rail"]({bbox});'
          ");out geom;")
    # Same mirror fallthrough as the app (services/osm_platform_service.dart):
    # the main instance 504s under load, so try mirrors before failing.
    endpoints = [
        "https://overpass-api.de/api/interpreter",
        "https://overpass.openstreetmap.fr/api/interpreter",
        "https://overpass.kumi.systems/api/interpreter",
    ]
    resp = None
    last = None
    for endpoint in endpoints:
        try:
            r = _post(endpoint, data={"data": ql},
                              headers={"User-Agent": "BesserBahn/1.0 (+https://bahn.chuk.dev)",
                                       "Accept": "*/*"}, timeout=TIMEOUT)
            if r.status_code == 200:
                resp = r
                break
            last = f"{endpoint} HTTP {r.status_code}"
        except requests.RequestException as e:
            last = f"{endpoint} {type(e).__name__}"
    if resp is None:
        raise CheckError(f"all Overpass mirrors unavailable (last: {last})")
    elements = resp.json().get("elements", [])
    if not elements:
        raise CheckError("Overpass returned no elements near Hamburg Hbf")
    platforms, rails = [], 0
    for el in elements:
        tags = el.get("tags") or {}
        if tags.get("railway") == "rail":
            geom = el.get("geometry") or []
            if len(geom) >= 2 and "lat" in geom[0] and "lon" in geom[0]:
                rails += 1
        elif tags.get("public_transport") == "platform" and tags.get("ref"):
            # A relation's geometry lives in its member ways, not at top level.
            if el.get("type") == "relation":
                if el.get("members"):
                    platforms.append(tags["ref"])
            else:
                geom = el.get("geometry") or []
                if len(geom) >= 2 and "lat" in geom[0] and "lon" in geom[0]:
                    platforms.append(tags["ref"])
    if not platforms:
        raise CheckError("no public_transport=platform ways with a ref (Gleis)")
    if rails < 1:
        raise CheckError("no railway=rail ways with inlined geometry")
    # The Gleis-7 island ("7;8") is what the preview/port is verified against.
    if not any("7" in p.split(";") for p in platforms):
        raise CheckError(f"no platform ref includes Gleis 7 (got {platforms[:6]})")
    return (f"{len(platforms)} platform refs (e.g. {sorted(set(platforms))[:5]}), "
            f"{rails} rail ways")


def check_basemap_tiles() -> str:
    """Outdoor base map: OpenFreeMap "Positron" VECTOR tiles — the German-labelled
    (local names), keyless, light basemap the app renders under every outdoor map
    via vector_map_tiles. Assert the style JSON resolves and a vector tile (.pbf)
    serves. Soft: on loss the app falls back to the CARTO raster, data still works.
    """
    hdr = {"User-Agent": DBNAV_UA}
    style = _get("https://tiles.openfreemap.org/styles/positron",
                         headers=hdr, timeout=TIMEOUT)
    style.raise_for_status()
    src = style.json().get("sources", {}).get("openmaptiles", {})
    src_url = src.get("url")
    if not src_url and not src.get("tiles"):
        raise CheckError("positron style lost its openmaptiles vector source")
    # Resolve the source TileJSON → it must advertise pbf tile URLs.
    tj = _get(src_url, headers=hdr, timeout=TIMEOUT)
    tj.raise_for_status()
    tiles = tj.json().get("tiles") or []
    if not tiles or ".pbf" not in tiles[0]:
        raise CheckError("openmaptiles TileJSON has no .pbf tile urls")
    return f"OpenFreeMap Positron ok (vector tiles: {tiles[0].split('/data/')[-1]})"


def check_basemap_offline_bundle() -> str:
    """The offline travel package (#29) rebuilds the basemap Style from a cached
    copy of the *style bundle*, because vector_map_tiles' StyleReader re-fetches
    style JSON + source TileJSON + sprite JSON + sprite PNG on every cold start
    and caches none of them — so without all four the map is blank offline no
    matter how many tiles were prefetched.

    Covers what core/basemap_style_cache.dart + TileCache.prefetchVectorTiles
    actually do, which the plain basemap check above does not:
      * every layer draws from a *vector* source (we only wire vector sources; a
        raster-sourced layer would trip VectorTileLayer's own assert),
      * the sprite bundle serves as JSON + PNG (icons vanish silently without it),
      * a real .pbf resolves through the {z}/{x}/{y} template the prefetcher
        builds by hand (it deliberately bypasses NetworkVectorTileProvider to
        reuse the app's connection-capped client).
    Soft: same reasoning as the basemap check — losing this degrades the map, it
    doesn't break travel data.
    """
    hdr = {"User-Agent": DBNAV_UA}
    style = _get("https://tiles.openfreemap.org/styles/positron",
                 headers=hdr, timeout=TIMEOUT)
    style.raise_for_status()
    s = style.json()

    sources = s.get("sources", {})
    vector_names = {n for n, v in sources.items() if v.get("type") == "vector"}
    layer_sources = {lyr["source"] for lyr in s.get("layers", []) if lyr.get("source")}
    non_vector = layer_sources - vector_names
    if non_vector:
        raise CheckError(
            f"positron layers now draw from non-vector source(s) {sorted(non_vector)} — "
            "basemap_style_cache.dart only wires vector sources")

    sprite = s.get("sprite")
    if not sprite:
        raise CheckError("positron style lost its sprite — map icons would vanish offline")
    sj = _get(f"{sprite}.json", headers=hdr, timeout=TIMEOUT)
    sj.raise_for_status()
    icons = sj.json()
    if not isinstance(icons, dict) or not icons:
        raise CheckError("sprite index is empty or not a JSON object")
    sp = _get(f"{sprite}.png", headers=hdr, timeout=TIMEOUT)
    sp.raise_for_status()
    if not sp.content.startswith(b"\x89PNG"):
        raise CheckError("sprite atlas is not a PNG")

    tj = _get(sources["openmaptiles"]["url"], headers=hdr, timeout=TIMEOUT)
    tj.raise_for_status()
    tj = tj.json()
    template = (tj.get("tiles") or [None])[0]
    if not template:
        raise CheckError("openmaptiles TileJSON has no tile template")
    for token in ("{z}", "{x}", "{y}"):
        if token not in template:
            raise CheckError(f"tile template lost {token} — prefetchVectorTiles "
                             "substitutes these by hand")
    # Berlin Hbf at z12 — the exact tile core/offline_package.dart's
    # tileForLatLng test pins, so the two stay in agreement.
    url = template.replace("{z}", "12").replace("{x}", "2200").replace("{y}", "1343")
    tile = _get(url, headers=hdr, timeout=TIMEOUT)
    tile.raise_for_status()
    if not tile.content:
        raise CheckError("z12 Berlin vector tile is empty")

    maxzoom = tj.get("maxzoom")
    if maxzoom is None or int(maxzoom) < 11:
        raise CheckError(f"openmaptiles maxzoom {maxzoom} < the offline corridor's z11")

    return (f"style bundle ok — {len(layer_sources)} vector source(s), sprite "
            f"{len(icons)} icons + {len(sp.content) // 1024} KB atlas, z12 Berlin "
            f"pbf {len(tile.content) // 1024} KB, maxzoom {maxzoom}")


def _app_user_agent() -> str:
    """The identifying User-Agent the app actually ships, read out of
    `AppConstants.userAgent` in the Dart source (not a copy of it) so this
    check exercises the real string and cannot drift from it."""
    src = (pathlib.Path(__file__).resolve().parent.parent
           / "flutter-app" / "lib" / "core" / "constants.dart").read_text()
    version = re.search(r"appVersion\s*=\s*'([^']+)'", src)
    ua = re.search(r"userAgent\s*=\n?\s*'(BesserBahn/[^']+)'", src)
    if not version or not ua:
        raise CheckError("cannot read AppConstants.appVersion/userAgent from "
                         "lib/core/constants.dart — did it get renamed?")
    return ua.group(1).replace("$appVersion", version.group(1))


def check_traewelling_user_agent() -> str:
    """Träwelling gates its entire surface — OAuth token exchange, refresh and
    the REST API alike — on an *identifiable* User-Agent, answering 403 "No
    identifiable User-Agent provided" without one. That is what broke the login
    in #34: the token exchange set no UA, so Dart sent its default
    `Dart/x (dart:io)`, which is rejected just like a missing one.

    Measured live against traewelling.de: no UA, `Dart/…`, `curl/…` and
    `python-requests/…` all 403 regardless of the route; our
    `BesserBahn/<version> (+<repo>)` gets past the gate — 200 on the public
    `/api/v1/statuses`, 401 on this auth-gated route. The tell is 403 vs 401:
    403 means "who are you", 401 means the UA was fine and only a token is
    missing.

    So this pins both directions:
      - a generic UA must still be refused (the requirement is real, and the
        `_isRejectedUa` shape our tests reproduce still matches reality), and
      - the UA the app actually ships must still be accepted (if Träwelling
        ever tightened the rule against us, the login would break again).

    Soft, like the check-in probe below: an optional third-party social feature,
    so traewelling.de being down must not fail the whole run.
    """
    url = "https://traewelling.de/api/v1/trains/station/autocomplete/Berlin"

    # Direction 1: a generic library UA is refused. (`requests` sends
    # `python-requests/x` by default — one of the UAs Träwelling blocks.)
    generic = _get(url, headers={"Accept": "application/json"}, timeout=TIMEOUT)
    if generic.status_code != 403:
        raise CheckError(
            "Träwelling no longer 403s a generic User-Agent "
            f"(status={generic.status_code}) — the UA rule changed; re-check "
            "the reproduction in test/traewelling_user_agent_test.dart")
    if "identifiable User-Agent" not in generic.text:
        raise CheckError(f"403 but not the UA rejection: {generic.text[:120]}")

    # Direction 2: the UA the app ships is accepted. This is the one that has
    # to keep working — everything else is diagnosis.
    ua = _app_user_agent()
    ours = _get(url, headers={"Accept": "application/json", "User-Agent": ua},
                timeout=TIMEOUT)
    if ours.status_code == 403:
        raise CheckError(
            f"Träwelling rejects the app's own User-Agent ({ua!r}): "
            f"{ours.text[:160]} — the Träwelling login is broken (#34)")
    if ours.status_code in (404, 410):
        raise CheckError(f"autocomplete path gone (status={ours.status_code})")
    if ours.status_code not in (200, 401):
        raise CheckError(f"unexpected status {ours.status_code}")

    return (f"UA rule holds: generic 403, {ua!r} → {ours.status_code}")


def check_traewelling_api() -> str:
    """Träwelling REST host the check-in flow rides on. The endpoints we call
    (station autocomplete, departures, trip, checkin) all require a Bearer token
    — without one a *live* endpoint answers 401, while a removed/renamed path is
    404/410. So we assert the autocomplete route still exists (status != 404),
    which confirms the path shape the app builds. Soft: optional social feature,
    and we can't exercise the authenticated body from CI.

    Sends the app's identifying User-Agent, because Träwelling 403s without one.
    This check used to tolerate 403 as "reachable" and send no UA — so it went
    green against the very rejection that made the login fail in #34. A 403 is
    now a failure here; `check_traewelling_user_agent` owns the UA rule."""
    url = "https://traewelling.de/api/v1/trains/station/autocomplete/Berlin"
    r = _get(url,
             headers={"Accept": "application/json",
                      "User-Agent": _app_user_agent()},
             timeout=TIMEOUT)
    if r.status_code in (404, 410):
        raise CheckError(f"autocomplete path gone (status={r.status_code})")
    if r.status_code == 403:
        raise CheckError(f"403 despite an identifying UA: {r.text[:160]}")
    if r.status_code not in (200, 401):
        raise CheckError(f"unexpected status {r.status_code}")
    return f"trains/station/autocomplete reachable (status={r.status_code})"


def check_db_account_token_endpoint() -> str:
    """DB account login rides DB's Keycloak realm `db`
    (`accounts.bahn.de/.../openid-connect/token`, public client `kf_mobile`,
    Authorization Code + PKCE). We can't exercise a real login from CI, but a
    *live* token endpoint rejects a bogus grant with 400/401, while a
    removed/renamed realm path answers 404. Assert it still exists and refuses
    bad input — that pins the realm + client shape the Profile login builds.
    Soft: auth-only feature, no credentials in CI."""
    url = ("https://accounts.bahn.de/auth/realms/db/protocol/"
           "openid-connect/token")
    r = _post(
        url,
        headers={"Accept": "application/json"},
        data={
            "grant_type": "refresh_token",
            "client_id": "kf_mobile",
            "refresh_token": "healthcheck-invalid",
        },
        timeout=TIMEOUT,
    )
    if r.status_code in (404, 410):
        raise CheckError(f"token path gone (status={r.status_code})")
    # A live realm rejects the bogus grant with an OAuth 4xx; some Keycloak
    # builds answer 500 to a malformed refresh token. Either way the realm +
    # client path exists, which is all this reachability probe asserts.
    if r.status_code not in (400, 401, 403, 500):
        raise CheckError(f"unexpected status {r.status_code}")
    # Keycloak returns an OAuth error JSON for a bad grant.
    try:
        err = r.json().get("error", "")
    except Exception:  # noqa: BLE001
        err = ""
    return f"realm db token endpoint live (status={r.status_code} {err})"


def check_db_account_endpoints_require_auth() -> str:
    """The Profile tab reads the signed-in user's data from the DB Navigator
    backend (`app.services-bahn.de/mob`): emobilebahncards, kundenkonten,
    bbStatus, reisenuebersicht, auftrag detail. All require a Bearer token, so
    unauthenticated a *live* path answers 401/403 while a gone path is 404. We
    probe `emobilebahncards` (no path params) to confirm the route + media
    type still exist. Soft: can't carry a real token in CI."""
    url = "https://app.services-bahn.de/mob/emobilebahncards"
    media = "application/x.db.vendo.mob.emobilebahncards.v2+json"
    r = _get(url, headers=_vendo_headers(media), timeout=TIMEOUT)
    if r.status_code in (404, 410):
        raise CheckError(f"emobilebahncards path gone (status={r.status_code})")
    if r.status_code not in (401, 403):
        # 200 would mean it stopped requiring auth (very unexpected) — flag it.
        raise CheckError(f"unexpected status {r.status_code} (expected 401/403)")

    # Saved-trips (POST/DELETE /mob/reisen) — the "merken" path the app pushes
    # local saves to when logged in. Unauthenticated it must answer 401/403.
    reisen_media = "application/x.db.vendo.mob.freiereisen.v5+json"
    r2 = _post(
        "https://app.services-bahn.de/mob/reisen",
        headers=_vendo_headers(reisen_media),
        data=b"{}",
        timeout=TIMEOUT,
    )
    if r2.status_code in (404, 410):
        raise CheckError(f"mob/reisen path gone (status={r2.status_code})")
    if r2.status_code not in (400, 401, 403):
        raise CheckError(f"mob/reisen unexpected status {r2.status_code}")
    return ("mob/emobilebahncards + mob/reisen reachable, auth-gated "
            f"(status={r.status_code}/{r2.status_code})")


def check_db_account_forced_refresh_shape() -> str:
    """Pull-to-refresh on the Profil tab fetches every account source *forced*:
    same request as always, minus the conditional `If-None-Match` (#31).

    Without that, the server answers 304 and the app re-serves the very cache
    the pull was meant to replace — which is how a changed address or BahnBonus
    balance stayed invisible until a logout/login.

    Both shapes must reach the auth gate (401/403). A 400/415 on either would
    mean the edge started policing the conditional header, and the app's refresh
    (or its DB-Navigator parity) needs rethinking. Auth-gated, so this proves
    the request shape is *accepted*, not what it returns. Soft: can't carry a
    real token in CI."""
    url = "https://app.services-bahn.de/mob/emobilebahncards"
    media = "application/x.db.vendo.mob.emobilebahncards.v2+json"
    # 429 counts as accepted: the per-client limiter sits *behind* the edge, so
    # being rate-limited proves the route and the request shape were fine. A
    # 429 is never evidence that the API changed (project_vendo_rate_limit).
    ok = (401, 403, 429)

    # Forced: exactly what a pull sends — no If-None-Match, call-trigger manual.
    forced_headers = _vendo_headers(media)
    forced_headers["call-trigger"] = "manual"
    forced = _get(url, headers=forced_headers, timeout=TIMEOUT)
    if forced.status_code not in ok:
        raise CheckError(
            f"forced refresh shape rejected (status={forced.status_code}, "
            "expected the 401/403 auth gate)")

    # Conditional: the background revalidation, which keeps sending the ETag.
    cond_headers = _vendo_headers(media)
    cond_headers["If-None-Match"] = 'W/"probe-not-a-real-etag"'
    cond_headers["call-trigger"] = "auto"
    cond = _get(url, headers=cond_headers, timeout=TIMEOUT)
    if cond.status_code not in ok:
        raise CheckError(
            f"conditional refresh shape rejected (status={cond.status_code}, "
            "expected the 401/403 auth gate)")

    return ("forced (no if-none-match) + conditional refresh shapes both "
            f"accepted, auth-gated (status={forced.status_code}/"
            f"{cond.status_code})")


def check_db_bahnbonus_co2() -> str:
    """The Statistik tab's official CO₂ balance comes from BahnBonus' own
    CO₂ service (`apis.deutschebahn.com/.../co2-service/v1/statistics`, #37),
    authorized with the separate BahnBonus OAuth client — not the DB-Navigator
    mob backend. We can't carry that token in CI, so we only prove the route
    still exists and is auth-gated: unauthenticated a live path answers
    401/403, a gone path 404/410. The response shape (periodOfTime/emissions,
    parsed by DbBahnBonusCo2Balance) can only be checked with a real token.
    Soft: auth-gated + upstream availability."""
    url = ("https://apis.deutschebahn.com/db/apis/bahnbonus/co2-service/v1"
           "/statistics")
    params = {"interval": "YEARLY",
              "startDate": "2026-01-01", "endDate": "2026-01-01"}
    r = _get(url, params=params, headers={"Accept": "application/json"},
             timeout=TIMEOUT)
    if r.status_code in (404, 410):
        raise CheckError(f"co2-service path gone (status={r.status_code})")
    if r.status_code not in (401, 403, 429):
        # 200 unauthenticated would mean it stopped requiring auth — flag it.
        raise CheckError(f"unexpected status {r.status_code} (expected 401/403)")
    return f"co2-service/v1/statistics reachable, auth-gated (status={r.status_code})"


def check_db_oauth_authorize_page() -> str:
    """The DB login page has to render for a request shaped like the browser
    the app actually opens (#35).

    Two things are checked together, because they only fail together in the
    real flow:

    1. The registered scheme redirect still yields Keycloak's login form.
    2. An RFC 8252 loopback redirect (`http://127.0.0.1:<port>`) does NOT.
       Keycloak itself accepts loopback for this client, so an API-shaped probe
       says "fine" — but DB's edge WAF rejects any browser-shaped request that
       carries an `http://` redirect_uri, with an F5 "support ID" page instead
       of the login form. That is why the app cannot escape DB Navigator's
       claim on `dbnav://` by moving to loopback. If this ever flips, the
       loopback flow becomes available and is worth revisiting.

    Sending browser headers is the whole point — probing with API-ish headers
    hides the WAF and reports a green that the app can't actually use.
    """
    auth = "https://accounts.bahn.de/auth/realms/db/protocol/openid-connect/auth"
    headers = {
        "User-Agent": (
            "Mozilla/5.0 (Linux; Android 11; SM-A705FN) AppleWebKit/537.36 "
            "(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36"
        ),
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        "Accept-Language": "de-DE,de;q=0.9",
    }

    def fetch(redirect_uri: str) -> str:
        r = _get(auth, params={
            "response_type": "code",
            "client_id": "kf_mobile",
            "state": "healthcheck",
            "nonce": "n" * 24,
            "code_challenge": "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",
            "code_challenge_method": "S256",
            "prompt": "login",
            "scope": "offline_access",
            "redirect_uri": redirect_uri,
        }, headers=headers, timeout=TIMEOUT)
        body = r.text.lower()
        if "support id" in body or "requested url was rejected" in body:
            return "waf"
        if "password" in body or "kc-form-login" in body:
            return "login"
        if r.status_code == 400 and "redirect_uri" in body:
            return "rejected"
        return f"unknown(status={r.status_code}, len={len(r.text)})"

    scheme = fetch("dbnav://dbnavigator.bahn.de/login/success")
    if scheme != "login":
        raise CheckError(
            f"DB login page no longer renders for the app's redirect ({scheme})"
        )

    loopback = fetch("http://127.0.0.1:42171/callback")
    if loopback == "login":
        return ("scheme redirect renders the login form; loopback now passes "
                "the WAF too (the dbnav:// app-chooser could be avoided, #35)")
    return f"scheme redirect renders the login form; loopback blocked ({loopback})"


# (name, callable, soft) — soft checks warn instead of fail.
CHECKS = [
    ("bahn.de web API blocked (reiseloesung)", check_bahn_web_api_blocked, True),
    ("vendo departures (bahnhofstafel)", check_vendo_departures, False),
    ("vendo arrivals (bahnhofstafel)", check_vendo_arrivals, False),
    ("vendo board semantics (gattung/cancel)", check_vendo_board_semantics, False),
    ("vendo train run (zuglauf halte)", check_vendo_zuglauf_detail, False),
    ("vendo platform change (gleis vs ezGleis)", check_vendo_platform_change, True),
    ("vendo zuglauf notes (Umleitung/Zusatzhalt)", check_vendo_zuglauf_notes, False),
    ("vendo location search", check_vendo_location, False),
    ("vendo nearby stations (bytypes)", check_vendo_nearby, False),
    ("mob endpoint surface reachable (67)", check_mob_surface, True),
    ("vendo journey + prices (v9)", check_vendo_journey, False),
    ("vendo split scope: leg vs zuglauf (#22)", check_vendo_split_scope, False),
    ("vendo earlier alight (#26)", check_vendo_earlier_alight, False),
    ("vendo verkehrsmittel filter (#18)", check_vendo_verkehrsmittel, False),
    ("vendo search options (#19)", check_vendo_search_options, False),
    ("vendo transfer info (#20.6)", check_vendo_transfer_info, False),
    ("vendo serviceDays (#20.8)", check_vendo_service_days, False),
    ("vendo tagesbestpreis (#21)", check_vendo_tagesbestpreis, False),
    ("stammdaten vs reisende.dart (#21)", check_vendo_stammdaten_drift, False),
    ("vendo walking route (#21)", check_vendo_calculateroute, False),
    ("vendo party search (pax/bike/dog/SBA)", check_vendo_journey_party, False),
    ("vendo journey pagination (context)", check_vendo_journey_pagination, False),
    ("vendo weitere abfahrten (segment)", check_vendo_weitere_abfahrten, False),
    ("vendo share journey (teilen vbid)", check_vendo_share, False),
    ("vendo train polyline (zuglauf)", check_vendo_train_polyline, False),
    ("vendo seat map (gsd free seats)", check_vendo_seat_map, False),
    ("wagenreihung wing-train split (RE)", check_wagenreihung_split, True),
    ("wagenreihung transfer sectors (#27)",
     check_wagenreihung_transfer_sectors, True),
    # Soft: both need the right train on the board right now (a delayed
    # long-distance run / an S-Bahn in a served network), so a quiet board is a
    # skip, not a broken API.
    ("wagenreihung time-vs-date key (#32)", check_wagenreihung_time_key, True),
    ("wagenreihung S-Bahn served (#33)", check_wagenreihung_sbahn, True),
    ("osm platform geometry (overpass)", check_osm_platform_geometry, False),
    ("basemap (OpenFreeMap Positron vector)", check_basemap_tiles, True),
    ("basemap offline style bundle (#29)", check_basemap_offline_bundle, True),
    ("bahnhof.de station map (karte)", check_bahnhof_map, False),
    ("map bay ↔ departures link", check_bay_departure_link, True),
    ("map Gleis ↔ departures (normalised)", check_gleis_departure_link, False),
    ("bahnhof.de sitemap", check_bahnhof_sitemap, False),
    ("traewelling UA requirement (#34)", check_traewelling_user_agent, True),
    ("traewelling check-in API", check_traewelling_api, True),
    ("DB OAuth authorize page (#35)", check_db_oauth_authorize_page, False),
    ("DB account token endpoint (kf_mobile)", check_db_account_token_endpoint, True),
    ("DB account mob endpoints (auth-gated)", check_db_account_endpoints_require_auth, True),
    ("DB account forced refresh shape (#31)", check_db_account_forced_refresh_shape, True),
    ("DB BahnBonus CO₂ service (#37)", check_db_bahnbonus_co2, True),
    ("HAFAS rest mirror (flaky)", check_hafas_rest, True),
    ("website journey blocked check", check_website_journey_still_blocked, True),
]


# --------------------------------------------------------------------------
# pytest entrypoints (one test per non-soft check)
# --------------------------------------------------------------------------
def _make_pytest(fn):
    def _t():
        fn()
    return _t


for _name, _fn, _soft in CHECKS:
    if not _soft:
        globals()[f"test_{_fn.__name__}"] = _make_pytest(_fn)


# --------------------------------------------------------------------------
# Standalone runner
# --------------------------------------------------------------------------
def main() -> int:
    print(f"Besser-Bahn API health check — {datetime.now(timezone.utc):%Y-%m-%d %H:%M UTC}\n")
    failures = 0
    for name, fn, soft in CHECKS:
        t0 = time.monotonic()
        try:
            detail = fn()
            ms = int((time.monotonic() - t0) * 1000)
            print(f"  ✅ {name:36} {ms:>5}ms  {detail}")
        except _SkipCheck as e:
            # An optional dep is missing — the endpoint wasn't probed at all.
            # Never counts as a failure: it says nothing about the API.
            ms = int((time.monotonic() - t0) * 1000)
            print(f"  ⏭️ SKIP {name:36} {ms:>5}ms  {e}")
        except Exception as e:  # noqa: BLE001 - report everything
            ms = int((time.monotonic() - t0) * 1000)
            tag = "⚠️ WARN" if soft else "❌ FAIL"
            print(f"  {tag} {name:36} {ms:>5}ms  {type(e).__name__}: {e}")
            if not soft:
                failures += 1
    print()
    if failures:
        print(f"{failures} hard check(s) FAILED — an API likely changed.")
        return 1
    print("All hard checks passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
