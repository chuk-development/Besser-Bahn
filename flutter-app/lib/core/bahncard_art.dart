import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/painting.dart';

/// Parses DB's BahnCard `bildSicht` HTML into something Flutter can paint
/// natively — the card artwork (a base64 image inside a CSS `background-image`)
/// plus the CSS-positioned text fields DB lays over it.
///
/// **Why this exists.** `bildSicht` is a ~283 KB HTML document, and rendering it
/// meant standing up a platform WebView and re-parsing a quarter megabyte of
/// base64 on every single build. That is the whole reason the card takes a
/// visible moment to appear: the bytes are already on disk (`_BahnCardCache`),
/// the *renderer* is what's slow. Decoded once into real PNG bytes and painted
/// with a plain [Image], the card is up on the first frame.
///
/// **Why it is allowed to fail.** DB owns this HTML and can change it whenever
/// they like. Every unknown produces `null` from [BahnCardArt.parse] rather than
/// a guess, and the caller falls back to the WebView that renders DB's markup
/// verbatim. A card that is subtly wrong — a name in the wrong place, a missing
/// number — is worse than a card that took 300 ms, so the parser refuses
/// anything it cannot account for completely:
///
/// * exactly one element may carry a `background-image` data URI (the artwork);
/// * every other scrap of text in the document must sit in an absolutely
///   positioned element whose geometry we fully understand;
/// * any CSS we don't model (media queries, pseudo-elements, combinators,
///   transforms, ambiguous units) fails the whole parse.
///
/// This is deliberately a *recogniser*, not a rendering engine. It matches the
/// one document shape DB serves; anything else is the WebView's problem.
class BahnCardArt {
  /// Decoded artwork bytes (PNG/JPEG/WebP — whatever the data URI declared).
  final Uint8List imageBytes;

  /// The data URI's media type, e.g. `image/png`.
  final String mimeType;

  /// Text fields painted over [imageBytes], in document order.
  final List<BahnCardTextBox> texts;

  /// width / height of the card box, from the artwork element's
  /// `padding-top: NN%` (the CSS idiom DB uses to give the div its ratio).
  final double aspectRatio;

  const BahnCardArt({
    required this.imageBytes,
    required this.mimeType,
    required this.texts,
    required this.aspectRatio,
  });

  /// Parses [html]; returns null if anything about the document is unfamiliar.
  /// Never throws — a malformed payload is just a fallback, not a crash.
  static BahnCardArt? parse(String? html) {
    if (html == null || html.isEmpty) return null;
    try {
      return _BahnCardArtParser(html).run();
    } catch (_) {
      // Defensive: the parser signals failure with null, but a genuinely
      // pathological document must still degrade to the WebView, not throw
      // out of a widget build.
      return null;
    }
  }
}

/// One CSS-positioned text field over the card artwork.
///
/// Every measurement is a **fraction of the card box** rather than a pixel
/// value, because the card is drawn at whatever width the tile happens to be.
/// Horizontal values are fractions of the box width, vertical ones of its
/// height; [fontSize] and [letterSpacing] are fractions of the width (that's
/// what `vw` means, and it's the only way the text scales with the card).
class BahnCardTextBox {
  final String text;

  /// Distance from the respective edge, 0..1. At least one of [left]/[right]
  /// and one of [top]/[bottom] is non-null — the parser rejects anything less.
  final double? left;
  final double? top;
  final double? right;
  final double? bottom;

  /// Fraction of the card's width.
  final double fontSize;

  final Color color;
  final FontWeight fontWeight;
  final FontStyle fontStyle;
  final TextAlign textAlign;

  /// Fraction of the card's width, or null when CSS didn't set it.
  final double? letterSpacing;

  const BahnCardTextBox({
    required this.text,
    required this.fontSize,
    required this.color,
    this.left,
    this.top,
    this.right,
    this.bottom,
    this.fontWeight = FontWeight.normal,
    this.fontStyle = FontStyle.normal,
    this.textAlign = TextAlign.start,
    this.letterSpacing,
  });
}

// ---------------------------------------------------------------------------
// Parser internals
// ---------------------------------------------------------------------------

