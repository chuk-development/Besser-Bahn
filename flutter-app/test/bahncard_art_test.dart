import 'dart:convert';

import 'package:besser_bahn/core/bahncard_art.dart';
import 'package:besser_bahn/core/bahncard_html_dump.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

/// A 1×1 transparent PNG — enough to prove the bytes survive the data URI.
const _pngB64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk'
    'YPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';

/// Our best reconstruction of DB's `bildSicht`: one `.image` div carrying the
/// artwork as a background data URI and sized by `padding-top`, with absolutely
/// positioned text fields over it.
///
/// **This is a reconstruction, not a capture.** Nobody on this branch has a DB
/// account, so it is built from what the app's own code already documented
/// about the payload. It pins the behaviour we intend; it does NOT prove the
/// parser accepts the real thing. That's exactly why every test below has a
/// twin asserting the fallback, and why the debug export exists.
String _bildSicht({
  String name = 'MAX MUSTERMANN',
  String extraCss = '',
  String extraBody = '',
}) =>
    '''
<!DOCTYPE html>
<html><head><meta charset="utf-8"><style>
html,body{margin:0;padding:0;}
.image{
  background-image:url(data:image/png;base64,$_pngB64);
  background-size:cover;
  padding-top:65%;
  position:relative;
}
.name{position:absolute;top:55%;left:8%;font-size:4vw;color:#ffffff;font-weight:bold;}
.nummer{position:absolute;top:72%;left:8%;font-size:3.2vw;color:#fff;letter-spacing:0.4vw;}
.gueltig{position:absolute;bottom:6%;right:8%;font-size:2.8vw;color:rgba(255,255,255,0.85);text-align:right;}
$extraCss
</style></head>
<body>
  <div class="image">
    <div class="name">$name</div>
    <div class="nummer">7081 4270 9016 3212</div>
    <div class="gueltig">01.01.2026 &ndash; 31.12.2026</div>
    $extraBody
  </div>
</body></html>
''';

