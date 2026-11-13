# Besser Bahn

*Read this in another language: [Deutsch](README.md) · **English***

**The better Deutsche Bahn app. Privacy-first, for frequent travellers.**

A premium companion for Deutsche Bahn: connection search, live departures, train
runs on the map, delay and connection prediction, Träwelling check-ins, and
cheaper split-ticket options — all with no tracking, no ads, and no forced
account.

You can also connect your **own DB account**. Your **tickets (with the barcode
to show), BahnCard, and BahnBonus** then sit directly in the app.

<p align="center">
  <img src="assets/app_icon.png" width="100" />
</p>

## Features

### 🔎 Search
- Connection search between two stations, with station auto-complete
- Also accepts **coordinates or map links** as start/destination (`53.43, 14.53`,
  `geo:`, OpenStreetMap, Organic Maps, and Google Maps links) → nearby stops
- Full connection details: every transfer, platform, stop, and live delay
- **Connection and punctuality badges** for each transfer, computed by a
  self-hosted prediction model
- Sorting by **reliability** — not only by duration, but by how likely the trip
  really works out
- **⚡ Fastest · 💶 Cheapest · 🛡️ Safest · ⭐ Best compromise** are marked in the
  result list (only when they actually differ)

### 🔔 Live trip companion
Switch it on or off per trip ("Watch trip" in the connection view), with the app
in the foreground and reminders enabled:
- Push alerts for a **delay jump, a platform change at your stop, a cancelled
  train**, and an **endangered connection**
- **Connection rescue**: for a tight transfer, the app shows the next
  *reachable* train automatically (computed from the live arrival of the
  incoming train), with a one-tap "Switch" — including the cost if you miss the
  connection ("1:05 h later at the destination")
- **Arrival alarm** and an optional GPS exit alarm
- **Transfer profile** (Fast · Normal · Luggage · Child · Bike · Low-barrier ·
  More time): "8 minutes to change" is not judged the same for everyone. It
  changes only the warning threshold, not the timetable times. It stays on the
  device.
- A **diversion or changed train run** is marked as such, with added stops and
  cancelled stops
- Runs only on the device: no server reads your trip

### 🚉 Station
One combined tab with an internal switch between:
- **Train** – the run of a single service, with every stop, platform, and delay
- **Departures** – the live departure board of a station, with a map view
- **Map** – an interactive station map (platforms, lifts, points of interest)

### 🧭 Maps and live data
- Route run as the exact track polyline that DB draws itself
- A neutral German basemap background (BKG TopPlus-Open, grey)
- An offline tile cache on the device
- **Coach order and free seats** – seat map and coach sequence per train
- **Wing-train detection** – shows which portion of the train to board
- "My location" and nearby stations by GPS

### 💶 Split ticket
- Finds cheaper ticket combinations for a connection you found
- Accounts for the **BahnCard** (25/50, 1st/2nd class) and the **Deutschland-Ticket**
- Direct booking links for each part-ticket (the top offer is the correct one)
- An OS notification when the analysis is done

### 👤 DB account (optional)
You can connect your own DB account. The app then speaks the same backend as the
DB Navigator:
- **My tickets** – booked tickets, with the **barcode to show** at a check
- **BahnCard** – card view and inspection view, available offline
- **BahnBonus** – points and status
- **Saved trips** sync with "My trips" in the DB account
- Login by OAuth2 (PKCE, no password in the app). It is fully optional. Without
  an account, everything else works the same.

### 🤝 Träwelling
- Login by OAuth2 (PKCE, no password in the app)
- Per-leg check-in directly from the connection view
- Auto check-in: one tap on the Träwelling icon in a train checks you in
- Feed and friends, with an adjustable default visibility

### 📚 Trips
- A local library: favourites, recent searches, saved routes, and saved trains
- Frequent searches are marked as a favourite automatically

### 🔗 Share
- Official "Share trip": creates a real DB booking link for exactly this
  connection (not just a search)

## Privacy

- **No tracking, no Firebase, no Google Analytics, no ads**
- Searches, favourites, and tokens stay on the device
- The prediction backend runs on servers in Germany (Hetzner, GDPR-compliant)
- See [PRIVACY-POLICY.md](PRIVACY-POLICY.md)

## Install

