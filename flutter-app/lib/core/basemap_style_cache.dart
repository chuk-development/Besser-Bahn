import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:vector_map_tiles/vector_map_tiles.dart';
import 'package:vector_tile_renderer/vector_tile_renderer.dart'
    show SpriteIndexReader, ThemeReader;

import 'app_log.dart';

/// On-disk copy of the vector basemap's *style bundle*, so the map still draws
/// after a cold start with no network (#29).
///
/// Why this exists at all: [StyleReader.read] fetches four things over HTTP
/// every time — the style JSON, the source TileJSON, the sprite JSON and the
/// sprite atlas PNG — and caches none of them. `vector_map_tiles` caches *tiles*
/// on disk but not the style, so on a train with no signal the style read fails,
/// no [Style] can be built, and the basemap is blank **even though every tile it
/// needs is sitting in the tile cache**. Prefetching tiles for an offline
/// package would therefore have been pointless on its own.
///
/// So we do the four fetches ourselves, persist the bodies verbatim, and build
/// the [Style] from them — from the network when we can, from disk when we
/// can't. This mirrors what [StyleReader] does; the deliberate difference is
/// that we only wire up **vector** sources, which is all the Positron style's
/// layers reference (verified: all 54 layers use `openmaptiles`; the style also
/// declares an `ne2_shaded` raster source that no layer uses). If a future style
/// referenced a raster source, [VectorTileLayer]'s own assert would fail loudly
/// rather than silently drawing a wrong map.
class BasemapStyleCache {
  BasemapStyleCache._();

  /// Bump when the persisted layout changes; a mismatch is a miss, not a
  /// migration (same rule as the rest of the app's disk caches).
  static const _diskVersion = 1;

  static const _bundleFile = 'style_bundle.json';
  static const _spriteFile = 'sprite.png';

