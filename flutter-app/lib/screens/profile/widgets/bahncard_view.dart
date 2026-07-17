import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart'
    show AndroidWebViewController;

import '../../../core/bahncard_art.dart';
import '../../../core/bahncard_art_cache.dart';
import '../../../core/bahncard_webview_cache.dart';
import '../../../models/db_account.dart';
import '../../../providers/account_provider.dart';

/// True when the platform has a [WebViewWidget] implementation. Linux /
/// Windows / web don't — fall back to a native card there.
bool get _webViewSupported =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS);

/// Renders one BahnCard.
///
/// The official `bildSicht` is an HTML document (a `<div>` with the card art as
/// `background-image` and CSS-positioned text for the holder name, BC number
/// and validity dates). We render it three ways, best first:
///
/// 1. **Native** — [BahnCardArt] pulls the artwork out of the CSS data URI and
///    reads the text fields' geometry, and we paint an [Image] with [Positioned]
///    text on top. Nothing to boot, nothing to re-decode: the card is on the
///    first frame. This is the whole point — the WebView was never waiting on
///    the network (the bytes ship inside the 283 KB payload), it was waiting on
///    Android to stand up a browser and re-parse a quarter megabyte of base64.
/// 2. **WebView** — DB's markup rendered verbatim, exactly as before. Used
///    whenever the parse finds anything it doesn't recognise, so a change to
///    DB's HTML costs us the speed-up and nothing else.
/// 3. **Styled placeholder** — platforms with no WebView (Linux/Windows/web),
///    or an account whose API response carried no HTML at all.
class BahnCardView extends StatelessWidget {
  final DbBahnCard card;
  const BahnCardView({super.key, required this.card});

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(16);
    final hasControl = card.kontrollSichtHtml != null;

    final art = BahnCardArtCache.of(card);
    final Widget child;
    if (art != null) {
      child = ClipRRect(
        borderRadius: radius,
        child: BahnCardArtView(art: art),
      );
    } else if (_webViewSupported && card.bildSichtHtml != null) {
      child = ClipRRect(
        borderRadius: radius,
        child: AspectRatio(
          // DB's bildSicht is laid out at ~1.538:1 (the CSS uses
          // padding-top:65% of width). The injected fill-CSS in
          // [_BahnCardHtml] then stretches .image to 100% height so the
          // PNG covers the entire AspectRatio box without trailing
          // whitespace.
          aspectRatio: 1 / 0.65,
          // Stretched to fill: tile is a single WebView, no overlay
          // chip — tapping anywhere on the card opens the Kontrolle
          // (the obvious affordance for the card surface).
          child: IgnorePointer(
            child: _BahnCardHtml(
              cacheKey: 'bild:${card.nummer}',
              html: card.bildSichtHtml!,
              fill: true,
            ),
          ),
        ),
      );
    } else {
      child = _fallback(context);
    }

    return InkWell(
      borderRadius: radius,
      onTap: hasControl ? () => _openControlView(context) : null,
      child: child,
    );
  }

  void _openControlView(BuildContext context) =>
      openBahnCardControl(context, card);

  Widget _fallback(BuildContext context) {
    return AspectRatio(
      aspectRatio: 1.586,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFFEC0016), Color(0xFF9B0010)],
          ),
        ),
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              card.produktBezeichnung.isNotEmpty
                  ? card.produktBezeichnung
                  : card.typ,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            const Spacer(),
            if (card.karteninhaber != null)
              Text(
                card.karteninhaber!,
                style: const TextStyle(color: Colors.white, fontSize: 15),
              ),
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  card.firstClass ? '1. Klasse' : '2. Klasse',
                  style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.85),
                      fontSize: 13),
                ),
                if (card.gueltigBis != null)
                  Text(
                    'gültig bis ${_d(card.gueltigBis!)}',
                    style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.85),
                        fontSize: 13),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _d(String iso) {
    final dt = DateTime.tryParse(iso);
    return dt != null ? DateFormat('dd.MM.yyyy').format(dt) : iso;
  }
}