/// Properties that move or resize a box. If one of these shows up with a value
/// we can't resolve, the layout we'd produce is a guess — so we bail instead.
const _kLayoutCritical = {
  'position',
  'top',
  'left',
  'right',
  'bottom',
  'width',
  'height',
  'transform',
  'margin',
  'margin-top',
  'margin-left',
  'margin-right',
  'margin-bottom',
  'padding',
  'padding-left',
  'padding-right',
  'padding-bottom',
  'font-size',
  'writing-mode',
  'zoom',
  'scale',
  'rotate',
  'translate',
};

class _BahnCardArtParser {
  _BahnCardArtParser(this.html);

  final String html;

  /// Selector → declarations, in source order.
  final List<_Rule> _rules = [];

  BahnCardArt? run() {
    if (!_collectStyleSheets()) return null;

    final root = _parseNodes(_stripStyleAndScript(html));
    if (root == null) return null;

    // --- artwork ----------------------------------------------------------
    final artNodes = <_Element>[];
    _walk(root, (n) {
      final bg = _resolved(n)['background-image'];
      if (bg != null && _dataUri(bg) != null) artNodes.add(n);
    });
    if (artNodes.length != 1) return null; // zero or ambiguous → WebView
    final art = artNodes.single;
    final artStyle = _resolved(art);

    final uri = _dataUri(artStyle['background-image']!);
    if (uri == null) return null;
    final decoded = _decodeDataUri(uri);
    if (decoded == null) return null;

    // The artwork must be the outermost styled box. If it sits inside another
    // positioned/sized element, our "card box == artwork box" assumption — the
    // basis of every percentage below — is wrong.
    if (_hasStyledAncestor(art)) return null;

    final aspect = _aspectOf(artStyle);
    if (aspect == null) return null;

    // --- text -------------------------------------------------------------
    // Every non-blank piece of text in the document has to end up in a box we
    // understand. Text outside the artwork, or loose inside it, means the
    // document isn't the shape we think it is.
    final texts = <BahnCardTextBox>[];
    final claimed = <_Element>{};

    for (final child in art.children.whereType<_Element>()) {
      if (!_hasText(child)) continue;
      // An overlay must be a leaf-ish box: its own text, no nested elements
      // that could carry their own styling we'd have to cascade.
      if (child.children.any((c) => c is _Element)) return null;
      final box = _textBox(child);
      if (box == null) return null;
      texts.add(box);
      claimed.add(child);
    }

    // Loose text directly under the artwork (not wrapped in a positioned box).
    for (final c in art.children) {
      if (c is _Text && c.text.trim().isNotEmpty) return null;
    }

    // Any text anywhere else in the document.
    var stray = false;
    _walk(root, (n) {
      if (stray || n == art || claimed.contains(n)) return;
      if (_isAncestorOf(n, art)) return; // html/body wrappers
      for (final c in n.children) {
        if (c is _Text && c.text.trim().isNotEmpty) stray = true;
      }
    });
    if (stray) return null;

    if (texts.isEmpty) return null; // a card with no name/number is half a card

    return BahnCardArt(
      imageBytes: decoded.bytes,
      mimeType: decoded.mime,
      texts: texts,
      aspectRatio: aspect,
    );
  }

  // --- stylesheet -----------------------------------------------------------

  /// Parses every `<style>` block. Returns false when the sheet uses anything
  /// outside the simple `tag` / `.class` / `#id` vocabulary we model.
  bool _collectStyleSheets() {
    final re = RegExp(r'<style[^>]*>([\s\S]*?)</style>', caseSensitive: false);
    for (final m in re.allMatches(html)) {
      final css = _stripCssComments(m.group(1) ?? '');
      // At-rules (@media, @supports, @font-face) nest braces and change what
      // applies when — out of scope, and silently ignoring them would render
      // the wrong thing.
      if (css.contains('@')) return false;
      var i = 0;
      while (i < css.length) {
        final open = css.indexOf('{', i);
        if (open < 0) {
          if (css.substring(i).trim().isNotEmpty) return false;
          break;
        }
        final close = css.indexOf('}', open);
        if (close < 0) return false;
        final selectors = css.substring(i, open);
        final decls = _parseDecls(css.substring(open + 1, close));
        if (decls == null) return false;
        for (final sel in selectors.split(',')) {
          final s = sel.trim();
          if (s.isEmpty) return false;
          if (!_isSimpleSelector(s)) return false;
          _rules.add(_Rule(s, decls));
        }
        i = close + 1;
      }
    }
    return true;
  }

