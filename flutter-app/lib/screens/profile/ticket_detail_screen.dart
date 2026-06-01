import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform, Factory;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:webview_flutter/webview_flutter.dart';

import '../../models/db_ticket.dart';
import '../../models/journey.dart';
import '../../providers/account_provider.dart';
import '../../providers/service_providers.dart';
import '../connection_search/connection_detail_screen.dart';

/// Entry point for a booked ticket from the Reisen tab. Loads the ticket,
/// parses its `verbindung` into a [Journey], then defers to
/// [ConnectionDetailScreen] — so a bought ticket reads the *same* Reiseplan
/// view as a search result. From there, the AppBar's Ticket icon opens
/// [TicketViewScreen] (the official Handyticket WebView).
class TicketDetailScreen extends ConsumerWidget {
  final String auftragsnummer;
  final String kundenwunschId;

  const TicketDetailScreen({
    super.key,
    required this.auftragsnummer,
    required this.kundenwunschId,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final key = '$auftragsnummer/$kundenwunschId';
    final ticket = ref.watch(ticketProvider(key));
    return ticket.when(
      loading: () => Scaffold(
        appBar: AppBar(title: const Text('Reiseplan')),
        body: const Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => Scaffold(
        appBar: AppBar(title: const Text('Reiseplan')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.error_outline,
                    size: 48, color: Theme.of(context).colorScheme.error),
                const SizedBox(height: 12),
                Text('Ticket konnte nicht geladen werden.\n$e',
                    textAlign: TextAlign.center),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: () => ref.invalidate(ticketProvider(key)),
                  child: const Text('Erneut versuchen'),
                ),
              ],
            ),
          ),
        ),
      ),
      data: (t) {
        Journey? j;
        final v = t.verbindungJson;
        if (v != null) {
          try {
            j = ref.read(vendoServiceProvider).parseConnection(v);
          } catch (_) {/* fall through */}
        }
        if (j == null) {
          // No usable Reiseplan in this ticket — go straight to the official
          // Handyticket view so the user can at least show it.
          return TicketViewScreen(
            ticketRef: (
              auftragsnummer: auftragsnummer,
              kundenwunschId: kundenwunschId,
            ),
          );
        }
        return ConnectionDetailScreen(
          journey: j,
          ticketRef: (
            auftragsnummer: auftragsnummer,
            kundenwunschId: kundenwunschId,
          ),
        );
      },
    );
  }
}

// ===========================================================================
// TicketViewScreen — the official Handyticket WebView, opened from the
// AppBar "Ticket" action on a booked Reiseplan.
// ===========================================================================

class TicketViewScreen extends ConsumerWidget {
  final TicketRef ticketRef;
  const TicketViewScreen({super.key, required this.ticketRef});

  static bool get _webViewSupported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final key = '${ticketRef.auftragsnummer}/${ticketRef.kundenwunschId}';
    final ticket = ref.watch(ticketProvider(key));
    final reservations = ticket.asData?.value.reservierungen ?? const [];

