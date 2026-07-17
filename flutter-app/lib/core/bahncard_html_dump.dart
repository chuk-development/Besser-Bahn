/// Turns DB's BahnCard HTML into something safe to send to a developer.
///
/// [BahnCardArt] has to recognise DB's exact markup, and nobody can write that
/// parser against a document they've never seen — but the document is somebody's
/// BahnCard: their name, their card number, their photo-grade artwork. This
/// keeps the half that matters for the parser (the element tree, every CSS
/// declaration, the data URI's media type and size) and destroys the half that
/// identifies the holder (all text content, all image bytes).
///
/// The redaction is length-preserving where it can be, because "the name field
/// holds 17 characters" is exactly the kind of detail that explains a layout
/// bug, while the characters themselves are none of our business.
library;

/// Redacts [html] for sharing: text content → `X`, base64 payloads → a
/// `<N bytes elided>` note. Structure and CSS survive verbatim.
String redactBahnCardHtml(String html) {
  // `<style>` blocks are the point of the export, so they're carried through
  // untouched apart from their embedded image payloads. Everything outside them
  // gets its text stripped.
  final out = StringBuffer();
  final styleRe = RegExp(r'<style[^>]*>[\s\S]*?</style>', caseSensitive: false);
  var pos = 0;
  for (final m in styleRe.allMatches(html)) {
    out.write(_redactText(html.substring(pos, m.start)));
    out.write(_elideBase64(m.group(0)!));
    pos = m.end;
  }
  out.write(_redactText(html.substring(pos)));
  return _elideBase64(out.toString());
}

/// Replaces every base64 data-URI payload with its byte count. This is what
/// takes the export from ~283 KB to a few KB, and it's what makes it not a
/// BahnCard any more.
String _elideBase64(String src) => src.replaceAllMapped(
      RegExp(r'(data:[a-zA-Z0-9/.+-]*;base64,)([A-Za-z0-9+/=\s]+)'),
      (m) {
        final payload = m.group(2)!.replaceAll(RegExp(r'\s'), '');
        // 4 base64 chars ≈ 3 bytes; close enough to say how big the artwork is.
        final bytes = (payload.length * 3) ~/ 4;
        return '${m.group(1)}<<<$bytes bytes elided>>>';
      },
    );

/// Blanks the text between tags, keeping its length and shape so field widths
/// stay diagnosable. Attribute values are left alone: `class`/`style` are the
/// layout, and DB doesn't put the holder's name in them — but see
/// [_redactAttrText] for the ones that could carry copy.
String _redactText(String src) {
  final out = StringBuffer();
  var pos = 0;
  final tagRe = RegExp(r'''<[^>]*>''');
  for (final m in tagRe.allMatches(src)) {
    out.write(_mask(src.substring(pos, m.start)));
    out.write(_redactAttrText(m.group(0)!));
    pos = m.end;
  }
  out.write(_mask(src.substring(pos)));
  return out.toString();
}

/// `alt`/`title`/`aria-label` are human copy and can name the holder.
String _redactAttrText(String tag) => tag.replaceAllMapped(
      RegExp('''((?:alt|title|aria-label)\\s*=\\s*)(?:"([^"]*)"|'([^']*)')''',
          caseSensitive: false),
      (m) => '${m.group(1)}"${_mask(m.group(2) ?? m.group(3) ?? '')}"',
    );

/// Letters → `X`, digits → `0`; punctuation and whitespace stay, so the shape
/// of a card number (`0000 0000 0000 0000`) or a date (`00.00.0000`) is still
/// visible without disclosing one. HTML entities pass through intact — they're
/// markup, and the parser's whitespace handling turns on them.
String _mask(String s) {
  final entity = RegExp(r'&[a-zA-Z][a-zA-Z0-9]*;|&#[0-9]+;');
  final out = StringBuffer();
  var pos = 0;
  for (final m in entity.allMatches(s)) {
    out.write(_maskChars(s.substring(pos, m.start)));
    out.write(m.group(0));
    pos = m.end;
  }
  out.write(_maskChars(s.substring(pos)));
  return out.toString();
}

String _maskChars(String s) => s.replaceAllMapped(
      RegExp(r'[^\s\W_]'),
      (m) => RegExp(r'\d').hasMatch(m.group(0)!) ? '0' : 'X',
    );
