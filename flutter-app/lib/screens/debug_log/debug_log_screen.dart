import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/app_log.dart';
import '../../core/bahncard_art.dart';
import '../../core/bahncard_html_dump.dart';
import '../../models/departure.dart' show TransitLine;
import '../../models/journey.dart';
import '../../models/station.dart';
import '../../providers/account_provider.dart';
import '../../services/live_update_service.dart';
import '../../widgets/app_nav_bar.dart';

/// Live debug log — shows what the API layer is doing (vendo / bahn.de / HAFAS),
/// so issues like "search returns 500" can be diagnosed on-device.
class DebugLogScreen extends ConsumerWidget {
  const DebugLogScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Debug-Log'),
        actions: [
          IconButton(
            tooltip: 'Live-Update testen',
            icon: const Icon(Icons.notifications_active_outlined),
            onPressed: () => _testLiveUpdate(context),
          ),
          IconButton(
            tooltip: 'BahnCard-HTML exportieren',
            icon: const Icon(Icons.badge_outlined),
            onPressed: () => _exportBahnCardHtml(context, ref),
          ),
          IconButton(
            tooltip: 'Kopieren',
            icon: const Icon(Icons.copy),
            onPressed: () {
              Clipboard.setData(
                ClipboardData(text: AppLog.messages.value.join('\n')),
              );
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(const SnackBar(content: Text('Log kopiert')));
            },
          ),
          IconButton(
            tooltip: 'Leeren',
            icon: const Icon(Icons.delete_outline),
            onPressed: AppLog.clear,
          ),
        ],
      ),
      body: ValueListenableBuilder<List<String>>(
        valueListenable: AppLog.messages,
        builder: (context, lines, _) {
          if (lines.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  'Noch keine Log-Einträge.\n'
                  'Führe eine Suche oder Abfrage aus.',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          return ListView.builder(
            padding: EdgeInsets.fromLTRB(
              8,
              8,
              8,
              8 + AppNavBar.insetOf(context),
            ),
            itemCount: lines.length,
            itemBuilder: (context, i) {
              final line = lines[lines.length - 1 - i]; // newest first
              final isError =
                  line.contains('FAILED') ||
                  line.contains('failed') ||
                  line.contains('HTTP 5') ||
                  line.contains('HTTP 4');
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 1),
                child: SelectableText(
                  line,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    color: isError ? Colors.redAccent : null,
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

/// Shares a redacted copy of the BahnCard's `bildSicht` / `kontrollSicht` HTML.
///
/// [BahnCardArt] can only render the card natively — and skip the WebView — if
/// it recognises DB's markup, and that markup can't be developed against
/// blind: it only exists inside a real DB account. This hands over the element
/// tree and the full CSS with every name, number and image payload destroyed
/// first (see [redactBahnCardHtml]), plus what the parser made of the real
/// document, so a fallback can be diagnosed without anyone shipping their
/// BahnCard around.
/// Fire a Live Update with a synthetic in-progress trip so the feature can be
/// verified on-device without waiting for a real saved trip to enter its
/// tracking window. Reports whether the device actually promotes it.
Future<void> _testLiveUpdate(BuildContext context) async {
  final messenger = ScaffoldMessenger.of(context);
  final now = DateTime.now();
  Station st(String name, double lat, double lon) =>
      Station(id: name, name: name, latitude: lat, longitude: lon);
  TransitLine line() => const TransitLine(
    name: 'RE7',
    fahrtNr: '0',
    productName: 'RE',
    product: 'regional',
  );
  final journey = Journey(
    legs: [
      JourneyLeg(
        origin: st('Kiel Hbf', 54.3143, 10.1324),
        destination: st('Neumünster', 54.0719, 9.9819),
        line: line(),
        plannedDeparture: now.subtract(const Duration(minutes: 2)),
        departure: now.subtract(const Duration(minutes: 2)),
        plannedArrival: now.add(const Duration(minutes: 15)),
        arrival: now.add(const Duration(minutes: 18)), // +3 min delay
      ),
      JourneyLeg(
        origin: st('Neumünster', 54.0719, 9.9819),
        destination: st('Hamburg Hbf', 53.5528, 10.0067),
        line: line(),
        plannedDeparture: now.add(const Duration(minutes: 22)),
        departure: now.add(const Duration(minutes: 22)),
        plannedArrival: now.add(const Duration(minutes: 45)),
        arrival: now.add(const Duration(minutes: 45)),
      ),
    ],
  );

  AppLog.log(
    'live update: TEST-Knopf gedrückt — synthetische Reise '
    'Kiel→Hamburg, +3 Min',
    tag: 'notify',
  );
  LiveUpdateService.reset(); // clear any earlier "dismissed" state
  LiveUpdateService.invalidateSupport(); // re-ask the platform (toggle may have changed)
  final supported = await LiveUpdateService.isSupported();
  final posted = await LiveUpdateService.show(journey);
  if (!context.mounted) return;
  final msg = posted
      ? 'Live-Update gepostet — schau in die Statusleiste.'
      : supported
      ? 'Gerät unterstützt es, aber Post abgelehnt (Reise evtl. schon vorbei).'
      : 'Dein Gerät promotet es nicht: Android 16 QPR1+/17 nötig und '
            '„Live Updates" für die App in den Benachrichtigungs-'
            'einstellungen aktivieren.';
  messenger.showSnackBar(
    SnackBar(content: Text(msg), duration: const Duration(seconds: 6)),
  );
}

Future<void> _exportBahnCardHtml(BuildContext context, WidgetRef ref) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    final cards = ref.read(bahncardsProvider).value;
    if (cards == null || cards.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Keine BahnCard geladen — erst Profil öffnen.'),
        ),
      );
      return;
    }

    final buf = StringBuffer()
      ..writeln('# BahnCard bildSicht/kontrollSicht — geschwärzter Export')
      ..writeln('# Buchstaben → X, Ziffern → 0, Bilddaten entfernt.')
      ..writeln('# Struktur + CSS unverändert.')
      ..writeln();

    for (final (i, card) in cards.indexed) {
      final art = BahnCardArt.parse(card.bildSichtHtml);
      buf
        ..writeln('## Karte ${i + 1}: ${card.typ} / ${card.klasse}')
        ..writeln('# bildSicht: ${card.bildSichtHtml?.length ?? 0} Zeichen')
        ..writeln(
          '# Parser: ${art == null ? 'FALLBACK (nicht erkannt)' : 'OK — '
                    '${art.texts.length} Textfeld(er), '
                    '${art.imageBytes.length}B ${art.mimeType}, '
                    'ratio ${art.aspectRatio.toStringAsFixed(3)}'}',
        )
        ..writeln()
        ..writeln('### bildSicht')
        ..writeln(redactBahnCardHtml(card.bildSichtHtml ?? '(leer)'))
        ..writeln()
        ..writeln('### kontrollSicht')
        ..writeln(redactBahnCardHtml(card.kontrollSichtHtml ?? '(leer)'))
        ..writeln();
    }

    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/bahncard-html-redacted.txt');
    await file.writeAsString(buf.toString());
    if (!context.mounted) return;
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(file.path)],
        subject: 'BahnCard-HTML (geschwärzt)',
      ),
    );
  } catch (e) {
    messenger.showSnackBar(
      SnackBar(content: Text('Export fehlgeschlagen: $e')),
    );
  }
}
