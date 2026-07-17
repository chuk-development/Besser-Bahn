import 'dart:convert';

import 'package:besser_bahn/core/bahncard_art.dart';
import 'package:besser_bahn/core/bahncard_art_cache.dart';
import 'package:besser_bahn/models/db_account.dart';
import 'package:besser_bahn/screens/profile/widgets/bahncard_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 1×1 transparent PNG.
const _pngB64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk'
    'YPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';

const _bildSicht = '''
<html><head><style>
html,body{margin:0;padding:0;}
.image{background-image:url(data:image/png;base64,$_pngB64);
  background-size:cover;padding-top:65%;position:relative;}
.name{position:absolute;top:55%;left:8%;font-size:4vw;color:#ffffff;}
.nummer{position:absolute;bottom:10%;right:8%;font-size:3vw;color:#fff;}
</style></head>
<body><div class="image">
  <div class="name">MAX MUSTERMANN</div>
  <div class="nummer">7081 4270 9016 3212</div>
</div></body></html>
''';

DbBahnCard _card({String? bildSicht, String nummer = '7081427090163212'}) =>
    DbBahnCard.fromJson({
      'bahnCardNummer': nummer,
      'bahnCardTyp': 'BC50',
      'produktBezeichnung': 'My BahnCard 50',
      'karteninhaber': 'Max Mustermann',
      'klasse': 'KLASSE_2',
      'gueltigBis': '2026-12-31',
      if (bildSicht != null) 'bildSicht': base64Encode(utf8.encode(bildSicht)),
    });

/// [width] is load-bearing for the fallback tests: widget tests render with a
/// test font whose every glyph is a full em square, so the placeholder's
/// "2. Klasse / gültig bis …" row needs far more room here than with a real
/// font. 640 keeps that a non-event; the native-path tests use the default 400
/// because their assertions are stated against it.
Future<void> _pump(WidgetTester tester, DbBahnCard card,
        {double width = 400}) =>
    tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(width: width, child: BahnCardView(card: card)),
        ),
      ),
    );

/// Linux — a platform [BahnCardView] knows has no WebView, so tier 2 is out of
/// the picture and the tier-3 placeholder is reachable.
final _noWebView = TargetPlatformVariant.only(TargetPlatform.linux);