void main() {
  group('BahnCardArt.parse — the shape we expect', () {
    test('pulls the artwork out of the CSS data URI', () {
      final art = BahnCardArt.parse(_bildSicht());
      expect(art, isNotNull);
      expect(art!.mimeType, 'image/png');
      expect(art.imageBytes, base64Decode(_pngB64));
      // padding-top:65% of the width is the card's height.
      expect(art.aspectRatio, closeTo(1 / 0.65, 1e-9));
    });

    test('reads every text field, in document order', () {
      final art = BahnCardArt.parse(_bildSicht())!;
      expect(art.texts.map((t) => t.text), [
        'MAX MUSTERMANN',
        '7081 4270 9016 3212',
        // The entity is resolved, not left as markup.
        '01.01.2026 – 31.12.2026',
      ]);
    });

    test('geometry comes back as fractions of the card box', () {
      final art = BahnCardArt.parse(_bildSicht())!;
      final name = art.texts.first;
      expect(name.top, closeTo(0.55, 1e-9));
      expect(name.left, closeTo(0.08, 1e-9));
      expect(name.right, isNull);
      expect(name.bottom, isNull);
      // 4vw — a fraction of the WIDTH, so the text scales with the tile.
      expect(name.fontSize, closeTo(0.04, 1e-9));
      expect(name.fontWeight, FontWeight.w700);
      expect(name.color, const Color(0xFFFFFFFF));
    });

    test('bottom/right anchoring and text-align survive', () {
      final art = BahnCardArt.parse(_bildSicht())!;
      final gueltig = art.texts.last;
      expect(gueltig.bottom, closeTo(0.06, 1e-9));
      expect(gueltig.right, closeTo(0.08, 1e-9));
      expect(gueltig.top, isNull);
      expect(gueltig.textAlign, TextAlign.right);
      expect(gueltig.color, const Color.fromARGB(217, 255, 255, 255));
    });

    test('letter-spacing is scaled to the card, not to pixels', () {
      final art = BahnCardArt.parse(_bildSicht())!;
      expect(art.texts[1].letterSpacing, closeTo(0.004, 1e-9));
    });

    test('a 3-digit hex colour and shorthand weights resolve', () {
      final html = _bildSicht(
          extraCss: '.x{position:absolute;top:1%;left:1%;font-size:2vw;'
              'color:#f00;font-weight:600;}',
          extraBody: '<div class="x">RE</div>');
      final art = BahnCardArt.parse(html)!;
      final x = art.texts.firstWhere((t) => t.text == 'RE');
      expect(x.color, const Color(0xFFFF0000));
      expect(x.fontWeight, FontWeight.w600);
    });

    test('text-transform:uppercase is applied, not ignored', () {
      final html = _bildSicht(
          name: 'Max Mustermann',
          extraCss: '.name{text-transform:uppercase;}');
      final art = BahnCardArt.parse(html)!;
      expect(art.texts.first.text, 'MAX MUSTERMANN');
    });

    test('inline styles win over the stylesheet, like CSS says', () {
      final html = _bildSicht().replaceFirst(
          '<div class="name">', '<div class="name" style="left:20%;">');
      final art = BahnCardArt.parse(html)!;
      expect(art.texts.first.left, closeTo(0.20, 1e-9));
    });

    test('known entities are resolved, including the German ones', () {
      final html = _bildSicht(name: 'J&uuml;rgen Gro&szlig;');
      expect(BahnCardArt.parse(html)!.texts.first.text, 'Jürgen Groß');
    });

    test('numeric entities are resolved', () {
      final html = _bildSicht(name: '&#77;&#x41;X');
      expect(BahnCardArt.parse(html)!.texts.first.text, 'MAX');
    });

    test('inheritable text properties cascade down from the container', () {
      final html = _bildSicht(
        extraCss: '.image{color:#000000;}'
            '.plain{position:absolute;top:30%;left:30%;font-size:2vw;}',
        extraBody: '<div class="plain">INHERIT</div>',
      );
      final art = BahnCardArt.parse(html)!;
      final plain = art.texts.firstWhere((t) => t.text == 'INHERIT');
      expect(plain.color, const Color(0xFF000000));
    });
  });

  group('BahnCardArt.parse — falls back rather than guessing', () {
    // Each of these is a way DB could change the document. Every one must
    // produce null so [BahnCardView] shows the WebView: a card rendered from a
    // half-understood document is worse than a slow card.

    test('null / empty / not HTML at all', () {
      expect(BahnCardArt.parse(null), isNull);
      expect(BahnCardArt.parse(''), isNull);
      expect(BahnCardArt.parse('total garbage, not markup'), isNull);
    });

    test('no artwork in the document', () {
      expect(
          BahnCardArt.parse('<html><body><div class="x">hi</div></body></html>'),
          isNull);
    });

    test('artwork referenced by URL instead of inlined', () {
      final html = _bildSicht().replaceFirst(
          'url(data:image/png;base64,$_pngB64)', 'url(https://db.de/card.png)');
      expect(BahnCardArt.parse(html), isNull);
    });

    test('two background images — we would only paint one', () {
      final html = _bildSicht(
        extraCss: '.second{background-image:url(data:image/png;base64,$_pngB64);'
            'position:absolute;top:0;left:0;}',
        extraBody: '<div class="second"></div>',
      );
      expect(BahnCardArt.parse(html), isNull);
    });

    test('a media query — we do not know which rules apply', () {
      final html = _bildSicht(
          extraCss: '@media (min-width:600px){.name{left:20%;}}');
      expect(BahnCardArt.parse(html), isNull);
    });

    test('a descendant selector — we do not implement matching', () {
      final html = _bildSicht(extraCss: '.image .name{left:20%;}');
      expect(BahnCardArt.parse(html), isNull);
    });

    test('a pseudo-element — it could draw anything', () {
      final html = _bildSicht(extraCss: '.name::after{content:"!";}');
      expect(BahnCardArt.parse(html), isNull);
    });

    test('a transform on a text field', () {
      final html = _bildSicht(extraCss: '.name{transform:rotate(3deg);}');
      expect(BahnCardArt.parse(html), isNull);
    });

    test('a custom line-height — the baseline would shift', () {
      final html = _bildSicht(extraCss: '.name{line-height:2.4;}');
      expect(BahnCardArt.parse(html), isNull);
    });

    test('font-size in px — it would not scale with the card', () {
      final html = _bildSicht(extraCss: '.name{font-size:14px;}');
      expect(BahnCardArt.parse(html), isNull);
    });

    test('font-size in % — that is relative to the font, not the box', () {
      final html = _bildSicht(extraCss: '.name{font-size:120%;}');
      expect(BahnCardArt.parse(html), isNull);
    });

    test('a text field left in normal flow', () {
      final html = _bildSicht(extraCss: '.name{position:static;}');
      expect(BahnCardArt.parse(html), isNull);
    });

    test('a text field anchored on only one axis', () {
      final html = _bildSicht(
          extraCss: '.loose{position:absolute;left:5%;font-size:2vw;'
              'color:#000;}',
          extraBody: '<div class="loose">NO VERTICAL ANCHOR</div>');
      expect(BahnCardArt.parse(html), isNull);
    });

    test('a colour we cannot resolve', () {
      final html = _bildSicht(extraCss: '.name{color:rebeccapurple;}');
      expect(BahnCardArt.parse(html), isNull);
    });

    test('text loose inside the artwork instead of in a positioned box', () {
      final html = _bildSicht(extraBody: 'STRAY TEXT');
      expect(BahnCardArt.parse(html), isNull);
    });

    test('text outside the artwork entirely', () {
      final html =
          _bildSicht().replaceFirst('</body>', '<p>Fußnote</p></body>');
      expect(BahnCardArt.parse(html), isNull);
    });

    test('nested markup inside a text field', () {
      final html = _bildSicht(name: 'MAX <b>MUSTERMANN</b>');
      expect(BahnCardArt.parse(html), isNull);
    });

    test('an entity we do not know — it would be painted on raw', () {
      // The alternative is a BahnCard reading "MAX &thinsp; MUSTERMANN".
      final html = _bildSicht(name: 'MAX&thinsp;MUSTERMANN');
      expect(BahnCardArt.parse(html), isNull);
    });

    test('a malformed entity', () {
      expect(BahnCardArt.parse(_bildSicht(name: 'A & B')), isNull);
    });

    test('artwork with no aspect ratio to derive', () {
      final html = _bildSicht().replaceFirst('padding-top:65%;', '');
      expect(BahnCardArt.parse(html), isNull);
    });

    test('artwork wrapped in a positioned container', () {
      final html = _bildSicht()
          .replaceFirst('<body>', '<body><div class="wrap">')
          .replaceFirst('</body>', '</div></body>')
          .replaceFirst('</style>', '.wrap{position:absolute;top:10%;}</style>');
      expect(BahnCardArt.parse(html), isNull);
    });

    test('an artwork-only card — no name, no number', () {
      const html = '<html><head><style>'
          '.image{background-image:url(data:image/png;base64,$_pngB64);'
          'padding-top:65%;}'
          '</style></head><body><div class="image"></div></body></html>';
      // Half a card is not a card.
      expect(BahnCardArt.parse(html), isNull);
    });

    test('a corrupt base64 payload', () {
      final html = _bildSicht().replaceFirst(_pngB64, 'not!valid!base64!!!');
      expect(BahnCardArt.parse(html), isNull);
    });

    test('an SVG artwork — Image cannot decode it', () {
      final html = _bildSicht()
          .replaceFirst('data:image/png;base64,', 'data:image/svg+xml;base64,');
      expect(BahnCardArt.parse(html), isNull);
    });

    test('mis-nested tags', () {
      final html = _bildSicht().replaceFirst(
          '<div class="name">MAX MUSTERMANN</div>',
          '<div class="name">MAX MUSTERMANN</span>');
      expect(BahnCardArt.parse(html), isNull);
    });

    test('never throws, whatever it is handed', () {
      for (final s in [
        '<div style="',
        '<<<>>>',
        '<style>.a{',
        '<html><body><div class="image"></div>',
        'url(data:image/png;base64,)',
        '<div style="background-image:url(data:image/png;base64,${'A' * 1000})">x</div>',
      ]) {
        expect(() => BahnCardArt.parse(s), returnsNormally, reason: s);
      }
    });
  });

  group('redactBahnCardHtml', () {
    test('destroys the holder name, keeps its shape', () {
      final out = redactBahnCardHtml(_bildSicht());
      expect(out, isNot(contains('MUSTERMANN')));
      expect(out, contains('XXX XXXXXXXXXX')); // MAX MUSTERMANN
    });

    test('destroys the BahnCard number, keeps its shape', () {
      final out = redactBahnCardHtml(_bildSicht());
      expect(out, isNot(contains('7081')));
      expect(out, contains('0000 0000 0000 0000'));
    });

    test('elides the image payload and says how big it was', () {
      final out = redactBahnCardHtml(_bildSicht());
      expect(out, isNot(contains(_pngB64)));
      expect(out, contains('bytes elided'));
      // A redacted card is small enough to paste into an issue.
      expect(out.length, lessThan(_bildSicht().length));
    });

    test('keeps the CSS — that is the whole point of the export', () {
      final out = redactBahnCardHtml(_bildSicht());
      expect(out, contains('padding-top:65%'));
      expect(out, contains('position:absolute'));
      expect(out, contains('font-size:4vw'));
      expect(out, contains('class="name"'));
    });

    test('masks alt/title attributes — they can name the holder', () {
      final out = redactBahnCardHtml(
          '<img alt="BahnCard von Max Mustermann" src="x.png">');
      expect(out, isNot(contains('Mustermann')));
      expect(out, contains('alt='));
    });

    test('leaves HTML entities intact', () {
      expect(redactBahnCardHtml('<div>a&nbsp;b</div>'), contains('&nbsp;'));
    });
  });
}