  /// `div`, `.name`, `#foo`, `*`. Anything with a combinator, pseudo-class,
  /// attribute test or compound form is rejected: we'd have to implement real
  /// matching to know whether it applies.
  static bool _isSimpleSelector(String s) =>
      RegExp(r'^(\*|[a-zA-Z][a-zA-Z0-9]*|\.[-_a-zA-Z][-_a-zA-Z0-9]*|#[-_a-zA-Z][-_a-zA-Z0-9]*)$')
          .hasMatch(s);

  /// Cascade for [n]: `*`/tag rules, then class rules, then id rules, then the
  /// inline `style` attribute. Mirrors CSS specificity ordering for the simple
  /// selectors we accept, so later writes legitimately win.
  Map<String, String> _resolved(_Element n) {
    if (n.resolved != null) return n.resolved!;
    final out = <String, String>{};
    final classes = (n.attrs['class'] ?? '').split(RegExp(r'\s+')).toSet();
    final id = n.attrs['id'];

    for (final pass in const [0, 1, 2]) {
      for (final r in _rules) {
        final sel = r.selector;
        final matches = switch (pass) {
          0 => sel == '*' || sel == n.tag,
          1 => sel.startsWith('.') && classes.contains(sel.substring(1)),
          _ => sel.startsWith('#') && id != null && sel.substring(1) == id,
        };
        if (matches) out.addAll(r.decls);
      }
    }
    final inline = n.attrs['style'];
    if (inline != null) {
      final decls = _parseDecls(inline);
      if (decls != null) out.addAll(decls);
    }
    // Inherited text properties: an overlay usually only sets what differs from
    // the container, so pull the inheritable ones down from the ancestors.
    for (var p = n.parent; p != null; p = p.parent) {
      final up = _resolved(p);
      for (final prop in const [
        'color',
        'font-size',
        'font-weight',
        'font-style',
        'text-align',
        'letter-spacing',
        'text-transform',
        'font-family',
        'line-height',
      ]) {
        final v = up[prop];
        if (v != null) out.putIfAbsent(prop, () => v);
      }
    }
    return n.resolved = out;
  }

  // --- artwork helpers ------------------------------------------------------

  /// DB gives the artwork div its shape with `padding-top: NN%` — a percentage
  /// of the *width*, so it's the aspect ratio. Absent, we can't know the shape.
  static double? _aspectOf(Map<String, String> style) {
    final pt = style['padding-top'] ?? style['padding-bottom'];
    if (pt == null) return null;
    final pct = _percent(pt);
    if (pct == null || pct <= 0) return null;
    return 1 / pct;
  }

  bool _hasStyledAncestor(_Element n) {
    for (var p = n.parent; p != null; p = p.parent) {
      final style = _resolved(p);
      for (final prop in _kLayoutCritical) {
        final v = style[prop];
        if (v == null) continue;
        // `margin:0` / `padding:0` on html/body is the usual reset and moves
        // nothing; anything else above the artwork we refuse to reason about.
        if (_isZeroish(v)) continue;
        return true;
      }
    }
    return false;
  }

  static bool _isZeroish(String v) {
    final t = v.trim().toLowerCase().replaceAll('!important', '').trim();
    return t == '0' ||
        t == '0px' ||
        t == '0%' ||
        t == 'none' ||
        t == 'static' ||
        RegExp(r'^(0(px|%|em|rem)?\s*)+$').hasMatch(t);
  }

  // --- text boxes -----------------------------------------------------------

