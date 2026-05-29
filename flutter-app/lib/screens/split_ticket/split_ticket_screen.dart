import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../../models/split_ticket.dart';
import '../../providers/split_ticket_provider.dart';
import '../../providers/settings_provider.dart';
import '../../services/db_api_service.dart';
import '../../providers/service_providers.dart';
import '../../widgets/traewelling_avatar_button.dart';
import '../../core/constants.dart';
import '../../theme/app_colors.dart';

class SplitTicketScreen extends ConsumerStatefulWidget {
  const SplitTicketScreen({super.key});

  @override
  ConsumerState<SplitTicketScreen> createState() => _SplitTicketScreenState();
}

class _SplitTicketScreenState extends ConsumerState<SplitTicketScreen> {
  final _urlController = TextEditingController();
  bool _isResolving = false;
  String? _resolveError;

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  /// Extract bahn.de URL from text that may contain extra info
  /// (e.g. "Verbindung am Sa. 04.04... https://www.bahn.de/buchung/start?vbid=...")
  String _extractUrl(String text) {
    final regex = RegExp(r'https://www\.bahn\.de/[^\s]+');
    final match = regex.firstMatch(text);
    return match?.group(0) ?? text.trim();
  }

  Future<void> _pasteAndAnalyze() async {
    final clip = await Clipboard.getData(Clipboard.kTextPlain);
    if (clip?.text != null && clip!.text!.isNotEmpty) {
      _urlController.text = clip.text!;
      setState(() {});
      _analyze();
    }
  }

  Future<void> _analyze() async {
    final rawInput = _urlController.text.trim();
    if (rawInput.isEmpty) return;

    final url = _extractUrl(rawInput);
    if (!url.contains('bahn.de')) {
      _showError('Kein gültiger bahn.de Link gefunden.');
      return;
    }

    setState(() {
      _isResolving = true;
      _resolveError = null;
    });

    try {
      final settings = ref.read(settingsProvider);
      final travellers = DbApiService.createTravellerPayload(
        bahnCard: settings.bahnCard,
      );

      // Parse URL and resolve connection
      Map<String, dynamic>? connectionData;
      String dateStr = '';

      if (url.contains('vbid=')) {
        // Extract VBID from URL
        final uri = Uri.parse(
          url.contains('/buchung/start')
              ? url
              : url,
        );
        final vbid = uri.queryParameters['vbid'];
        if (vbid == null || vbid.isEmpty) {
          _showError('VBID konnte nicht aus dem Link extrahiert werden.');
          return;
        }

        // Resolve VBID -> connection data
        connectionData = await _resolveVbid(vbid, travellers,
            deutschlandTicket: settings.hasDeutschlandTicket);

        if (connectionData == null || connectionData.isEmpty) {
          _showError('Verbindung konnte nicht aufgelöst werden.');
          return;
        }

        // Extract date from first stop
        final firstStop = connectionData['verbindungen']?[0]
            ?['verbindungsAbschnitte']?[0]?['halte']?[0]?['abfahrtsZeitpunkt'];
        if (firstStop != null) {
          dateStr = (firstStop as String).split('T')[0];
        }
      } else if (url.contains('#')) {
        // Long-form search URL with fragment parameters
        final fragment = url.split('#').last;
        final params = Uri.splitQueryString(fragment);
        final fromId = params['soid'] ?? '';
        final toId = params['zoid'] ?? '';
        final dateTime = params['hd'] ?? '';

        if (fromId.isEmpty || toId.isEmpty || dateTime.isEmpty) {
          _showError('Link enthält nicht alle nötigen Parameter.');
          return;
        }

        final dbApi = ref.read(dbApiServiceProvider);
        connectionData = await dbApi.getConnectionDetails(
          fromId: fromId,
          toId: toId,
          dateTime: dateTime,
          travellers: travellers,
          deutschlandTicket: settings.hasDeutschlandTicket,
        );

        dateStr = dateTime.split('T')[0];
      } else {
        _showError('Link-Format nicht erkannt. Bitte einen bahn.de Verbindungslink einfügen.');
        return;
      }

      if (!connectionData.containsKey('verbindungen') ||
          (connectionData['verbindungen'] as List).isEmpty) {
        _showError('Keine Verbindungsdaten gefunden.');
        return;
      }

      // Extract stops from connection
      final connection = connectionData['verbindungen'][0];
      final sections = connection['verbindungsAbschnitte'] as List<dynamic>? ?? [];
      final stops = <Map<String, dynamic>>[];

      for (final section in sections) {
        final halte = section['halte'] as List<dynamic>? ?? [];
        for (int i = 0; i < halte.length; i++) {
          final halt = halte[i];
          final name = halt['name'] as String? ?? '';
          final id = halt['extId'] as String? ?? halt['id'] as String? ?? '';
          final depTime = halt['abfahrtsZeitpunkt'] as String? ?? '';
          final arrTime = halt['ankunftsZeitpunkt'] as String? ?? '';

          // Avoid duplicates (transfer stations appear in multiple sections)
          if (stops.isNotEmpty && stops.last['id'] == id) continue;

          stops.add({
            'name': name,
            'id': id,
            'departure_time': depTime.contains('T')
                ? depTime.split('T')[1].substring(0, 5)
                : '',
            'arrival_time': arrTime.contains('T')
                ? arrTime.split('T')[1].substring(0, 5)
                : '',
            'departure_iso': depTime,
          });
        }
      }

      if (stops.length < 2) {
        _showError('Nicht genug Haltestellen gefunden.');
        return;
      }

      // Get direct price
      final directPrice =
          (connection['angebotsPreis']?['betrag'] as num?)?.toDouble() ?? 0;

      setState(() => _isResolving = false);

      // Start split-ticket analysis
      ref.read(splitTicketProvider.notifier).analyze(
        stops: stops,
        date: dateStr,
        directPrice: directPrice,
      );
    } catch (e) {
      _showError('Fehler: $e');
    }
  }