    return Scaffold(
      // Theme background (the dark/brown app surface) shows between the two
      // white cards below — matches the DB Navigator's structure where the
      // ticket sits visually separate from the validity header.
      appBar: AppBar(
        title: const Text('Ticket'),
        actions: [
          if (reservations.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.event_seat_outlined),
              tooltip: 'Reservierte Sitzplätze',
              onPressed: () => _showReservations(context, reservations),
            ),
        ],
      ),
      body: ticket.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text('Ticket konnte nicht geladen werden.\n$e',
                textAlign: TextAlign.center),
          ),
        ),
        data: (t) => _body(context, t),
      ),
    );
  }

  Widget _body(BuildContext context, DbTicket t) {
    return Column(
      children: [
        // White status card at the top of the page, sitting on the theme bg.
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: _TicketStatusBlock(ticket: t),
        ),
        // Visible ~1cm gap of theme background between the validity header
        // and the ticket itself — matches the official app's spacing.
        const SizedBox(height: 24),
        // White ticket card, bigger inset around the WebView so the QR/Aztec
        // has equal breathing room on all sides.
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: ColoredBox(
                color: Colors.white,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: (_webViewSupported && t.ticketHtml != null)
                      ? _OfficialTicketWebView(html: t.ticketHtml!)
                      : _FallbackTicket(ticket: t),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  void _showReservations(
      BuildContext context, List<DbReservierung> reservations) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Deine Reservierung', style: theme.textTheme.titleLarge),
                const SizedBox(height: 12),
                for (final r in reservations)
                  Card(
                    margin: const EdgeInsets.only(bottom: 10),
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(Icons.train,
                                  size: 20, color: theme.colorScheme.primary),
                              const SizedBox(width: 8),
                              Text(r.trainLabel,
                                  style: theme.textTheme.titleMedium),
                            ],
                          ),
                          if (r.vonName != null || r.nachName != null) ...[
                            const SizedBox(height: 4),
                            Text('${r.vonName ?? ''} → ${r.nachName ?? ''}',
                                style: theme.textTheme.bodyMedium?.copyWith(
                                    color: theme.colorScheme.outline)),
                          ],
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Icon(Icons.event_seat,
                                  size: 20, color: theme.colorScheme.primary),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                    r.plaetze.isEmpty
                                        ? '${r.anzahlPlaetze} Platz reserviert'
                                        : r.seatLabel,
                                    style: theme.textTheme.bodyLarge),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

// --- Ticket status header (matches DB Navigator's dark block) --------------

/// White validity card above the ticket, mirroring the DB Navigator layout:
/// top row is gültig-ab date (left) + Auftrags-Nr (right, tabular), big
/// tariff line, route line small/secondary, and a status line at the bottom
/// (red "Ticket nicht mehr gültig" / "Ticket storniert", or green "Ticket
/// gültig" with a pulsing dot) — all on white with dark text so it sits
/// cleanly on top of the app's themed background.
class _TicketStatusBlock extends StatelessWidget {
  final DbTicket ticket;
  const _TicketStatusBlock({required this.ticket});

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final expired =
        ticket.gueltigBis != null && now.isAfter(ticket.gueltigBis!);
    final stornoed = ticket.status.toUpperCase() == 'STORNIERT';
    final valid = !expired && !stornoed;

    final statusColor = stornoed || expired
        ? const Color(0xFFD32011) // red
        : const Color(0xFF0E7A2C); // green
    final statusText = stornoed
        ? 'Ticket storniert'
        : expired
            ? 'Ticket nicht mehr gültig'
            : 'Ticket gültig';

    final date = ticket.gueltigAb != null
        ? DateFormat('dd.MM.yyyy').format(ticket.gueltigAb!)
        : '';
    final tariff = ticket.angebotsname?.trim().isNotEmpty == true
        ? '${ticket.angebotsname} ${ticket.firstClass ? '1.Kl' : '2.Kl'}'
        : (ticket.firstClass ? 'Einzelkarte 1.Kl' : 'Einzelkarte 2.Kl');
    final route = (ticket.vonName == null && ticket.nachName == null)
        ? ''
        : '${ticket.vonName ?? '—'} → ${ticket.nachName ?? '—'}';

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
      ),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Date · Auftrags-Nr (small, two-up).
          Row(
            children: [
              Text(date,
                  style: const TextStyle(
                      color: Colors.black87,
                      fontSize: 13,
                      fontWeight: FontWeight.w600)),
              const Spacer(),
              Text(
                ticket.auftragsnummer,
                style: const TextStyle(
                    color: Colors.black54,
                    fontSize: 13,
                    fontFeatures: [FontFeature.tabularFigures()]),
              ),
            ],
          ),
          const SizedBox(height: 4),
          // Tariff (the headline).
          Text(tariff,
              style: const TextStyle(
                  color: Colors.black87,
                  fontSize: 15,
                  fontWeight: FontWeight.bold)),
          if (route.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(route,
                style: const TextStyle(color: Colors.black54, fontSize: 12)),
          ],
          const SizedBox(height: 8),
          // Status text — red when expired/storniert, green when valid; a
          // small pulsing dot rides next to the valid state as a cheap "live"
          // proof a screenshot can't fake.
          Row(
            children: [
              if (valid) ...[
                const _LiveDot(),
                const SizedBox(width: 6),
              ] else ...[
                Icon(stornoed ? Icons.info : Icons.cancel,
                    color: statusColor, size: 16),
                const SizedBox(width: 4),
              ],
              Text(statusText,
                  style: TextStyle(
                      color: statusColor,
                      fontSize: 13,
                      fontWeight: FontWeight.w700)),
            ],
          ),
        ],
      ),
    );
  }
}