  BahnCardTextBox? _textBox(_Element n) {
    final style = _resolved(n);

    // Only absolute positioning is modelled. Static/relative flow would need a
    // layout engine to place.
    final pos = _bare(style['position']);
    if (pos != 'absolute') return null;

    // Anything that would move or reshape the box beyond the four offsets.
    for (final prop in const [
      'transform',
      'writing-mode',
      'zoom',
      'scale',
      'rotate',
      'translate',
    ]) {
      if (style[prop] != null && !_isZeroish(style[prop]!)) return null;
    }

    // `line-height` shifts the glyphs inside the box, so ignoring a custom one
    // would put the text at the right box but the wrong baseline. We render
    // with the font's natural metrics, which is what `normal` means.
    final lineHeight = _bare(style['line-height']);
    if (lineHeight != null && lineHeight != 'normal') return null;

    final left = _fracH(style['left']);
    final right = _fracH(style['right']);
    final top = _fracV(style['top']);
    final bottom = _fracV(style['bottom']);
    if (style['left'] != null && left == null) return null;
    if (style['right'] != null && right == null) return null;
    if (style['top'] != null && top == null) return null;
    if (style['bottom'] != null && bottom == null) return null;
    // Unanchored on an axis means the browser resolves it from static
    // position — i.e. flow layout again.
    if (left == null && right == null) return null;
    if (top == null && bottom == null) return null;

    final size = _fontSize(style['font-size']);
    if (size == null) return null;

    final color = _color(style['color']);
    if (color == null) return null;

    var text = _textOf(n);
    if (text == null) return null; // unresolvable entity — see _decodeEntities
    final transform = _bare(style['text-transform']);
    if (transform == 'uppercase') {
      text = text.toUpperCase();
    } else if (transform == 'lowercase') {
      text = text.toLowerCase();
    } else if (transform != null && transform != 'none') {
      return null; // capitalize/full-width — not worth approximating
    }
    if (text.trim().isEmpty) return null;

    double? spacing;
    if (style['letter-spacing'] != null &&
        !_isZeroish(style['letter-spacing']!) &&
        _bare(style['letter-spacing']) != 'normal') {
      spacing = _fracH(style['letter-spacing']);
      if (spacing == null) return null;
    }

    return BahnCardTextBox(
      text: text,
      left: left,
      top: top,
      right: right,
      bottom: bottom,
      fontSize: size,
      color: color,
      fontWeight: _weight(style['font-weight']),
      fontStyle:
          _bare(style['font-style']) == 'italic' ? FontStyle.italic : FontStyle.normal,
      textAlign: switch (_bare(style['text-align'])) {
        'center' => TextAlign.center,
        'right' => TextAlign.right,
        'left' => TextAlign.left,
        _ => TextAlign.start,
      },
      letterSpacing: spacing,
    );
  }

  /// Horizontal length as a fraction of the card width. `%` and `vw` both
  /// resolve against the card box (the artwork *is* the viewport). `px` and
  /// friends are absolute and would not scale with the tile — rejected.
  static double? _fracH(String? v) => _viewportFrac(v, const ['%', 'vw']);

  /// Vertical length as a fraction of the card height. Note `%` here is of the
  /// containing block's height, and `vh` of the viewport's — the same box.
  static double? _fracV(String? v) => _viewportFrac(v, const ['%', 'vh']);

  static double? _viewportFrac(String? v, List<String> units) {
    if (v == null) return null;
    final t = _bare(v);
    if (t == null) return null;
    for (final u in units) {
      if (t.endsWith(u)) {
        final n = double.tryParse(t.substring(0, t.length - u.length).trim());
        if (n == null) return null;
        return n / 100;
      }
    }
    return null;
  }

  /// Font size as a fraction of the card width. Only `vw` says that
  /// unambiguously. `%`/`em` are relative to the *inherited font size*, not the
  /// box — a completely different quantity — and `px` is fixed while our card
  /// is not, so both are rejected rather than guessed at.
  static double? _fontSize(String? v) => _viewportFrac(v, const ['vw']);

  static FontWeight _weight(String? v) {
    final t = _bare(v);
    return switch (t) {
      'bold' || 'bolder' || '700' => FontWeight.w700,
      '100' => FontWeight.w100,
      '200' => FontWeight.w200,
      '300' || 'lighter' => FontWeight.w300,
      '400' || 'normal' => FontWeight.w400,
      '500' => FontWeight.w500,
      '600' => FontWeight.w600,
      '800' => FontWeight.w800,
      '900' => FontWeight.w900,
      _ => FontWeight.w400,
    };
  }

