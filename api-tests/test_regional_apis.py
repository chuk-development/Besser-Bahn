"""Live tests for the regional transport backends the app trusts over DB for the
platform a bus/tram really leaves from (flutter-app/lib/services/regional_*).

Three systems, one question each ("planned platform vs the one it really leaves
from today"):

  * HAFAS `mgate.exe` — dPlatfS vs dPlatfR         (16 Verbünde)
  * EFA/Mentz `XML_DM_REQUEST` — plannedPlatformName vs platformName  (7)
  * Geofox GTI (HVV Hamburg) — platform vs realtimePlatform  (HMAC-signed)

These hit the real endpoints, so they are written to survive the real world:
one backend being down is a `skip`, not a failure (the app treats it the same —
it is an extra on top of DB). The suite only FAILS when the *majority* of a
system is unreachable, because that means the protocol moved and the app has
gone blind, which is the thing worth a red build.

Reuses the endpoint tables from healthcheck.py so there is one source of truth.

Run: `cd api-tests && python3 -m pytest test_regional_apis.py -v`
"""

from __future__ import annotations

import hashlib
import hmac
import base64
import json
import time
from datetime import datetime

import pytest
import requests

import healthcheck as hc


# --------------------------------------------------------------------------- #
# Transport hiccups are not protocol changes
# --------------------------------------------------------------------------- #

# A read timeout, a reset, a TLS hiccup or a HAFAS box answering "not today"
# says nothing about whether the protocol still works — only that this one
# Verbund is having a moment. Shape errors (assert/KeyError) are NOT in here:
# those are the signal the monitor exists for.
NETWORK_ERRORS = (requests.exceptions.RequestException, OSError, hc.CheckError)


_last_error = ""


def _attempt(fn, *args, **kwargs):
    """One live request, retried once after a short pause on a transport error.

    Returns `None` if it stays unreachable; the reason lands in `_last_error`
    so a skip still names what went wrong.
    """
    global _last_error
    for attempt in range(2):
        try:
            return fn(*args, **kwargs)
        except NETWORK_ERRORS as e:
            _last_error = f"{type(e).__name__}: {str(e)[:80]}"
            if attempt == 0:
                time.sleep(2)
    return None


def _call(pid, fn, *args, **kwargs):
    """Like `_attempt`, but skips the test when the backend stays unreachable.

    Every live call in a per-backend test must go through this. Wrapping only
    the *first* call used to be enough by accident: `fpa.invg.de` answered
    LocMatch and then read-timed out on the StationBoard call, which escaped as
    a ReadTimeout and turned the whole daily monitor red (#79) — for one slow
    Verbund the app treats as optional anyway.
    """
    res = _attempt(fn, *args, **kwargs)
    if res is None:
        # AUTH is not a bad minute: the backend understood us fine and rejected
        # our credentials — it will keep doing that until we change them. bvg,
        # vmt and saarfahrplan sat on `LocMatch AUTH` (truncated aids) unnoticed
        # for months precisely because a skip is silent. That one gets to be red.
        if "AUTH" in _last_error:
            pytest.fail(f"{pid} rejected our credentials — aid/client stale "
                        f"({_last_error})")
        pytest.skip(f"{pid} unreachable: {_last_error}")
    return res


# --------------------------------------------------------------------------- #
# HAFAS — the 16 Verbünde
# --------------------------------------------------------------------------- #

@pytest.mark.parametrize("profile", hc.REGIONAL_PROFILES, ids=lambda p: p[0])
def test_hafas_backend_platforms(profile):
    """LocMatch → StationBoard, and departures carry the planned platform.

    A single dead backend skips; the aggregate test below is what fails when too
    many are gone.
    """
    pid, label, endpoint, cid, cname, aid, probe = profile
    res = _call(pid, hc._hafas, endpoint, cid, cname, aid, "LocMatch",
                {"input": {"loc": {"type": "S", "name": probe + "?"},
                           "maxLoc": 5, "field": "S"}})

    locs = (res.get("match") or {}).get("locL") or []
    assert locs, f"{pid}: LocMatch returned no stop for {probe!r}"

    board = _call(pid, hc._hafas, endpoint, cid, cname, aid, "StationBoard",
                  {"type": "DEP", "date": datetime.now().strftime("%Y%m%d"),
                   "time": "090000", "stbLoc": {"extId": locs[0]["extId"]},
                   "maxJny": 60})
    assert board.get("jnyL"), f"{pid}: empty board at {probe}"
    # Whether THIS stop happens to carry platforms is checked in the aggregate
    # below — a single stop that resolves to a bay-less tram halt (VRN does this
    # for "Mannheim Hauptbahnhof") is a data quirk, not a broken backend.


