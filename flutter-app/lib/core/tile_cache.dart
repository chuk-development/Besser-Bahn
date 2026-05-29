import 'package:flutter/widgets.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_tile_caching/flutter_map_tile_caching.dart';

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

  /// CARTO "Positron" (light_all): a deliberately minimal grey basemap. It
  /// renders place and region names (cities, Bundesländer) and roads/water but
  /// almost no POI clutter — no restaurant/shop icons like the full OSM style —
  /// so it stays an unobtrusive backdrop for our route/markers. In Germany the
  /// names come out German (OSM `name` tag). No API key.
  static const String outdoorTileUrl =
      'https://{s}.basemaps.cartocdn.com/light_all/{z}/{x}/{y}{r}.png';

  /// The shared outdoor base layer, cached on disk. Used by every outdoor map
  /// (route, departures, station fallback) so the style/source lives in one
  /// place. [context] only drives retina tile selection.
  static TileLayer outdoorLayer(BuildContext context) => TileLayer(
        urlTemplate: outdoorTileUrl,
        subdomains: const ['a', 'b', 'c', 'd'],
        retinaMode: RetinaMode.isHighDensity(context),
        userAgentPackageName: 'de.chuk.besserebahn',
        tileProvider: provider(),
        maxZoom: 20,
      );
}