  static Future<Directory> _dir() async {
    final base = await getApplicationSupportDirectory();
    final d = Directory('${base.path}/basemap_style');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  /// Read the style from the network and persist it for later offline use.
  /// Throws on any network failure — the caller falls back to [fromDisk].
  static Future<Style> fetchAndPersist(String styleUri, http.Client client) async {
    final bundle = await _fetchBundle(styleUri, client);
    // Persist first; a style we can't rebuild offline is only half the point.
    await _persist(bundle);
    return _build(bundle);
  }

  /// Rebuild the style from the last persisted bundle. Throws when nothing
  /// usable is on disk.
  static Future<Style> fromDisk() async {
    final bundle = await _readDisk();
    if (bundle == null) {
      throw StateError('no persisted basemap style');
    }
    AppLog.log('basemap style rebuilt from disk cache', tag: 'map');
    return _build(bundle);
  }

  /// Whether a rebuildable bundle is on disk — drives the offline package's
  /// tile part (tiles without a style are unusable, so we report them together).
  static Future<bool> get isPersisted async => (await _readDisk()) != null;

  /// The `{z}/{x}/{y}` URL template + zoom bounds per vector source, from the
  /// persisted TileJSON. The offline prefetcher builds tile URLs from this
  /// instead of calling [VectorTileProvider.provide], so tile fetches go through
  /// the app's shared connection-capped client rather than the per-tile
  /// `RetryClient` that [NetworkVectorTileProvider] creates (see tile_cache.dart
  /// for why unbounded/retrying tile fetches are actively harmful here).
  ///
  /// Empty when no bundle is cached yet — the caller must then treat tiles as
  /// unavailable rather than guessing a template.
  static Future<Map<String, BasemapSource>> resolvedSources() async {
    final bundle = await _readDisk();
    if (bundle == null) return const {};
    return {
      for (final e in bundle.sources.entries)
        e.key: (
          urlTemplate: e.value.urlTemplate,
          minZoom: e.value.minZoom,
          maxZoom: e.value.maxZoom,
        ),
    };
  }

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

  // --- fetching -------------------------------------------------------------

  static Future<_Bundle> _fetchBundle(String styleUri, http.Client client) async {
    final styleJson = await _getJson(client, styleUri);

    final sources = <String, _SourceSpec>{};
    final rawSources = styleJson['sources'];
    if (rawSources is! Map) {
      throw StateError('basemap style has no sources');
    }
    for (final entry in rawSources.entries) {
      final value = entry.value;
      if (value is! Map) continue;
      if (value['type'] != 'vector') continue; // see class doc
      final spec = await _resolveSource(client, styleUri, value);
      if (spec != null) sources[entry.key.toString()] = spec;
    }
    if (sources.isEmpty) {
      throw StateError('basemap style has no vector sources');
    }

    // Sprites are optional — a style without icons still renders.
    Map<String, dynamic>? spriteJson;
    Uint8List? spriteImage;
    final spriteBase = styleJson['sprite'];
    if (spriteBase is String && spriteBase.trim().isNotEmpty) {
      try {
        spriteJson = await _getJson(client, '$spriteBase.json');
        spriteImage = await _getBytes(client, '$spriteBase.png');
      } catch (e) {
        AppLog.log('basemap sprites unavailable ($e) — style without icons',
            tag: 'map');
        spriteJson = null;
        spriteImage = null;
      }
    }

    return _Bundle(
      styleJson: styleJson,
      sources: sources,
      spriteJson: spriteJson,
      spriteImage: spriteImage,
    );
  }

  /// A source either points at a TileJSON (`url`) that carries the real tile
  /// template, or inlines `tiles` directly. Both shapes appear in the wild.
  static Future<_SourceSpec?> _resolveSource(
      http.Client client, String styleUri, Map<dynamic, dynamic> source) async {
    Map<String, dynamic> spec;
    final url = source['url'];
    if (url is String && url.isNotEmpty) {
      spec = await _getJson(client, url);
    } else {
      spec = source.cast<String, dynamic>();
    }
    final tiles = spec['tiles'];
    if (tiles is! List || tiles.isEmpty) return null;
    final template = tiles.first;
    if (template is! String || template.isEmpty) return null;
    return _SourceSpec(
      urlTemplate: template,
      minZoom: (spec['minzoom'] as num?)?.toInt() ?? 0,
      maxZoom: (spec['maxzoom'] as num?)?.toInt() ?? 14,
    );
  }

  static Future<Map<String, dynamic>> _getJson(
      http.Client client, String url) async {
    final res = await client
        .get(Uri.parse(url))
        .timeout(const Duration(seconds: 12));
    if (res.statusCode != 200) {
      throw StateError('style fetch $url → HTTP ${res.statusCode}');
    }
    final decoded = json.decode(utf8.decode(res.bodyBytes));
    if (decoded is! Map<String, dynamic>) {
      throw StateError('style fetch $url → not a JSON object');
    }
    return decoded;
  }

  static Future<Uint8List> _getBytes(http.Client client, String url) async {
    final res = await client
        .get(Uri.parse(url))
        .timeout(const Duration(seconds: 12));
    if (res.statusCode != 200) {
      throw StateError('style fetch $url → HTTP ${res.statusCode}');
    }
    return res.bodyBytes;
  }

  // --- disk -----------------------------------------------------------------

  static Future<void> _persist(_Bundle bundle) async {
    try {
      final dir = await _dir();
      await File('${dir.path}/$_bundleFile').writeAsString(json.encode({
        'v': _diskVersion,
        'style': bundle.styleJson,
        'sources': {
          for (final e in bundle.sources.entries) e.key: e.value.toJson(),
        },
        if (bundle.spriteJson != null) 'sprite': bundle.spriteJson,
      }));
      final img = bundle.spriteImage;
      if (img != null) {
        await File('${dir.path}/$_spriteFile').writeAsBytes(img);
      }
    } catch (e) {
      // Best-effort: failing to persist must never break the online map.
      AppLog.log('basemap style persist failed ($e)', tag: 'map');
    }
  }

  static Future<_Bundle?> _readDisk() async {
    try {
      final dir = await _dir();
      final f = File('${dir.path}/$_bundleFile');
      if (!await f.exists()) return null;
      final decoded = json.decode(await f.readAsString());
      if (decoded is! Map<String, dynamic>) return null;
      if ((decoded['v'] as num?)?.toInt() != _diskVersion) return null;
      final styleJson = decoded['style'];
      if (styleJson is! Map<String, dynamic>) return null;

      final sources = <String, _SourceSpec>{};
      final rawSources = decoded['sources'];
      if (rawSources is Map) {
        for (final e in rawSources.entries) {
          final v = e.value;
          if (v is Map<String, dynamic>) {
            final spec = _SourceSpec.fromJson(v);
            if (spec != null) sources[e.key.toString()] = spec;
          }
        }
      }
      if (sources.isEmpty) return null;

      Uint8List? spriteImage;
      final spriteFile = File('${dir.path}/$_spriteFile');
      if (await spriteFile.exists()) {
        spriteImage = await spriteFile.readAsBytes();
      }

      return _Bundle(
        styleJson: styleJson,
        sources: sources,
        spriteJson: decoded['sprite'] as Map<String, dynamic>?,
        spriteImage: spriteImage,
      );
    } catch (_) {
      return null;
    }
  }

  // --- building -------------------------------------------------------------

  static Style _build(_Bundle bundle) {
    final providers = <String, VectorTileProvider>{
      for (final e in bundle.sources.entries)
        e.key: NetworkVectorTileProvider(
          urlTemplate: e.value.urlTemplate,
          maximumZoom: e.value.maxZoom,
          minimumZoom: e.value.minZoom,
        ),
    };

    SpriteStyle? sprites;
    final spriteJson = bundle.spriteJson;
    final spriteImage = bundle.spriteImage;
    if (spriteJson != null && spriteImage != null) {
      sprites = SpriteStyle(
        atlasProvider: () async => spriteImage,
        index: SpriteIndexReader().read(spriteJson),
      );
    }

    return Style(
      name: bundle.styleJson['name'] as String?,
      theme: ThemeReader().read(bundle.styleJson),
      providers: TileProviders(providers),
      sprites: sprites,
    );
  }
}

/// A vector source's tile template + zoom bounds, as resolved from its TileJSON.
class _SourceSpec {
  final String urlTemplate;
  final int minZoom;
  final int maxZoom;

  const _SourceSpec({
    required this.urlTemplate,
    required this.minZoom,
    required this.maxZoom,
  });

  Map<String, dynamic> toJson() => {
        'urlTemplate': urlTemplate,
        'minZoom': minZoom,
        'maxZoom': maxZoom,
      };

  static _SourceSpec? fromJson(Map<String, dynamic> json) {
    final t = json['urlTemplate'] as String?;
    if (t == null || t.isEmpty) return null;
    return _SourceSpec(
      urlTemplate: t,
      minZoom: (json['minZoom'] as num?)?.toInt() ?? 0,
      maxZoom: (json['maxZoom'] as num?)?.toInt() ?? 14,
    );
  }
}

/// Everything needed to rebuild a [Style] without touching the network.
class _Bundle {
  final Map<String, dynamic> styleJson;
  final Map<String, _SourceSpec> sources;
  final Map<String, dynamic>? spriteJson;
  final Uint8List? spriteImage;

  const _Bundle({
    required this.styleJson,
    required this.sources,
    this.spriteJson,
    this.spriteImage,
  });
}

/// Public view of a source's tile template, for the offline prefetcher.
typedef BasemapSource = ({String urlTemplate, int minZoom, int maxZoom});
