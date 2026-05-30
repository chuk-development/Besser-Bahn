import 'package:flutter/widgets.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_tile_caching/flutter_map_tile_caching.dart';
import 'package:vector_map_tiles/vector_map_tiles.dart';

import 'app_log.dart';

/// Persistent on-disk cache for map tiles (FMTC / ObjectBox backend).
///
/// Goal (user-chosen): keep ~50 MB of tiles on disk, evicting the oldest when
/// full, so re-opening the map — even after an app restart — paints instantly
/// from disk instead of re-downloading every tile.
///
/// FMTC has two independent limits:
///  * the per-store `maxLength` counts **tiles** and removes the OLDEST when
///    exceeded → this is our LRU eviction. ~50 MB ≈ 1500 tiles at ~30 KB each.
///  * `maxDatabaseSize` is a hard **KB** ceiling that *throws* (no eviction)
///    on write when hit → we set it well above the LRU target purely as a
///    safety net so we never actually hit it.
///
/// Init is best-effort: on platforms without the ObjectBox native library
/// (e.g. a plain Linux desktop build) or any failure, we silently fall back to
/// a normal [NetworkTileProvider] — the map still works, tiles just aren't
/// persisted.
class TileCache {
  TileCache._();

  static const _store = 'mapTiles';
  static const _maxTiles = 1500; // ≈ 50 MB; oldest evicted past this (LRU)

  static bool _ready = false;
  static bool get isReady => _ready;

  static Future<void> init() async {
    try {
      await FMTCObjectBoxBackend().initialise(
        // KB. Generous ceiling; the per-store maxLength keeps us near ~50 MB.
        maxDatabaseSize: 200000, // 200 MB hard cap (never expected to hit)
      );
      await FMTCStore(_store).manage.create(maxLength: _maxTiles);
      _ready = true;
      AppLog.log('tile cache ready (store "$_store", maxLength $_maxTiles)',
          tag: 'map');
    } catch (e) {
      _ready = false;
      AppLog.log('tile cache unavailable → network only ($e)', tag: 'map');
    }
  }

  /// A caching tile provider when the cache is up, else a plain network one.
  /// [headers] is forwarded (e.g. the `Referer` the indoor tiles require).
  static TileProvider provider({Map<String, String>? headers}) {
    if (_ready) {
      return FMTCTileProvider(
        stores: const {_store: BrowseStoreStrategy.readUpdateCreate},
        loadingStrategy: BrowseLoadingStrategy.cacheFirst,
        cachedValidDuration: const Duration(days: 30),
        headers: headers,
      );
    }
    return NetworkTileProvider(headers: headers ?? const {});
  }

  /// OpenFreeMap "Positron" — the clean light-grey Positron look the user likes,
  /// served as VECTOR tiles, which means labels use local names (German in
  /// Germany: Bayern/München, not CARTO's "Bavaria"). Free, no API key, no usage
  /// limit. Vector → rendered with vector_map_tiles.
  static const String _styleUri =
      'https://tiles.openfreemap.org/styles/positron';

  /// CARTO Positron raster — fallback shown while the vector style loads on the
  /// first map of a session, and if OpenFreeMap is unreachable. Keyless.
  static const String _fallbackTileUrl =
      'https://{s}.basemaps.cartocdn.com/light_all/{z}/{x}/{y}.png';

  static Future<Style>? _styleFuture;
  static Style? _style; // resolved style, cached so later maps skip the fetch

  static Future<Style> _loadStyle() =>
      _styleFuture ??= StyleReader(uri: _styleUri).read().then((s) {
        _style = s;
        AppLog.log('vector basemap style loaded ($_styleUri)', tag: 'map');
        return s;
      });

  /// The shared outdoor base layer. Used by every outdoor map (route, departures,
  /// station fallback) so the style/source lives in one place. Renders the
  /// German OpenFreeMap Positron vector style; falls back to the CARTO raster
  /// while the style loads and if it can't be fetched.
  static Widget outdoorLayer() {
    final ready = _style;
    if (ready != null) return _vectorLayer(ready);
    return FutureBuilder<Style>(
      future: _loadStyle(),
      builder: (context, snap) =>
          snap.data != null ? _vectorLayer(snap.data!) : _rasterFallback(),
    );
  }

  static Widget _vectorLayer(Style style) => VectorTileLayer(
        theme: style.theme,
        sprites: style.sprites,
        tileProviders: style.providers,
        fileCacheTtl: const Duration(days: 30),
        maximumZoom: 20,
        // Render tiles to images (vs. live canvas) — smoother and lighter, and
        // works everywhere incl. desktop.
        layerMode: VectorTileLayerMode.raster,
      );

  static TileLayer _rasterFallback() => TileLayer(
        urlTemplate: _fallbackTileUrl,
        subdomains: const ['a', 'b', 'c', 'd'],
        userAgentPackageName: 'de.chuk.besserebahn',
        tileProvider: provider(),
        maxZoom: 20,
        // A missing tile (cache miss + no/slow connection) makes FMTC throw a
        // FMTCBrowsingError per tile. flutter_map's default handler dumps EACH
        // one to the console → the endless red error block the user saw. Swallow
        // it (log once, throttled) and drop the failed tile so it can retry.
        evictErrorTileStrategy: EvictErrorTileStrategy.notVisible,
        errorTileCallback: (_, error, _) => _logTileError(error),
      );

  /// Last tile-error message + when, so a burst of identical FMTC misses logs
  /// once instead of thousands of times (one line, not an endless block).
  static String? _lastTileError;
  static void _logTileError(Object error) {
    final msg = error.toString().split('\n').first;
    if (msg == _lastTileError) return;
    _lastTileError = msg;
    AppLog.log('tile load failed (suppressing repeats): $msg', tag: 'map');
  }
}
