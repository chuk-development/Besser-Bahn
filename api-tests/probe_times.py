"""Throwaway probe: do any fahrt halte carry echtzeit WITHOUT sollzeit?
That would make our timeline drop the time (we key the spine on sollzeit)."""
import requests, uuid

H = {
    "User-Agent": "Mozilla/5.0 (Linux; Android 14) Mobile Safari/537.36",
    "Accept": "application/json", "Accept-Language": "de-DE,de;q=0.9",
}
B = "https://www.bahn.de/web/api/reiseloesung"


def orte(q):
    r = requests.get(f"{B}/orte", params={"suchbegriff": q, "typ": "ALL", "limit": 3}, headers=H, timeout=20)
    return r.json()[0]


def main():
    for stop in ["Hannover Hbf", "Bremen Hbf"]:
        o = orte(stop)
        eva = o.get("extId") or o["id"]
        dep = requests.get(f"{B}/abfahrten", params={"ortExtId": eva, "mitVias": "true", "maxVias": "8"},
                           headers=H, timeout=20).json()
        entries = dep.get("entries", dep) if isinstance(dep, dict) else dep
        print(f"\n=== {stop} ({eva}) — {len(entries)} departures ===")
        checked = 0
        for e in entries:
            jid = e.get("journeyId")
            if not jid:
                continue
            f = requests.get(f"{B}/fahrt", params={"journeyId": jid}, headers=H, timeout=20).json()
            halte = f.get("halte", [])
            line = (halte[0].get("kategorie", "?") + " " + str(halte[0].get("nummer", ""))) if halte else "?"
            miss_soll = miss_both = 0
            for h in halte:
                for key in ("ankunft", "abfahrt"):
                    t = h.get(key)
                    if not isinstance(t, dict):
                        continue
                    soll, echt = t.get("sollzeit"), t.get("echtzeit")
                    if echt and not soll:
                        miss_soll += 1
                    if not echt and not soll:
                        miss_both += 1
            print(f"  {line:<10} halte={len(halte):>2}  echtzeit_without_sollzeit={miss_soll}  no_time_at_all={miss_both}")
            checked += 1
            if checked >= 5:
                break


if __name__ == "__main__":
    main()
