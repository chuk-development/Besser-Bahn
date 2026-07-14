#!/usr/bin/env python3
"""
Besser-Bahn API health check.

Probes every upstream endpoint the app depends on and asserts the response
still has the shape we parse. Run it to find out *fast* when Deutsche Bahn
changes or removes an endpoint.

Two ways to run:
    python3 healthcheck.py            # human-readable table, exit 1 on failure
    pytest healthcheck.py             # CI / assertion mode

Zero hard deps beyond `requests`.

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

import json
import math
import re
import sys
import time
import urllib.parse
import uuid
from datetime import datetime, timedelta, timezone

import requests

TIMEOUT = 20
DBNAV_UA = "DBNavigator/Android/26.9.0"

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


def _corr_id() -> str:
    return f"{uuid.uuid4()}_{uuid.uuid4()}"


def _browser_headers() -> dict:
    return {
        "User-Agent": ("Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 "
                       "(KHTML, like Gecko) Chrome/125.0.0.0 Mobile Safari/537.36"),
        "Accept": "application/json",
        "Accept-Language": "de-DE,de;q=0.9",
    }


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
    r = requests.post(
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
    r = requests.get(
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
    r = requests.get(
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
    r = requests.post(
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
    r = requests.post(
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
    r = requests.post(
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
    r = requests.post(
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
    sr = requests.post(
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
    r = requests.post(
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
    base = requests.post(url, headers=_vendo_headers(media),
                         data=json.dumps(body()), timeout=TIMEOUT)
    base.raise_for_status()
    bd = base.json()
    tok = bd.get("frueherContext")
    if not tok:
        raise CheckError("no frueherContext token in journey response")
    earlier = requests.post(url, headers=_vendo_headers(media),
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
    r = requests.post(
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

    r = requests.get(
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
    r = requests.get("https://www.bahnhof.de/hamburg-hbf/karte",
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
    h = requests.get("https://www.bahnhof.de/hamburg-hbf/karte",
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

    karte = requests.get("https://www.bahnhof.de/kiel-hbf/karte",
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

    karte = requests.get("https://www.bahnhof.de/hamburg-hbf/karte",
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
    r = requests.get("https://www.bahnhof.de/sitemap.xml",
                     headers=_browser_headers(), timeout=TIMEOUT)
    r.raise_for_status()
    count = r.text.count("<loc>https://www.bahnhof.de/")
    if count < 4000:
        raise CheckError(f"sitemap only has {count} urls (expected >4000)")
    return f"{count} sitemap urls"


def check_hafas_rest() -> str:
    """Community HAFAS mirror — flaky, treated as a soft/degraded check."""
    r = requests.get("https://v6.db.transport.rest/locations",
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
    r = requests.post("https://www.bahn.de/web/api/angebote/fahrplan",
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
    r = requests.post("https://app.services-bahn.de/mob/angebote/fahrplan",
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
        resp = requests.get(url, headers={"User-Agent": DBNAV_UA}, timeout=TIMEOUT)
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
    w = requests.get(
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
    r = requests.post(
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
    rr = requests.get(
        "https://www.bahn.de/web/api/reisebegleitung/wagenreihung/vehicle-sequence",
        params={
            "administrationId": "80", "category": leg["kurztext"],
            "date": f"{dep.year}-{dep.month:02d}-{dep.day:02d}",
            "evaNumber": eva, "number": leg["zugNummer"],
            "time": dep.astimezone(timezone.utc).isoformat().replace(
                "+00:00", "Z"),
        }, headers=_browser_headers(), timeout=TIMEOUT)
    rr.raise_for_status()
    seq = rr.json()
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
            r = requests.post(endpoint, data={"data": ql},
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
    style = requests.get("https://tiles.openfreemap.org/styles/positron",
                         headers=hdr, timeout=TIMEOUT)
    style.raise_for_status()
    src = style.json().get("sources", {}).get("openmaptiles", {})
    src_url = src.get("url")
    if not src_url and not src.get("tiles"):
        raise CheckError("positron style lost its openmaptiles vector source")
    # Resolve the source TileJSON → it must advertise pbf tile URLs.
    tj = requests.get(src_url, headers=hdr, timeout=TIMEOUT)
    tj.raise_for_status()
    tiles = tj.json().get("tiles") or []
    if not tiles or ".pbf" not in tiles[0]:
        raise CheckError("openmaptiles TileJSON has no .pbf tile urls")
    return f"OpenFreeMap Positron ok (vector tiles: {tiles[0].split('/data/')[-1]})"


def check_traewelling_api() -> str:
    """Träwelling REST host the check-in flow rides on. The endpoints we call
    (station autocomplete, departures, trip, checkin) all require a Bearer token
    — without one a *live* endpoint answers 401, while a removed/renamed path is
    404/410. So we assert the autocomplete route still exists (status != 404),
    which confirms the path shape the app builds. Soft: optional social feature,
    and we can't exercise the authenticated body from CI."""
    url = "https://traewelling.de/api/v1/trains/station/autocomplete/Berlin"
    r = requests.get(url, headers={"Accept": "application/json"}, timeout=TIMEOUT)
    if r.status_code in (404, 410):
        raise CheckError(f"autocomplete path gone (status={r.status_code})")
    if r.status_code not in (200, 401, 403):
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
    r = requests.post(
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
    r = requests.get(url, headers=_vendo_headers(media), timeout=TIMEOUT)
    if r.status_code in (404, 410):
        raise CheckError(f"emobilebahncards path gone (status={r.status_code})")
    if r.status_code not in (401, 403):
        # 200 would mean it stopped requiring auth (very unexpected) — flag it.
        raise CheckError(f"unexpected status {r.status_code} (expected 401/403)")

    # Saved-trips (POST/DELETE /mob/reisen) — the "merken" path the app pushes
    # local saves to when logged in. Unauthenticated it must answer 401/403.
    reisen_media = "application/x.db.vendo.mob.freiereisen.v5+json"
    r2 = requests.post(
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


# (name, callable, soft) — soft checks warn instead of fail.
CHECKS = [
    ("bahn.de web API blocked (reiseloesung)", check_bahn_web_api_blocked, True),
    ("vendo departures (bahnhofstafel)", check_vendo_departures, False),
    ("vendo arrivals (bahnhofstafel)", check_vendo_arrivals, False),
    ("vendo train run (zuglauf halte)", check_vendo_zuglauf_detail, False),
    ("vendo platform change (gleis vs ezGleis)", check_vendo_platform_change, True),
    ("vendo location search", check_vendo_location, False),
    ("vendo nearby stations (bytypes)", check_vendo_nearby, False),
    ("mob endpoint surface reachable (67)", check_mob_surface, True),
    ("vendo journey + prices (v9)", check_vendo_journey, False),
    ("vendo party search (pax/bike/dog/SBA)", check_vendo_journey_party, False),
    ("vendo journey pagination (context)", check_vendo_journey_pagination, False),
    ("vendo weitere abfahrten (segment)", check_vendo_weitere_abfahrten, False),
    ("vendo share journey (teilen vbid)", check_vendo_share, False),
    ("vendo train polyline (zuglauf)", check_vendo_train_polyline, False),
    ("vendo seat map (gsd free seats)", check_vendo_seat_map, False),
    ("wagenreihung wing-train split (RE)", check_wagenreihung_split, True),
    ("osm platform geometry (overpass)", check_osm_platform_geometry, False),
    ("basemap (OpenFreeMap Positron vector)", check_basemap_tiles, True),
    ("bahnhof.de station map (karte)", check_bahnhof_map, False),
    ("map bay ↔ departures link", check_bay_departure_link, True),
    ("map Gleis ↔ departures (normalised)", check_gleis_departure_link, False),
    ("bahnhof.de sitemap", check_bahnhof_sitemap, False),
    ("traewelling check-in API", check_traewelling_api, True),
    ("DB account token endpoint (kf_mobile)", check_db_account_token_endpoint, True),
    ("DB account mob endpoints (auth-gated)", check_db_account_endpoints_require_auth, True),
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