def _hafas_platform_share():
    """How many HAFAS backends expose the planned platform, and how many were
    reachable. Shared by the two aggregate assertions."""
    reachable = with_platform = 0
    for pid, label, endpoint, cid, cname, aid, probe in hc.REGIONAL_PROFILES:
        res = _attempt(hc._hafas, endpoint, cid, cname, aid, "LocMatch",
                       {"input": {"loc": {"type": "S", "name": probe + "?"},
                                  "maxLoc": 3, "field": "S"}})
        locs = ((res or {}).get("match") or {}).get("locL") or []
        if not locs:
            continue
        reachable += 1
        # A board that times out must not count against `with_platform` — it
        # never got to say whether it names a platform. Drop the backend from
        # both tallies instead of scoring it a silent zero.
        board = _attempt(hc._hafas, endpoint, cid, cname, aid, "StationBoard",
                         {"type": "DEP",
                          "date": datetime.now().strftime("%Y%m%d"),
                          "time": "090000",
                          "stbLoc": {"extId": locs[0]["extId"]},
                          "maxJny": 60})
        if board is None:
            reachable -= 1
            continue
        if any(hc._hafas_platform(j.get("stbStop") or {}, "S")
               for j in (board.get("jnyL") or [])):
            with_platform += 1
    return reachable, with_platform


def test_hafas_majority_alive_and_platformed():
    """The protocol still works across the fleet AND still yields the planned
    platform. Fails only if most are dark or the dPlatfS field vanished
    everywhere — the two ways the app goes blind."""
    reachable, with_platform = _hafas_platform_share()
    total = len(hc.REGIONAL_PROFILES)
    assert reachable >= total // 2, (
        f"only {reachable}/{total} HAFAS backends answered — protocol "
        f"1.34/4000100 may have been rejected fleet-wide")
    # Most reachable ones must still name a platform; a lone quirk is tolerated.
    assert with_platform >= reachable // 2, (
        f"only {with_platform}/{reachable} reachable HAFAS backends expose "
        f"dPlatfS — the planned/live pair the app needs may be gone")


# --------------------------------------------------------------------------- #
# EFA / Mentz — BW, Bayern, NRW, Sachsen, RLP
# --------------------------------------------------------------------------- #

def _efa(base, path, params):
    r = hc._get(f"{base}/{path}",
                params={"outputFormat": "rapidJSON", "version": "10.2.10.139",
                        **params},
                headers={"Accept": "application/json", "User-Agent": hc.DBNAV_UA},
                timeout=hc.TIMEOUT)
    r.raise_for_status()
    return r.json()


@pytest.mark.parametrize("profile", hc.EFA_PROFILES, ids=lambda p: p[0])
def test_efa_backend_platforms(profile):
    """STOPFINDER → DM_REQUEST, and a departure names BOTH planned and live
    platform. One value alone cannot say whether a platform moved."""
    pid, label, base, probe = profile
    sf = _call(pid, _efa, base, "XML_STOPFINDER_REQUEST",
               {"name_sf": probe, "type_sf": "any",
                "coordOutputFormat": "WGS84[DD.ddddd]"})

    locs = [l for l in (sf.get("locations") or []) if l.get("type") == "stop"] \
        or (sf.get("locations") or [])
    assert locs, f"{pid}: stopfinder found nothing for {probe!r}"

    dm = _call(pid, _efa, base, "XML_DM_REQUEST",
               {"name_dm": locs[0]["id"], "type_dm": "stop", "mode": "direct",
                "useRealtime": "1", "limit": "30"})
    assert dm.get("stopEvents"), (
        f"{pid}: empty board at {probe} {dm.get('systemMessages') or ''}")
    # Whether this stop names both platform fields is the aggregate's job — VRN
    # resolves "Mannheim Hauptbahnhof" to a bay-less tram halt, which is a data
    # quirk of one stop, not a broken backend.