### Android
Go to the [Releases page](https://github.com/chukfinley/Besser-Bahn/releases) and
download the newest version.

### iOS
I have neither a Mac nor an iOS device to build the app for iOS. If you can build
the app for iOS, please get in touch. I will then provide the iOS version here
officially.

## Report a bug

[Open a new issue](https://github.com/chukfinley/Besser-Bahn/issues/new/choose) —
there are two forms (Bug / Idea). Both ask for the **app version** and the
**install source**. Both are required, for a practical reason: the version is in
the app under **Settings → at the top**, and the source tells how old your build
is (IzzyOnDroid is often a few days behind a GitHub release). With both, it takes
seconds to see whether the bug is already fixed. Without them, every report
starts with a question.

It also helps a lot: **Settings → Debug log → Share** (it holds the live API
calls; tokens are not logged).

## How it works

The app uses **no official end-user API** of Deutsche Bahn. Instead, it prefers
the backend of the **DB Navigator app** (`app.services-bahn.de/mob`), which
provides the real timetable, price, coach-order, and route data. The bahn.de web
API and a public HAFAS mirror serve as a fallback.

The **connection and punctuality prediction** comes from a separate, self-hosted
service (`bahn.chuk.dev`), which provides a delay model.

The split-ticket logic breaks a connection into all possible part-routes. It
then finds, by dynamic programming, the cheapest combination that covers the full
route — including BahnCard and Deutschland-Ticket discounts.

## Project structure

| Directory            | Contents                                                     |
| -------------------- | ------------------------------------------------------------ |
| `flutter-app/`       | The app (Flutter, Riverpod, GoRouter)                        |
| `prediction-service/`| Self-hosted delay/connection prediction API                  |
| `api-tests/`         | Health checks for every upstream endpoint used               |
| `docs/`              | Project website                                              |

## Development

### Build the app

```bash
git clone https://github.com/chukfinley/Besser-Bahn
cd Besser-Bahn/flutter-app
flutter pub get
flutter run
```

Prerequisite: Flutter (SDK ^3.10) installed on the system.

### Endpoint health check

Before you work on network or data code, `api-tests/healthcheck` checks that
every upstream endpoint still returns the response shape we expect. It runs in
Dart over `dart:io`, the same network stack as the app, and daily as a GitHub
Action:

```bash
cd api-tests/healthcheck && dart pub get && dart run bin/healthcheck.dart
```

## Recommended open-source rail projects and tools

*   **Traewelldroid** – a check-in app for public and long-distance transport in
    Europe, based on open-data interfaces.
    [Codeberg](https://codeberg.org/traewelldroid/traewelldroid)
*   **Transportr** – an open-source public-transport app for many regions
    worldwide. [GitHub](https://github.com/grote/Transportr)
*   **OpenRailwayMap** – a detailed interactive map of the worldwide railway
    network on an OSM base. [Website](https://openrailwaymap.org/)
*   **bahn.expert** – deep analysis of train connections, delays, and punctuality
    statistics. [Website](https://bahn.expert/)

## Privacy in rail travel

Organisations such as Digitalcourage work for transparency and user rights:

*   **Lawsuit against Deutsche Bahn over data collection in the DB Navigator** –
    Digitalcourage sued DB because the "DB Navigator" passes on personal data
    without sufficient consent.
    [Details at Digitalcourage](https://digitalcourage.de/pressemitteilungen/2025/bahn-klage-termin)

## Donate

If this app helps you save money on your rail trips, I am glad about a donation.
It secures further development and maintenance. You find the donation options
through the "Sponsor" button at the top of this GitHub page.

## Contribute

Contributions are welcome. Open an issue or a pull request if you want to suggest
improvements.

## License

Licensed under the DO WHAT THE FUCK YOU WANT TO PUBLIC LICENSE — see
[LICENSE.txt](LICENSE.txt).

## Disclaimer

This app is an unofficial project and has no connection to Deutsche Bahn AG. Use
is at your own risk. The split-tickets found comply with the conditions of
carriage of Deutsche Bahn.

## Acknowledgement

Great thanks to Lukas Weihrauch and his video, which was the inspiration for this
project: [https://youtu.be/SxKtI8f5QTU](https://youtu.be/SxKtI8f5QTU)