void main() {
  setUp(BahnCardArtCache.clear);
  tearDown(BahnCardArtCache.clear);

  group('BahnCardView — the native path', () {
    testWidgets('paints DB artwork and DB text, with no WebView', (t) async {
      await _pump(t, _card(bildSicht: _bildSicht));

      expect(find.byType(BahnCardArtView), findsOneWidget);
      expect(find.byType(Image), findsOneWidget);
      expect(find.text('MAX MUSTERMANN'), findsOneWidget);
      expect(find.text('7081 4270 9016 3212'), findsOneWidget);
    });

    testWidgets('text scales to the card, not to a fixed pixel size',
        (t) async {
      final art = BahnCardArt.parse(_bildSicht)!;

      Future<double> sizeAtWidth(double w) async {
        await t.pumpWidget(MaterialApp(
          home: Scaffold(
            body: SizedBox(width: w, child: BahnCardArtView(art: art)),
          ),
        ));
        final text = t.widget<Text>(find.text('MAX MUSTERMANN'));
        return text.style!.fontSize!;
      }

      // 4vw of a 400 pt card is 16 pt; the same card on a 700 pt tablet has to
      // be 28 pt or the text drifts off the artwork it was positioned against.
      expect(await sizeAtWidth(400), closeTo(16, 1e-6));
      expect(await sizeAtWidth(700), closeTo(28, 1e-6));
    });

    testWidgets('honours the aspect ratio the CSS declared', (t) async {
      await _pump(t, _card(bildSicht: _bildSicht));
      final box = t.getSize(find.byType(BahnCardArtView));
      expect(box.width / box.height, closeTo(1 / 0.65, 1e-6));
    });

    testWidgets('offsets are anchored to the box the artwork fills', (t) async {
      await _pump(t, _card(bildSicht: _bildSicht));
      final card = t.getRect(find.byType(BahnCardArtView));
      final name = t.getRect(find.text('MAX MUSTERMANN'));
      // left:8% of a 400 pt card.
      expect(name.left - card.left, closeTo(0.08 * 400, 0.5));
      // top:55% of the card's height.
      expect(name.top - card.top, closeTo(0.55 * card.height, 0.5));
    });
  });

  group('BahnCardView — the fallback tiers', () {
    // Tier 2 (DB's HTML in a WebView) can't be widget-tested: webview_flutter
    // has no platform implementation outside a real Android/iOS engine, and
    // faking one would test the fake. What IS tested here is the decision —
    // an unrecognised document must never reach the native renderer — plus
    // tier 3, the styled placeholder, which is reachable by pretending to be a
    // platform that has no WebView at all (which Linux genuinely is).

    testWidgets('unparseable HTML falls back instead of rendering junk',
        (t) async {
      await _pump(t, _card(bildSicht: '<html><body>nope</body></html>'),
          width: 640);

      expect(find.byType(BahnCardArtView), findsNothing);
      // The styled placeholder carries the essentials from the model's own
      // fields, so the card is still identifiable.
      expect(find.text('My BahnCard 50'), findsOneWidget);
      expect(find.text('Max Mustermann'), findsOneWidget);
      expect(find.text('2. Klasse'), findsOneWidget);
      expect(find.text('gültig bis 31.12.2026'), findsOneWidget);
    }, variant: _noWebView);

    testWidgets('an account with no bildSicht at all still shows a card',
        (t) async {
      await _pump(t, _card(), width: 640);
      expect(find.byType(BahnCardArtView), findsNothing);
      expect(find.text('My BahnCard 50'), findsOneWidget);
    }, variant: _noWebView);

    testWidgets('a card whose artwork is missing never renders half a card',
        (t) async {
      // Text overlays but no artwork — the exact "half a card" case.
      const html = '<html><head><style>'
          '.name{position:absolute;top:55%;left:8%;font-size:4vw;color:#fff;}'
          '</style></head><body><div class="name">MAX MUSTERMANN</div>'
          '</body></html>';
      await _pump(t, _card(bildSicht: html), width: 640);
      expect(find.byType(BahnCardArtView), findsNothing);
      expect(find.text('MAX MUSTERMANN'), findsNothing);
      expect(find.text('My BahnCard 50'), findsOneWidget);
    }, variant: _noWebView);

    testWidgets('the native card also renders where no WebView exists',
        (t) async {
      // A side effect worth keeping: desktop used to get the gradient
      // placeholder no matter what, because tier 2 needs a WebView. The native
      // renderer doesn't, so Linux now shows the real card.
      await _pump(t, _card(bildSicht: _bildSicht));
      expect(find.byType(BahnCardArtView), findsOneWidget);
      expect(find.text('MAX MUSTERMANN'), findsOneWidget);
      expect(find.text('My BahnCard 50'), findsNothing); // not the placeholder
    }, variant: _noWebView);
  });

  group('BahnCardArtCache', () {
    test('parses a card once and reuses the result', () {
      final card = _card(bildSicht: _bildSicht);
      final a = BahnCardArtCache.of(card);
      final b = BahnCardArtCache.of(card);
      expect(a, isNotNull);
      // Identical instance — the whole point: no re-decode per build.
      expect(identical(a, b), isTrue);
      expect(identical(a!.imageBytes, b!.imageBytes), isTrue);
    });

    test('memoises the failure too, so a bad card is parsed once', () {
      final card = _card(bildSicht: '<html><body>nope</body></html>');
      expect(BahnCardArtCache.of(card), isNull);
      expect(BahnCardArtCache.of(card), isNull);
    });

    test('a re-issued card gets a new key, never the old artwork', () {
      final v1 = _card(bildSicht: _bildSicht);
      final v2 = _card(
          bildSicht: _bildSicht.replaceAll('MAX MUSTERMANN', 'ERIKA MUSTERFRAU'));
      expect(BahnCardArtCache.cacheKey(v1),
          isNot(BahnCardArtCache.cacheKey(v2)));
      expect(BahnCardArtCache.of(v2)!.texts.first.text, 'ERIKA MUSTERFRAU');
    });

    test('different cards get different keys', () {
      expect(
        BahnCardArtCache.cacheKey(_card(bildSicht: _bildSicht, nummer: 'A')),
        isNot(BahnCardArtCache.cacheKey(
            _card(bildSicht: _bildSicht, nummer: 'B'))),
      );
    });

    test('clear drops the memoised parse', () async {
      final card = _card(bildSicht: _bildSicht);
      final a = BahnCardArtCache.of(card);
      await BahnCardArtCache.clear();
      expect(identical(a, BahnCardArtCache.of(card)), isFalse);
    });
  });
}