  Future<Map<String, dynamic>?> _resolveVbid(
      String vbid, List<Map<String, dynamic>> travellers,
      {bool deutschlandTicket = false}) async {
    final headers = {
      'User-Agent': ApiConstants.userAgent,
      'Accept': 'application/json',
      'Content-Type': 'application/json; charset=UTF-8',
    };

    // Step 1: Get reconString from VBID
    final vbidResponse = await http.get(
      Uri.parse('${ApiConstants.dbWebApiBaseUrl}/angebote/verbindung/$vbid'),
      headers: headers,
    );

    if (vbidResponse.statusCode != 200) return null;

    final vbidData = json.decode(vbidResponse.body);
    final reconString = vbidData['hinfahrtRecon'] as String?;
    if (reconString == null) return null;

    // Step 2: Resolve with recon
    final reconPayload = {
      'klasse': 'KLASSE_2',
      'reisende': travellers,
      'ctxRecon': reconString,
      'deutschlandTicketVorhanden': deutschlandTicket,
    };

    final reconResponse = await http.post(
      Uri.parse('${ApiConstants.dbWebApiBaseUrl}/angebote/recon'),
      headers: headers,
      body: json.encode(reconPayload),
    );

    if (reconResponse.statusCode == 200 || reconResponse.statusCode == 201) {
      if (reconResponse.body.isNotEmpty) {
        try {
          return json.decode(reconResponse.body) as Map<String, dynamic>;
        } catch (_) {
          // Retry on 201
          if (reconResponse.statusCode == 201) {
            await Future.delayed(const Duration(seconds: 1));
            final retry = await http.post(
              Uri.parse('${ApiConstants.dbWebApiBaseUrl}/angebote/recon'),
              headers: headers,
              body: json.encode(reconPayload),
            );
            if (retry.statusCode == 200 && retry.body.isNotEmpty) {
              return json.decode(retry.body) as Map<String, dynamic>;
            }
          }
        }
      }
    }

    return null;
  }

  void _showError(String msg) {
    setState(() {
      _isResolving = false;
      _resolveError = msg;
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(splitTicketProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Split-Ticketing'),
        actions: const [TraewellingAvatarButton()],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          // Disclaimer
          Card(
            margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            color: theme.colorScheme.errorContainer.withAlpha(40),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.info_outline, size: 20,
                      color: theme.colorScheme.error),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Split-Tickets haben kein Anschluss-Recht. '
                      'Das Risiko bei Verspätungen liegt beim Fahrgast.',
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.error),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // URL input
          Card(
            margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('DB-Verbindungslink oder geteilten Text einfügen',
                      style: theme.textTheme.titleSmall),
                  const SizedBox(height: 4),
                  Text(
                    'In der DB App: Verbindung → Teilen → "Infos kopieren" → hier einfügen',
                    style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _urlController,
                    decoration: InputDecoration(
                      hintText: 'Link oder Text einfügen...',
                      prefixIcon: const Icon(Icons.link),
                      suffixIcon: IconButton(
                        icon: const Icon(Icons.content_paste),
                        onPressed: _pasteAndAnalyze,
                        tooltip: 'Einfügen & Analysieren',
                      ),
                    ),
                    maxLines: 3,
                    minLines: 1,
                    style: const TextStyle(fontSize: 13),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: (_isResolving || state.isLoading)
                        ? OutlinedButton.icon(
                            onPressed: state.isLoading
                                ? () => ref
                                    .read(splitTicketProvider.notifier)
                                    .cancel()
                                : null,
                            icon: const Icon(Icons.cancel),
                            label: Text(
                                _isResolving ? 'Verbindung wird aufgelöst...' : 'Abbrechen'),
                          )
                        : FilledButton.icon(
                            onPressed: _analyze,
                            icon: const Icon(Icons.call_split),
                            label: const Text('Analyse starten'),
                          ),
                  ),
                ],
              ),
            ),
          ),