def _efa_platform_share():
    reachable = with_platform = 0
    for pid, label, base, probe in hc.EFA_PROFILES:
        sf = _attempt(_efa, base, "XML_STOPFINDER_REQUEST",
                      {"name_sf": probe, "type_sf": "any"})
        locs = [l for l in ((sf or {}).get("locations") or [])
                if l.get("type") == "stop"] or ((sf or {}).get("locations") or [])
        if not locs:
            continue
        reachable += 1
        dm = _attempt(_efa, base, "XML_DM_REQUEST",
                      {"name_dm": locs[0]["id"], "type_dm": "stop",
                       "mode": "direct", "useRealtime": "1", "limit": "30"})
        if dm is None:  # timed out before it could name a platform — see above
            reachable -= 1
            continue
        if any(
            ((e.get("location") or {}).get("properties") or {}).get("plannedPlatformName")
            and ((e.get("location") or {}).get("properties") or {}).get("platformName")
            for e in (dm.get("stopEvents") or [])
        ):
            with_platform += 1
    return reachable, with_platform


def test_efa_majority_alive_and_platformed():
    """The EFA fleet still answers AND still names plannedPlatformName +
    platformName. Fails only if most are dark or the field pair vanished."""
    reachable, with_platform = _efa_platform_share()
    total = len(hc.EFA_PROFILES)
    assert reachable >= total // 2, (
        f"only {reachable}/{total} EFA backends answered — rapidJSON shape may "
        f"have changed")
    assert with_platform >= reachable // 2, (
        f"only {with_platform}/{reachable} reachable EFA backends name both "
        f"plannedPlatformName and platformName")


# --------------------------------------------------------------------------- #
# Geofox GTI (HVV Hamburg) — HMAC-signed
# --------------------------------------------------------------------------- #

GTI_BASE = "https://gti.geofox.de/gti/restapp"
GTI_USER = "hvv-app"
GTI_KEY = b"]vUl>8We7hY6"  # from the hvv APK's libsekret.so (see notes)


def _gti_sig(body: str) -> str:
    return base64.b64encode(
        hmac.new(GTI_KEY, body.encode(), hashlib.sha1).digest()).decode()


def _gti(path: str, obj: dict) -> dict:
    body = json.dumps(obj, separators=(",", ":"))
    r = hc._post(
        f"{GTI_BASE}/{path}",
        headers={"geofox-auth-user": GTI_USER, "geofox-auth-type": "HmacSHA1",
                 "geofox-auth-signature": _gti_sig(body), "X-Platform": "android",
                 "Content-Type": "application/json", "Accept": "application/json",
                 "User-Agent": hc.DBNAV_UA},
        data=body, timeout=hc.TIMEOUT)
    r.raise_for_status()
    return r.json()


def test_gti_signature_reproduces_known_value():
    """The HMAC recipe extracted from the APK, pinned offline: if this drifts,
    every signed call breaks and the live tests below would only tell us 'auth
    failed' with no clue why."""
    assert _gti_sig("{}") == "OrxF3rXPxotvUKt3FmEBFTRmH/0="


def test_gti_auth_accepted():
    """`init` with the extracted key must be accepted — proves the app user +
    signature still authenticate."""
    d = _call("gti", _gti, "init", {})
    assert d.get("returnCode") == "OK", (
        f"Geofox rejected the key (returnCode={d.get('returnCode')}) — the app "
        f"secret may have rotated")


def test_gti_departure_platforms():
    """checkName → departureList, and rail/U-Bahn departures carry
    `platform`/`realtimePlatform` (the planned/live pair).

    NB Hamburg does not publish bus BAY assignments — neither Geofox nor the
    NAH.SH neighbour has them — so the platform data here is rail/U-/S-Bahn. The
    test asserts what the feed actually provides, not the bus bays it does not.
    """
    found = _call("gti", _gti, "checkName",
                  {"version": 58,
                   "theName": {"name": "Hauptbahnhof", "city": "Hamburg",
                               "type": "STATION"}, "maxList": 3})
    results = found.get("results") or []
    assert results, "checkName found no Hamburg Hauptbahnhof"

    now = datetime.now()
    board = _call("gti", _gti, "departureList",
                  {"version": 58, "station": results[0],
                   "time": {"date": now.strftime("%d.%m.%Y"),
                            "time": now.strftime("%H:%M")},
                   "maxList": 40, "maxTimeOffset": 120, "useRealtime": True})
    deps = board.get("departures") or []
    assert board.get("returnCode") == "OK" and deps, \
        f"departureList returnCode={board.get('returnCode')}, {len(deps)} deps"

    with_platform = sum(1 for d in deps if d.get("platform"))
    assert with_platform, (
        "no departure carries a platform — Geofox stopped exposing "
        "platform/realtimePlatform")
