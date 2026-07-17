import 'dart:async' show Completer, unawaited;
import 'dart:convert' show utf8;
import 'dart:io';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

import '../models/db_account.dart';
import 'app_log.dart';
import 'bahncard_art.dart';

/// Keeps the BahnCard artwork ready to paint.
///
/// Two layers, for two different costs:
///
/// * **Memory** — [of] parses a card's `bildSicht` once per launch and hands
///   back the same [BahnCardArt] forever after. This is what makes the card
///   instant: the widget can ask for the artwork *during build* and get it
///   synchronously, so there is no async gap and no placeholder frame. Without
///   it, every rebuild re-decoded ~283 KB of base64.
/// * **Disk** — the decoded image bytes are written out as a real file, so
///   [warm] can push them into Flutter's image cache (and warm the OS page
///   cache) before the Profil tab is ever opened. The base64 stays in
///   SharedPreferences where the rest of the card lives, but it is decoded at
///   most once per card per device, not once per frame.
///
/// The disk copy is wiped on logout along with every other personal cache: the
/// artwork carries the holder's card design, and the parsed text boxes carry
/// their name and BahnCard number.
class BahnCardArtCache {
  BahnCardArtCache._();

  /// Bump when the on-disk layout changes; a mismatch is a miss, not a
  /// migration (same rule as the app's other disk caches).
  static const _diskVersion = 1;

  static final Map<String, BahnCardArt?> _mem = {};

  /// Cache identity: the card plus a digest of the exact HTML it came from, so
  /// a rotated / re-issued card can never serve the previous artwork.
  static String cacheKey(DbBahnCard card) {
    final html = card.bildSichtHtml ?? '';
    final digest = sha256.convert(utf8.encode(html)).toString().substring(0, 16);
    final nummer = card.nummer.isEmpty ? 'anon' : card.nummer;
    return '${sha256.convert(utf8.encode(nummer)).toString().substring(0, 12)}_$digest';
  }

  /// The parsed artwork for [card], or null when the HTML isn't a shape we
  /// recognise (→ caller falls back to the WebView).
  ///
  /// Synchronous on purpose — see the class doc. The first call for a card
  /// pays the parse (single-digit milliseconds; the base64 decode dominates),
  /// every later call is a map lookup.
  static BahnCardArt? of(DbBahnCard card) {
    final key = cacheKey(card);
    if (_mem.containsKey(key)) return _mem[key];
    final art = BahnCardArt.parse(card.bildSichtHtml);
    _mem[key] = art;
    if (art == null) {
      AppLog.log('bahncard art: bildSicht not parseable → WebView fallback',
          tag: 'db-account');
    } else {
      AppLog.log(
          'bahncard art: parsed ${art.imageBytes.length}B ${art.mimeType}, '
          '${art.texts.length} text box(es)',
          tag: 'db-account');
      // Best-effort; the memory copy is what renders, disk is just a head start
      // for the next cold launch.
      unawaited(_persist(key, art));
    }
    return art;
  }

  /// Parse + decode + push into Flutter's image cache, so the first frame that
  /// shows a card already has a decoded texture to blit.
  ///
  /// Called when the BahnCards land rather than when the Profil tab builds:
  /// by then a [BahnCardView] is being built in the same frame and would
  /// resolve the image itself anyway, so warming there buys nothing. Warming
  /// at the source means the decode has usually finished long before the user
  /// taps Profil.
  ///
  /// Context-free on purpose ([ImageConfiguration.empty] is enough — these are
  /// raw bytes, with no asset variant or device-pixel-ratio bucket to pick),
  /// which is what lets a provider call it. Safe to call repeatedly; the parse
  /// is memoised and a resident image resolves instantly. Failures are
  /// swallowed: a cold cache costs milliseconds later, it must never break the
  /// account load.
  static Future<void> warm(Iterable<DbBahnCard> cards) async {
    for (final card in cards) {
      try {
        final art = of(card);
        if (art == null) continue;
        final completer = Completer<void>();
        final stream = imageProviderFor(art).resolve(ImageConfiguration.empty);
        late final ImageStreamListener listener;
        listener = ImageStreamListener(
          (_, _) {
            stream.removeListener(listener);
            if (!completer.isCompleted) completer.complete();
          },
          onError: (e, _) {
            stream.removeListener(listener);
            if (!completer.isCompleted) completer.complete();
            AppLog.log('bahncard art decode failed: $e', tag: 'db-account');
          },
        );
        stream.addListener(listener);
        await completer.future;
      } catch (e) {
        AppLog.log('bahncard art warm failed: $e', tag: 'db-account');
      }
    }
  }

  /// The provider the card widget paints. Keyed on the memoised byte list, so
  /// Flutter's image cache resolves it to the same decoded texture every time
  /// rather than re-decoding the PNG per rebuild.
  static ImageProvider imageProviderFor(BahnCardArt art) =>
      MemoryImage(art.imageBytes);

  /// Drops every parsed card from memory and every decoded image from disk.
  /// Called on logout: the artwork and the parsed name/number are as personal
  /// as the rest of the account cache.
  static Future<void> clear() async {
    _mem.clear();
    try {
      final dir = await _dir();
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {/* best effort */}
  }

  /// Total bytes held on disk — reported by the offline/storage screens.
  static Future<int> diskBytes() async {
    try {
      final dir = await _dir();
      if (!await dir.exists()) return 0;
      var total = 0;
      await for (final e in dir.list()) {
        if (e is File) total += await e.length();
      }
      return total;
    } catch (_) {
      return 0;
    }
  }

  /// The decoded image on disk for [key], if a previous launch wrote one.
  /// Exposed for tests and the debug export.
  static Future<Uint8List?> diskImage(String key) async {
    try {
      final f = File('${(await _dir()).path}/${_diskVersion}_$key.img');
      if (!await f.exists()) return null;
      return await f.readAsBytes();
    } catch (_) {
      return null;
    }
  }

  static Future<Directory> _dir() async {
    final base = await getApplicationSupportDirectory();
    return Directory('${base.path}/bahncard_art');
  }

  static Future<void> _persist(String key, BahnCardArt art) async {
    try {
      final dir = await _dir();
      if (!await dir.exists()) await dir.create(recursive: true);
      final f = File('${dir.path}/${_diskVersion}_$key.img');
      if (await f.exists()) return; // content-addressed: same key, same bytes
      await f.writeAsBytes(art.imageBytes, flush: false);
      // A re-issued card leaves its predecessor behind. Drop the stale
      // generations *of this card only* — the key is `<card>_<htmlDigest>`, so
      // sibling cards in the same account keep their own artwork.
      final prefix = '${_diskVersion}_${key.split('_').first}_';
      await for (final e in dir.list()) {
        if (e is! File || e.path == f.path) continue;
        if (!e.uri.pathSegments.last.startsWith(prefix)) continue;
        try {
          await e.delete();
        } catch (_) {}
      }
    } catch (e) {
      AppLog.log('bahncard art persist failed: $e', tag: 'db-account');
    }
  }
}