  static Color? _color(String? v) {
    var t = _bare(v);
    if (t == null) return null;
    if (t.startsWith('#')) {
      final hex = t.substring(1);
      String full;
      if (hex.length == 3) {
        full = 'ff${hex[0]}${hex[0]}${hex[1]}${hex[1]}${hex[2]}${hex[2]}';
      } else if (hex.length == 6) {
        full = 'ff$hex';
      } else if (hex.length == 8) {
        // CSS #RRGGBBAA → Flutter wants AARRGGBB.
        full = '${hex.substring(6)}${hex.substring(0, 6)}';
      } else {
        return null;
      }
      final n = int.tryParse(full, radix: 16);
      return n == null ? null : Color(n);
    }
    final rgb = RegExp(r'^rgba?\(([^)]*)\)$').firstMatch(t);
    if (rgb != null) {
      final parts = rgb.group(1)!.split(RegExp('[,/ ]+')).where((s) => s.isNotEmpty).toList();
      if (parts.length < 3) return null;
      final vals = <int>[];
      for (var i = 0; i < 3; i++) {
        final n = double.tryParse(parts[i]);
        if (n == null) return null;
        vals.add(n.round().clamp(0, 255));
      }
      var a = 255;
      if (parts.length > 3) {
        final n = double.tryParse(parts[3].replaceAll('%', ''));
        if (n == null) return null;
        a = (parts[3].contains('%') ? n / 100 * 255 : n * 255).round().clamp(0, 255);
      }
      return Color.fromARGB(a, vals[0], vals[1], vals[2]);
    }
    return switch (t) {
      'black' => const Color(0xFF000000),
      'white' => const Color(0xFFFFFFFF),
      'red' => const Color(0xFFFF0000),
      'gray' || 'grey' => const Color(0xFF808080),
      _ => null, // named colours beyond these → we're guessing
    };
  }

  static double? _percent(String v) {
    final t = _bare(v);
    if (t == null || !t.endsWith('%')) return null;
    final n = double.tryParse(t.substring(0, t.length - 1).trim());
    return n == null ? null : n / 100;
  }

  static String? _bare(String? v) {
    if (v == null) return null;
    final t = v.replaceAll('!important', '').trim().toLowerCase();
    return t.isEmpty ? null : t;
  }

  // --- data URIs ------------------------------------------------------------

  /// Pulls the `data:` URI out of a `background-image` value. Rejects a value
  /// with more than one layer — we'd only paint the first.
  static String? _dataUri(String value) {
    final urls = RegExp(r'url\(\s*(?:"([^"]*)"|' r"'([^']*)'" r'|([^)]*))\s*\)')
        .allMatches(value)
        .map((m) => (m.group(1) ?? m.group(2) ?? m.group(3) ?? '').trim())
        .toList();
    if (urls.length != 1) return null;
    final u = urls.single;
    return u.startsWith('data:image/') ? u : null;
  }

  static ({Uint8List bytes, String mime})? _decodeDataUri(String uri) {
    final comma = uri.indexOf(',');
    if (comma < 0) return null;
    final header = uri.substring(5, comma); // strip 'data:'
    if (!header.contains(';base64')) return null;
    final mime = header.split(';').first;
    if (!const {'image/png', 'image/jpeg', 'image/jpg', 'image/webp'}
        .contains(mime)) {
      return null;
    }
    try {
      // Base64 in CSS is routinely line-wrapped; the decoder won't take that.
      final raw = uri.substring(comma + 1).replaceAll(RegExp(r'\s'), '');
      final bytes = base64Decode(raw);
      if (bytes.isEmpty) return null;
      return (bytes: bytes, mime: mime);
    } catch (_) {
      return null;
    }
  }

  // --- CSS text helpers -----------------------------------------------------

