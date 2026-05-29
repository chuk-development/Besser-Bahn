# Besser Bahn

Eine App zum Finden günstigerer Split-Ticket-Optionen für Deutsche Bahn Verbindungen.

<p align="center">
  <img src="assets/app_icon.png" width="100" />
</p>

## Funktionen

- Analyse von DB-Links (kurze vbid-Links und lange URLs)
- Finden der günstigsten Split-Ticket-Kombination
- Unterstützung für BahnCard-Rabatte (25/50, 1./2. Klasse)
- Deutschland-Ticket Integration
- Direkte Buchungslinks für gefundene Tickets (Das oberste Angebot ist das richtige)
- Detaillierte Preisvergleiche und Ersparnisberechnung
- **Keine Serverkosten: Die App läuft vollständig lokal auf Ihrem Gerät.**

## Installation

### Android
Gehen Sie zur [Releases-Seite](https://github.com/chukfinley/Besser-Bahn/releases) und laden Sie die neueste Version herunter.

### iOS
Ich selbst besitze weder einen Mac noch ein iOS-Gerät, um die App für iOS zu kompilieren. Sollte jemand von euch die App erfolgreich für iOS kompilieren können, meldet euch gerne bei mir, und ich werde die iOS-Version dann offiziell hier bereitstellen.

## Development

### Building the app

1. Stelle sicher, dass Flutter auf deinem System installiert ist
2. Klone das Repository:
   ```
   git clone https://github.com/chukfinley/Besser-Bahn
   ```
3. Wechsle in das Verzeichnis:
   ```
   cd Besser-Bahn/flutter-app
   ```
4. Installiere die Abhängigkeiten:
   ```
   flutter pub get
   ```
5. Starte die App:
   ```
   flutter run
   ```

### Python-Version

Die App ist auch als Python-Skript verfügbar:

1. Stelle sicher, dass `uv` installiert ist
2. Installiere die Abhängigkeiten:
   ```
   uv run main.py
   ```
3. Führe das Skript aus:
   ```
   uv run main.py "https://www.bahn.de/buchung/start?vbid=9dd9db26-4ffc-411c-b79c-e82bf5338989" [--age 30] [--bahncard BC25_2] [--deutschland-ticket]
   ```

## Verwendung

1. Kopiere einen Link aus der DB Navigator App oder von bahn.de
2. Füge den Link in die App ein
3. Wähle optional deine BahnCard und andere Einstellungen
4. Klicke auf "Verbindung analysieren"
5. Die App zeigt dir, ob eine günstigere Split-Ticket-Option verfügbar ist
6. Nutze die Buchungslinks, um die einzelnen Tickets direkt zu kaufen

## Unterstützte Links

- Kurze Links: `https://www.bahn.de/buchung/start?vbid=...`
- Lange Links: `https://www.bahn.de/...#soid=...&zoid=...&hd=...`

## Wie es funktioniert

Die App analysiert alle möglichen Teilstrecken einer Verbindung und findet durch dynamische Programmierung die günstigste Kombination von Tickets, die die gesamte Strecke abdeckt. Dabei werden auch Rabatte durch BahnCard und Deutschland-Ticket berücksichtigt.

**Wichtiger Hinweis zur Funktionsweise:**
Diese App nutzt **keine offizielle API** der Deutschen Bahn. Stattdessen simuliert sie die Abfragen, die ein Browser an `bahn.de` senden würde, um die nötigen Fahrplandaten und Preise zu erhalten. Da für die Analyse vieler möglicher Teilstrecken eine große Anzahl von Anfragen notwendig ist, würde ein zentraler Server (z.B. eine Webseite) sehr schnell von der Deutschen Bahn blockiert werden. Um dies zu vermeiden, sendet **jede Installation der App die Anfragen direkt von Ihrem Gerät**. Dadurch verteilt sich die Last auf viele individuelle Nutzer, und die Funktionalität kann erhalten bleiben. Es gibt daher auch keine Webseiten-Version dieser App.

## Empfohlene Open-Source Bahn-Projekte und Tools

Hier sind einige weitere nützliche Open-Source-Ressourcen und Projekte rund um das Thema Bahnreisen:

*   **Traewelldroid**: Eine App für Android und iOS, die Fahrplaninformationen für den öffentlichen Nah- und Fernverkehr in vielen Ländern Europas bietet. Sie basiert auf Open-Data-Schnittstellen und bietet Funktionen wie Echtzeitdaten, Benachrichtigungen und eine übersichtliche Kartenansicht.
    *   [GitHub-Repository](https://github.com/Traewelldroid/traewelldroid)

*   **Transportr**: Eine quelloffene Android-App für den öffentlichen Nahverkehr. Sie unterstützt verschiedene Regionen und Anbieter weltweit und bietet Funktionen wie Fahrplanauskunft, Echtzeit-Ankunftszeiten und Favoriten.
    *   [GitHub-Repository](https://github.com/grote/Transportr)

*   **OpenRailwayMap**: Eine detaillierte interaktive Karte des weltweiten Eisenbahnnetzes, basierend auf OpenStreetMap-Daten. Ideal für alle, die das Streckennetz, die Bahnhöfe oder die Infrastruktur genau erkunden möchten.
    *   [Website](https://openrailwaymap.org/)

*   **bahn.expert**: Ein Tool für die detaillierte Analyse von Zugverbindungen, Verspätungen und Pünktlichkeitsstatistiken der Deutschen Bahn. Es bietet tiefere Einblicke in die Daten als die offiziellen Kanäle und ist nützlich für Zugfans und Reisende, die mehr über ihre Verbindungen erfahren möchten.
    *   [Website](https://bahn.expert/)

## Wichtige Informationen zum Datenschutz im Bahnverkehr

Es ist wichtig, sich der Datenschutzaspekte beim Nutzen digitaler Angebote der Deutschen Bahn bewusst zu sein. Organisationen wie Digitalcourage setzen sich für mehr Transparenz und Nutzerrechte ein:

*   **Klage gegen die Deutsche Bahn wegen Datenerfassung im DB Navigator**
    *   Digitalcourage hat die Deutsche Bahn verklagt, weil der "DB Navigator" persönliche Daten ohne ausreichende Einwilligung weitergibt. Dabei geht es um die Frage, ob solche Datenweitergaben bei der Nutzung von Grundversorgungsangeboten rechtens sind.
    *   [Weitere Details bei Digitalcourage](https://digitalcourage.de/pressemitteilungen/2025/bahn-klage-termin)

## To-Do-Liste

- [x] Logo zur Android-App hinzufügen
- [ ] die totale menge an geld die man gespart hat tracken.
- [ ] Ratelimit mit proxys oder so umgehen
- [ ] Onboard-Zugdaten via WifiOnICE/ICE-Portal anzeigen (Geschwindigkeit, GPS-Position, nächste Halte, Verspätung). Quelle: `https://iceportal.de/api1/rs/status` (Tempo/GPS/Zugtyp) und `https://iceportal.de/api1/rs/tripInfo/trip` (Halte/Verspätung) — nur im Zug-WLAN erreichbar. App soll automatisch erkennen, ob ein solches Portal aktiv ist, und die Live-Daten einblenden. **Nur im Zug umsetzbar/testbar.**


## Spenden

Wenn diese App Ihnen geholfen hat, bei Ihren Bahnreisen Geld zu sparen, wäre es großartig, wenn Sie einen Teil oder die gesamte Ersparnis als Spende in dieses Projekt investieren könnten. Ihre Unterstützung hilft, die Weiterentwicklung und Wartung der App zu sichern!

Sie finden die Spendenmöglichkeiten über den "Sponsor"-Button oben auf dieser GitHub-Seite.

## Beitragen

Beiträge sind willkommen! Bitte öffne ein Issue oder einen Pull Request, wenn du Verbesserungen vorschlagen möchtest.

## Lizenz

Dieses Projekt ist unter der DO WHAT THE FUCK YOU WANT TO PUBLIC LICENSE lizenziert - siehe die [LICENSE](LICENSE.txt) Datei für Details.

## Haftungsausschluss

Diese App ist ein inoffizielles Projekt und steht in keiner Verbindung zur Deutschen Bahn AG. Die Nutzung erfolgt auf eigene Gefahr. Die gefundenen Split-Tickets entsprechen den Beförderungsbedingungen der Deutschen Bahn.

## Danksagung

Ein großer Dank geht an Lukas Weihrauch und sein Video, das die Inspiration für dieses Projekt lieferte: [https://youtu.be/SxKtI8f5QTU](https://youtu.be/SxKtI8f5QTU)