/// Paints a parsed [BahnCardArt]: DB's own card artwork with DB's own text
/// fields over it, laid out from the CSS the parser read.
///
/// Everything [BahnCardArt] carries is a *fraction of the card box*, never a
/// pixel — the tile is whatever width the Profil tab gives it, so the box is
/// measured at layout time and every offset scaled to it. That is also why the
/// font size is a fraction of the width: `4vw` on a 350 pt card is 14 pt, and on
/// a 700 pt tablet card it has to be 28 pt or the text drifts out of the artwork
/// it was positioned against.
class BahnCardArtView extends StatelessWidget {
  final BahnCardArt art;
  const BahnCardArtView({super.key, required this.art});

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: art.aspectRatio,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final w = constraints.maxWidth;
          final h = constraints.maxHeight;
          return Stack(
            fit: StackFit.expand,
            children: [
              Image(
                image: BahnCardArtCache.imageProviderFor(art),
                fit: BoxFit.cover,
                // The bytes are already decoded and resident — fading in would
                // add a frame of blank card for no reason.
                gaplessPlayback: true,
                filterQuality: FilterQuality.medium,
              ),
              for (final t in art.texts)
                Positioned(
                  left: t.left == null ? null : t.left! * w,
                  right: t.right == null ? null : t.right! * w,
                  top: t.top == null ? null : t.top! * h,
                  bottom: t.bottom == null ? null : t.bottom! * h,
                  child: Text(
                    t.text,
                    textAlign: t.textAlign,
                    maxLines: 1,
                    softWrap: false,
                    // The artwork has a fixed amount of room for each field;
                    // clipping matches what the browser does when the holder's
                    // name is longer than DB planned for.
                    overflow: TextOverflow.clip,
                    style: TextStyle(
                      color: t.color,
                      fontSize: t.fontSize * w,
                      fontWeight: t.fontWeight,
                      fontStyle: t.fontStyle,
                      letterSpacing: t.letterSpacing == null
                          ? null
                          : t.letterSpacing! * w,
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// Open DB's BahnCard Kontrollansicht for [card] — same screen as tapping the
/// card in Profil, exposed so the Ticket view can jump to it (a conductor
/// usually checks both, so the user needs a fast switch).
void openBahnCardControl(BuildContext context, DbBahnCard card) {
  // Regular push (not fullscreenDialog) so the AppBar leading icon is a back
  // arrow, not a close X — matches the navigation style of the rest of the
  // app's secondary screens.
  Navigator.of(context, rootNavigator: true).push(
    MaterialPageRoute<void>(
      builder: (_) => _BahnCardControlScreen(card: card),
    ),
  );
}

/// Open the first BahnCard's Kontrollansicht, or show a snackbar explaining
/// why nothing happened (still loading / endpoint failed / no BahnCard in the
/// account). Always-visible Ticket-AppBar action — never a silent no-op.
Future<void> openFirstBahnCardControl(
    BuildContext context, WidgetRef ref) async {
  final messenger = ScaffoldMessenger.of(context);
  final async = ref.read(bahncardsProvider);
  final cards = async.asData?.value;
  if (cards != null && cards.isNotEmpty) {
    openBahnCardControl(context, cards.first);
    return;
  }
  if (cards != null && cards.isEmpty) {
    messenger.showSnackBar(
        const SnackBar(content: Text('Keine BahnCard im Konto.')));
    return;
  }
  // Loading or error — kick a fresh fetch and report.
  messenger.showSnackBar(
      const SnackBar(content: Text('BahnCard wird geladen …')));
  ref.invalidate(bahncardsProvider);
  try {
    final fresh = await ref.read(bahncardsProvider.future);
    if (!context.mounted) return;
    if (fresh.isEmpty) {
      messenger.showSnackBar(
          const SnackBar(content: Text('Keine BahnCard im Konto.')));
      return;
    }
    openBahnCardControl(context, fresh.first);
  } catch (e) {
    if (!context.mounted) return;
    messenger
        .showSnackBar(SnackBar(content: Text('BahnCard nicht ladbar: $e')));
  }
}

/// Fullscreen Kontrollansicht — DB Navigator's exact control-view HTML
/// (PNG + CSS overlay) in a WebView so the conductor sees the same
/// `sichtpruefmerkmal` artwork the official app shows. Layout mirrors
/// [TicketViewScreen]: title in the AppBar (`MyBahnCard 50 (2. Klasse)`),
/// white card with the same ~20/16 inset padding around the WebView, and
/// metadata (BC-Nr, Gültig-bis) underneath — the official card image
/// already carries the holder name inline so we don't duplicate it.
///
/// **This one stays on the WebView, deliberately.** The card face is
/// decoration; the Kontrollsicht is the document a conductor inspects, and DB
/// rotates its anti-fraud artwork on its own schedule
/// ([DbBahnCard.kontrollSichtGueltigBis]). Re-implementing DB's rendering here
/// would mean a fare check could fail on our layout bug. The speed-up isn't
/// worth that: this screen is opened deliberately, one card at a time, and the
/// controller cache below already spares it the reload.
class _BahnCardControlScreen extends StatelessWidget {
  final DbBahnCard card;
  const _BahnCardControlScreen({required this.card});

  @override
  Widget build(BuildContext context) {
    final html = card.kontrollSichtHtml;
    final title = card.produktBezeichnung.isNotEmpty
        ? card.produktBezeichnung
        : 'BahnCard · Kontrolle';
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: ColoredBox(
        color: Colors.white,
        child: Padding(
          // Generous top inset — the Kontrollsicht reads as a "ticket-like
          // card" and benefits from breathing room above. Side / bottom
          // insets match TicketViewScreen so both surfaces feel consistent.
          padding: const EdgeInsets.fromLTRB(20, 32, 20, 20),
          child: (_webViewSupported && html != null)
              ? _BahnCardHtml(
                  cacheKey: 'kontrolle:${card.nummer}', html: html)
              : const Center(
                  child: Text('Keine Kontrollansicht verfügbar.',
                      style: TextStyle(color: Colors.black54))),
        ),
      ),
    );
  }
}

/// Shared WebView wrapper for the BahnCard's `bildSicht` / `kontrollSicht`
/// HTML payloads. JS disabled (DB's HTML is static), no scrollbars. When
/// [fill] is true (inline profile tile) the embedded `.image` div is forced
/// to fill 100% of the viewport via injected CSS so the PNG covers the
/// AspectRatio box edge-to-edge — without it the div's natural
/// `padding-top:65%` leaves trailing white below the card.
///
/// [cacheKey] identifies the controller in [BahnCardWebViewCache]; it must be
/// unique per (view, card) and stable across rebuilds.
class _BahnCardHtml extends StatefulWidget {
  final String cacheKey;
  final String html;
  final bool fill;
  const _BahnCardHtml({
    required this.cacheKey,
    required this.html,
    this.fill = false,
  });

  @override
  State<_BahnCardHtml> createState() => _BahnCardHtmlState();
}

class _BahnCardHtmlState extends State<_BahnCardHtml> {
  late final WebViewController _controller;

  static const _baseCss =
      'html,body{margin:0;padding:0;background:transparent;'
      'scrollbar-width:none;-ms-overflow-style:none;}'
      'html::-webkit-scrollbar,body::-webkit-scrollbar{display:none;width:0;}';

  /// Forces DB's `.image` div to fill the WebView viewport (100%×100%) and
  /// `background-size:cover` keeps the PNG aspect-correct. The four
  /// `position:absolute` overlay divs stay correct because their
  /// `top:NN%`/`left:NN%`/`right:NN%` are relative to `.image`, which is
  /// now fullscreen instead of `padding-top:65%`-shaped. `img` is treated
  /// the same way for the kontrollSicht's `<img>` payload.
  static const _fillCss =
      'html,body{height:100%;overflow:hidden;}'
      '.image{padding-top:0!important;width:100%!important;height:100%!important;'
      'background-size:cover!important;background-position:center!important;}'
      'img{display:block;max-width:100%;height:auto;}';

  @override
  void initState() {
    super.initState();
    // The `fill` variant injects different CSS, so it needs its own entry even
    // for the same card.
    final key = '${widget.cacheKey}:${widget.fill}';
    _controller = BahnCardWebViewCache.putIfAbsent(key, _build);
  }

  WebViewController _build() {
    final style = '<style>$_baseCss${widget.fill ? _fillCss : ''}</style>';
    final html = widget.html.contains('</head>')
        ? widget.html.replaceFirst('</head>', '$style</head>')
        : '$style${widget.html}';
    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.disabled)
      ..setBackgroundColor(Colors.transparent)
      ..loadHtmlString(html);
    // The CSS above only hides the scrollbar the PAGE draws. Android's system
    // WebView draws its own overlay scrollbar on top of that, which no
    // stylesheet can reach — the platform view has to be told. The ticket view
    // already learned this the hard way; the BahnCard never got the same
    // treatment, so a scrollbar rode along the card face. No-op off Android.
    final platform = controller.platform;
    if (platform is AndroidWebViewController) {
      platform.setVerticalScrollBarEnabled(false);
      platform.setHorizontalScrollBarEnabled(false);
    }
    return controller;
  }

  @override
  Widget build(BuildContext context) =>
      WebViewWidget(controller: _controller);
}
