"""Throwaway probe: simulate, with REAL data, what the connection-detail
timeline renders per stop for a Kiel<->Berlin journey — to find where an/ab
times go blank. Mirrors the app:
  Vendo verbindungssuche -> leg.zuglaufId -> bahn.de fahrt -> Stopover times.
For each leg we resolve board/alight and print, per stop, the spine time we'd
show and whether the 'an X / ab Y' detail renders (our showAnAb gate)."""
import json
import uuid
from datetime import datetime

import requests

TIMEOUT = 20
DBNAV_UA = "DBNavigator/Android/26.9.0"
KIEL_LOC = "A=1@O=Kiel Hbf@X=10131976@Y=54314982@U=80@L=8000199@B=1@p=0@"
BERLIN_LOC = "A=1@O=Berlin Hbf@X=13369549@Y=52525589@U=80@L=8011160@B=1@p=0@"


def vh(media):
    return {"Accept": media, "Content-Type": media, "Accept-Language": "de",
            "User-Agent": DBNAV_UA, "X-App-Version": "26.9.0",
            "X-Correlation-ID": f"{uuid.uuid4()}_{uuid.uuid4()}"}


def bh():
    return {"User-Agent": "Mozilla/5.0 (Linux; Android 14) Mobile Safari/537.36",
            "Accept": "application/json", "Accept-Language": "de-DE,de;q=0.9"}


def hhmm(s):
    if not s:
        return None
    try:
        return datetime.fromisoformat(s).strftime("%H:%M")
    except ValueError:
        return s[11:16] if len(s) >= 16 else s


def journey(src, dst):
    media = "application/x.db.vendo.mob.verbindungssuche.v9+json"
    body = {
        "autonomeReservierung": False, "einstiegsTypList": ["STANDARD"],
        "fahrverguenstigungen": {"deutschlandTicketVorhanden": False,
                                 "nurDeutschlandTicketVerbindungen": False},
        "klasse": "KLASSE_2",
        "reiseHin": {"wunsch": {
            "abgangsLocationId": src, "alternativeHalteBerechnung": True,
            "verkehrsmittel": ["ALL"],
            "zeitWunsch": {"reiseDatum": datetime.now().astimezone().isoformat(),
                           "zeitPunktArt": "ABFAHRT"},
            "zielLocationId": dst}},
        "reisendenProfil": {"reisende": [{"ermaessigungen": ["KEINE_ERMAESSIGUNG KLASSENLOS"],
                                          "reisendenTyp": "ERWACHSENER"}]},
        "reservierungsKontingenteVorhanden": False}
    r = requests.post("https://app.services-bahn.de/mob/angebote/fahrplan",
                      headers=vh(media), data=json.dumps(body), timeout=TIMEOUT)
    r.raise_for_status()
    return r.json().get("verbindungen", [])


def fahrt(jid):
    r = requests.get("https://www.bahn.de/web/api/reiseloesung/fahrt",
                     params={"journeyId": jid}, headers=bh(), timeout=TIMEOUT)
    if r.status_code != 200:
        return None
    return r.json()


def main():
    conns = journey(KIEL_LOC, BERLIN_LOC)
    print(f"{len(conns)} journeys")
    c = conns[0]
    legs = c["verbindung"]["verbindungsAbschnitte"]
    for li, leg in enumerate(legs):
        typ = leg.get("verkehrsmittel", {}).get("kurzText") or leg.get("typ")
        zid = leg.get("zuglaufId") or leg.get("risZuglaufId")
        board = leg.get("abgangsOrt", {}).get("name")
        alight = leg.get("ankunftsOrt", {}).get("name")
        print(f"\n--- leg {li}: {typ}  {board} -> {alight}  zuglaufId={'yes' if zid else 'NONE'}")
        if not zid:
            print("    (Fussweg/no train run)")
            continue
        f = fahrt(zid)
        if not f:
            print("    !! bahn.de fahrt FAILED for this zuglaufId -> app would have NO timeline")
            continue
        halte = f.get("halte", [])
        names = [h.get("name") for h in halte]
        bi = names.index(board) if board in names else 0
        ai = names.index(alight) if alight in names else len(halte) - 1
        for i, h in enumerate(halte):
            an, ab = h.get("ankunft") or {}, h.get("abfahrt") or {}
            psoll, pdep = hhmm(an.get("sollzeit")), hhmm(ab.get("sollzeit"))
            spine = pdep or psoll  # what _spineTime shows (plannedDeparture ?? plannedArrival)
            show_anab = bool(psoll and pdep and psoll != pdep)
            tag = "BOARD" if i == bi else ("ALIGHT" if i == ai else ("·" if bi < i < ai else " "))
            spine_txt = spine or "—— BLANK ——"
            anab = f"an {psoll} / ab {pdep}" if show_anab else "(no an/ab detail)"
            print(f"    [{tag:^6}] {h.get('name','?'):<28} spine={spine_txt:<9}  {anab}")


if __name__ == "__main__":
    main()