          // Resolve error
          if (_resolveError != null)
            Card(
              margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              color: theme.colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    Icon(Icons.error_outline, size: 18,
                        color: theme.colorScheme.onErrorContainer),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(_resolveError!,
                          style: TextStyle(
                              color: theme.colorScheme.onErrorContainer)),
                    ),
                  ],
                ),
              ),
            ),

          // Progress
          if (state.isLoading && state.progress != null)
            _buildProgress(context, state.progress!),

          // Analysis error
          if (state.error != null)
            Card(
              margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              color: theme.colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(state.error!,
                    style: TextStyle(color: theme.colorScheme.onErrorContainer)),
              ),
            ),

          // Results
          if (state.result != null) ...[
            _buildPriceComparison(context, state.result!),
            for (int i = 0; i < state.result!.tickets.length; i++)
              _buildTicketCard(context, state.result!.tickets[i], i + 1),
          ],

          // Logs
          if (state.logs.isNotEmpty)
            _buildLogs(context, state.logs),
        ],
      ),
    );
  }

  Widget _buildProgress(BuildContext context, SplitTicketProgress progress) {
    final theme = Theme.of(context);
    final pct = (progress.progress * 100).toStringAsFixed(0);
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const SizedBox(
                  width: 20, height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Prüfe ${progress.processedCombinations} / '
                    '${progress.totalCombinations} Kombinationen ($pct%)',
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            LinearProgressIndicator(value: progress.progress),
            if (progress.currentSegment.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(progress.currentSegment,
                  style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildPriceComparison(
      BuildContext context, TicketAnalysisResult result) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Direktpreis:'),
                Text('${result.directPrice.toStringAsFixed(2)} €',
                    style: const TextStyle(fontSize: 16)),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Split-Preis:',
                    style: TextStyle(fontWeight: FontWeight.w600)),
                Text(
                  '${result.splitPrice.toStringAsFixed(2)} €',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: result.hasSavings ? AppColors.onTime : null,
                  ),
                ),
              ],
            ),
            if (result.hasSavings) ...[
              const Divider(height: 16),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: AppColors.onTime.withAlpha(20),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('Ersparnis',
                        style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: AppColors.onTime)),
                    Text(
                      '${result.savings.toStringAsFixed(2)} € '
                      '(${result.savingsPercent.toStringAsFixed(0)}%)',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: AppColors.onTime,
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 8),
            Text(
              '${result.combinationsChecked} Kombinationen in '
              '${result.elapsed.inSeconds}s geprüft',
              style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTicketCard(
      BuildContext context, SplitTicket ticket, int index) {
    final theme = Theme.of(context);
    final settings = ref.read(settingsProvider);

    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer,
                shape: BoxShape.circle,
              ),
              child: Center(
                child: Text('$index',
                    style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: theme.colorScheme.onPrimaryContainer)),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.train, size: 16),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          '${ticket.from} → ${ticket.to}',
                          style: const TextStyle(fontWeight: FontWeight.w500),
                        ),
                      ),
                    ],
                  ),
                  if (ticket.coveredByDeutschlandTicket)
                    Row(
                      children: [
                        Icon(Icons.check_circle, size: 14,
                            color: AppColors.onTime),
                        const SizedBox(width: 4),
                        Text('Mit Deutschland-Ticket abgedeckt',
                            style: TextStyle(
                                fontSize: 12, color: AppColors.onTime)),
                      ],
                    ),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  ticket.priceFormatted,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: ticket.coveredByDeutschlandTicket
                        ? AppColors.onTime
                        : null,
                  ),
                ),
                if (!ticket.coveredByDeutschlandTicket && ticket.price > 0)
                  TextButton(
                    onPressed: () {
                      final url = DbApiService.generateBookingLink(
                        ticket,
                        bahnCard: settings.bahnCard,
                        deutschlandTicket: settings.hasDeutschlandTicket,
                      );
                      launchUrl(Uri.parse(url),
                          mode: LaunchMode.externalApplication);
                    },
                    style: TextButton.styleFrom(
                        padding: EdgeInsets.zero,
                        minimumSize: const Size(0, 30)),
                    child: const Text('Buchen', style: TextStyle(fontSize: 12)),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLogs(BuildContext context, List<String> logs) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: ExpansionTile(
        title: Text('Log (${logs.length})', style: theme.textTheme.titleSmall),
        initiallyExpanded: false,
        children: [
          Container(
            height: 200,
            padding: const EdgeInsets.all(8),
            child: ListView.builder(
              reverse: true,
              itemCount: logs.length,
              itemBuilder: (_, i) => Text(
                logs[logs.length - 1 - i],
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