/// Pulsing dot — only animation in the new status block. Cheap proof of life
/// (a screenshot can't pulse) without the noisy moving banner.
class _LiveDot extends StatefulWidget {
  const _LiveDot();

  @override
  State<_LiveDot> createState() => _LiveDotState();
}

class _LiveDotState extends State<_LiveDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
        opacity: Tween(begin: 0.35, end: 1.0).animate(_ctrl),
        child: Container(
          width: 8,
          height: 8,
          decoration: const BoxDecoration(
            color: Color(0xFF6CE07A),
            shape: BoxShape.circle,
          ),
        ),
      );
}

// --- WebView ----------------------------------------------------------------

class _OfficialTicketWebView extends StatefulWidget {
  final String html;
  const _OfficialTicketWebView({required this.html});

  @override
  State<_OfficialTicketWebView> createState() => _OfficialTicketWebViewState();
}

class _OfficialTicketWebViewState extends State<_OfficialTicketWebView> {
  late final WebViewController _controller;

  /// Hides the Android WebView's overlay scrollbar AND the WebKit scroll
  /// gutter (the thin grey strip the user sees on the right). Scrolling
  /// itself stays on — only the chrome goes away.
  static const _hideScrollbarsCss = '<style>'
      'html,body{scrollbar-width:none;-ms-overflow-style:none;}'
      'html::-webkit-scrollbar,body::-webkit-scrollbar{display:none;width:0;}'
      '</style>';

  @override
  void initState() {
    super.initState();
    final html = widget.html.contains('</head>')
        ? widget.html.replaceFirst('</head>', '$_hideScrollbarsCss</head>')
        : '$_hideScrollbarsCss${widget.html}';
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.disabled)
      ..setBackgroundColor(Colors.white)
      ..loadHtmlString(html);
  }

  @override
  Widget build(BuildContext context) => WebViewWidget(
        controller: _controller,
        // Claim vertical drag so the WebView's internal scroll always wins —
        // without this any ancestor scrollable could steal the gesture and the
        // ticket appears stuck (the bug the user reported).
        gestureRecognizers: <Factory<OneSequenceGestureRecognizer>>{
          Factory<VerticalDragGestureRecognizer>(
              () => VerticalDragGestureRecognizer()),
        },
      );
}

// --- Native fallback (desktop/web) -----------------------------------------

class _FallbackTicket extends StatelessWidget {
  final DbTicket ticket;
  const _FallbackTicket({required this.ticket});

  @override
  Widget build(BuildContext context) {
    final t = ticket;
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: [
        Card(
          margin: EdgeInsets.zero,
          color: Colors.white,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                if (t.barcode != null)
                  Image.memory(t.barcode!,
                      width: 220,
                      height: 220,
                      fit: BoxFit.contain,
                      gaplessPlayback: true)
                else
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 32),
                    child: Text('Kein Barcode in diesem Ticket.',
                        style: TextStyle(color: Colors.black54)),
                  ),
                const SizedBox(height: 8),
                Text('Auftrag ${t.auftragsnummer}',
                    style: const TextStyle(color: Colors.black87)),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          margin: EdgeInsets.zero,
          child: Column(
            children: [
              if (t.angebotsname != null)
                _row(theme, Icons.local_offer_outlined, 'Tarif',
                    t.angebotsname!),
              _row(theme, Icons.event_seat_outlined, 'Klasse',
                  t.firstClass ? '1. Klasse' : '2. Klasse'),
              _row(theme, Icons.group_outlined, 'Reisende', t.reisendeText),
              if (t.gueltigAb != null)
                _row(theme, Icons.schedule, 'Gültig ab',
                    DateFormat('dd.MM.yyyy, HH:mm').format(t.gueltigAb!)),
              if (t.gueltigBis != null)
                _row(theme, Icons.event_busy_outlined, 'Gültig bis',
                    DateFormat('dd.MM.yyyy, HH:mm').format(t.gueltigBis!)),
              _row(theme, Icons.verified_outlined, 'Status', t.status),
            ],
          ),
        ),
      ],
    );
  }

  Widget _row(ThemeData theme, IconData icon, String label, String value) =>
      ListTile(
        leading: Icon(icon, color: theme.colorScheme.primary),
        title: Text(label, style: theme.textTheme.bodySmall),
        subtitle: Text(value, style: theme.textTheme.bodyLarge),
      );
}