  static String _stripCssComments(String css) =>
      css.replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '');

  /// Splits `a:b; c:d` respecting parens and quotes — a `background-image` data
  /// URI is full of `;` and `:` that must not be treated as separators.
  static Map<String, String>? _parseDecls(String src) {
    final out = <String, String>{};
    for (final decl in _splitTop(src, ';')) {
      final d = decl.trim();
      if (d.isEmpty) continue;
      final colon = _indexOfTop(d, ':');
      if (colon <= 0) return null;
      final prop = d.substring(0, colon).trim().toLowerCase();
      final value = d.substring(colon + 1).trim();
      if (prop.isEmpty || value.isEmpty) return null;
      out[prop] = value;
    }
    return out;
  }

  static List<String> _splitTop(String s, String sep) {
    final out = <String>[];
    var depth = 0;
    String? quote;
    var start = 0;
    for (var i = 0; i < s.length; i++) {
      final c = s[i];
      if (quote != null) {
        if (c == quote) quote = null;
        continue;
      }
      if (c == '"' || c == "'") {
        quote = c;
      } else if (c == '(') {
        depth++;
      } else if (c == ')') {
        if (depth > 0) depth--;
      } else if (c == sep && depth == 0) {
        out.add(s.substring(start, i));
        start = i + 1;
      }
    }
    out.add(s.substring(start));
    return out;
  }

  static int _indexOfTop(String s, String needle) {
    var depth = 0;
    String? quote;
    for (var i = 0; i < s.length; i++) {
      final c = s[i];
      if (quote != null) {
        if (c == quote) quote = null;
        continue;
      }
      if (c == '"' || c == "'") {
        quote = c;
      } else if (c == '(') {
        depth++;
      } else if (c == ')') {
        if (depth > 0) depth--;
      } else if (c == needle && depth == 0) {
        return i;
      }
    }
    return -1;
  }

  // --- HTML -----------------------------------------------------------------

  static String _stripStyleAndScript(String src) => src
      .replaceAll(RegExp(r'<style[^>]*>[\s\S]*?</style>', caseSensitive: false), '')
      .replaceAll(RegExp(r'<script[^>]*>[\s\S]*?</script>', caseSensitive: false), '')
      .replaceAll(RegExp(r'<!--[\s\S]*?-->'), '')
      .replaceAll(RegExp(r'<!doctype[^>]*>', caseSensitive: false), '');

  static const _voidTags = {
    'img', 'br', 'hr', 'meta', 'link', 'input', 'source', 'area', 'base', 'col',
  };

  /// A deliberately small HTML reader: enough for the static, generated markup
  /// DB serves, and it returns null the moment the document does something a
  /// real browser would have to recover from (stray close tags, bad nesting).
  static _Element? _parseNodes(String src) {
    final root = _Element('#root', const {});
    final stack = <_Element>[root];
    final tagRe = RegExp(
      r'''<\s*(/?)\s*([a-zA-Z][a-zA-Z0-9]*)((?:[^>"']|"[^"]*"|'[^']*')*?)(/?)\s*>''',
    );
    var pos = 0;
    for (final m in tagRe.allMatches(src)) {
      if (m.start > pos) {
        final text = src.substring(pos, m.start);
        if (text.trim().isNotEmpty) stack.last.children.add(_Text(text));
      }
      pos = m.end;
      final closing = m.group(1) == '/';
      final tag = m.group(2)!.toLowerCase();
      final selfClosing = m.group(4) == '/';

      if (closing) {
        if (stack.length < 2) return null; // close without open
        if (stack.last.tag != tag) return null; // mis-nested
        stack.removeLast();
        continue;
      }
      final attrs = _parseAttrs(m.group(3) ?? '');
      if (attrs == null) return null;
      final el = _Element(tag, attrs)..parent = stack.last;
      stack.last.children.add(el);
      if (!selfClosing && !_voidTags.contains(tag)) stack.add(el);
    }
    if (pos < src.length && src.substring(pos).trim().isNotEmpty) {
      stack.last.children.add(_Text(src.substring(pos)));
    }
    if (stack.length != 1) return null; // unclosed tags
    return root;
  }

  static Map<String, String>? _parseAttrs(String src) {
    final out = <String, String>{};
    final re = RegExp(
      r'''([a-zA-Z_:][-a-zA-Z0-9_:.]*)\s*(?:=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+)))?''',
    );
    for (final m in re.allMatches(src)) {
      final name = m.group(1);
      if (name == null) continue;
      out[name.toLowerCase()] = m.group(2) ?? m.group(3) ?? m.group(4) ?? '';
    }
    return out;
  }

  static void _walk(_Element n, void Function(_Element) fn) {
    for (final c in n.children) {
      if (c is _Element) {
        fn(c);
        _walk(c, fn);
      }
    }
  }

  static bool _isAncestorOf(_Element maybeAncestor, _Element n) {
    for (var p = n.parent; p != null; p = p.parent) {
      if (p == maybeAncestor) return true;
    }
    return false;
  }

  static bool _hasText(_Element n) {
    var found = false;
    if (n.children.any((c) => c is _Text && c.text.trim().isNotEmpty)) return true;
    _walk(n, (c) {
      if (c.children.any((t) => t is _Text && t.text.trim().isNotEmpty)) {
        found = true;
      }
    });
    return found;
  }

  /// The named entities we resolve. Anything outside this table fails the
  /// parse — an entity we don't know would otherwise be painted onto the card
  /// verbatim, and `01.01.2026 &ndash; 31.12.2026` across someone's BahnCard is
  /// precisely the kind of half-right rendering this parser exists to avoid.
  static const _entities = {
    'nbsp': '\u{00A0}',
    'amp': '&',
    'lt': '<',
    'gt': '>',
    'quot': '"',
    'apos': "'",
    'ndash': '–',
    'mdash': '—',
    'middot': '·',
    'bull': '•',
    'euro': '€',
    'auml': 'ä',
    'ouml': 'ö',
    'uuml': 'ü',
    'Auml': 'Ä',
    'Ouml': 'Ö',
    'Uuml': 'Ü',
    'szlig': 'ß',
    'reg': '®',
    'copy': '©',
    'deg': '°',
    'hellip': '…',
  };

  /// Text content of [n] with HTML whitespace collapsing applied, or null when
  /// it holds an entity we can't resolve.
  static String? _textOf(_Element n) {
    final buf = StringBuffer();
    void rec(_Element e) {
      for (final c in e.children) {
        if (c is _Text) {
          buf.write(c.text);
        } else if (c is _Element) {
          rec(c);
        }
      }
    }

    rec(n);
    final decoded = _decodeEntities(buf.toString());
    if (decoded == null) return null;
    // Collapse runs of whitespace the way an HTML renderer does. A decoded
    // NBSP is deliberately NOT collapsed — DB uses it to hold spacing.
    return decoded.replaceAll(RegExp(r'[ \t\r\n]+'), ' ').trim();
  }

  static String? _decodeEntities(String s) {
    final re = RegExp(r'&(#x?[0-9a-fA-F]+|[a-zA-Z][a-zA-Z0-9]*);');
    final out = StringBuffer();
    var pos = 0;
    for (final m in re.allMatches(s)) {
      out.write(s.substring(pos, m.start));
      final body = m.group(1)!;
      if (body.startsWith('#')) {
        final isHex = body.length > 1 && (body[1] == 'x' || body[1] == 'X');
        final digits = isHex ? body.substring(2) : body.substring(1);
        final code = int.tryParse(digits, radix: isHex ? 16 : 10);
        if (code == null || code <= 0 || code > 0x10FFFF) return null;
        out.writeCharCode(code);
      } else {
        final v = _entities[body];
        if (v == null) return null; // unknown → refuse; never paint it raw
        out.write(v);
      }
      pos = m.end;
    }
    out.write(s.substring(pos));
    // A surviving bare `&` means either a malformed entity or markup we don't
    // understand. Either way, not our document.
    final result = out.toString();
    return result.contains('&') ? null : result;
  }
}

class _Rule {
  _Rule(this.selector, this.decls);
  final String selector;
  final Map<String, String> decls;
}

abstract class _NodeBase {}

class _Text extends _NodeBase {
  _Text(this.text);
  final String text;
}

class _Element extends _NodeBase {
  _Element(this.tag, this.attrs);
  final String tag;
  final Map<String, String> attrs;
  final List<_NodeBase> children = [];
  _Element? parent;
  Map<String, String>? resolved;
}
