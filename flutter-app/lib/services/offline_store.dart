import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import '../core/app_log.dart';
import '../core/offline_package.dart';
import '../core/tile_cache.dart';

/// The on-disk half of the offline travel package (#29).
///
/// Deliberately dependency-free (no services, no Riverpod): the download side
/// writes through it, and the data services read back through it as their
/// last-resort fallback. Keeping it at the bottom of the dependency graph is
/// what lets `VendoService`/`CoachSequenceService`/`StationMapService` fall back
/// to cached data without any of them importing each other.
///
/// Layout — one folder per saved journey:
/// ```
/// <appSupport>/offline_packages/<hashed journey key>/
///   manifest.json          what we hold, and when it was fetched
///   plan_<hash>.json       raw /mob/zuglauf response, per leg
///   coach_<hash>.json      raw vehicle-sequence response, per leg
///   station_<slug>.txt     raw bahnhof.de body, per station
///   tiles.txt              names of the vector tiles this package prefetched
/// ```
/// Map tiles themselves live in the shared vector tile cache (that is the only
/// place the map layer looks); `tiles.txt` records which of them this package
/// paid for, so [delete] can reclaim them without touching tiles another package
/// still needs.
///
/// Everything stores the **raw upstream payload**, never a serialised model —
/// the same rule the ticket cache follows. A parser fix then improves packages
/// that were downloaded before it, and no model needs a `toJson` written purely
/// for the cache to freeze and drift.
class OfflineStore {
  OfflineStore._();

  static final OfflineStore instance = OfflineStore._();

  static const _manifestFile = 'manifest.json';
  static const _tilesFile = 'tiles.txt';

  Directory? _rootCache;

  Future<Directory> _root() async {
    final cached = _rootCache;
    if (cached != null) return cached;
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/offline_packages');
    if (!await dir.exists()) await dir.create(recursive: true);
    return _rootCache = dir;
  }

  /// Journey keys contain EVA ids, timestamps and `_` — safe enough in practice,
  /// but hashing removes any doubt about path traversal or length limits.
  static String _hash(String s) => sha1.convert(utf8.encode(s)).toString();

  Future<Directory> _packageDir(String journeyKey, {bool create = false}) async {
    final root = await _root();
    final dir = Directory('${root.path}/${_hash(journeyKey)}');
    if (create && !await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  // --- manifest -------------------------------------------------------------

  Future<OfflineManifest?> readManifest(String journeyKey) async {
    try {
      final dir = await _packageDir(journeyKey);
      final f = File('${dir.path}/$_manifestFile');
      if (!await f.exists()) return null;
      final decoded = json.decode(await f.readAsString());
      if (decoded is! Map<String, dynamic>) return null;
      final m = OfflineManifest.fromJson(decoded);
      if (m == null) return null;
      return _reconcileTiles(m, dir, await _tileIndex());
    } catch (_) {
      return null;
    }
  }

  /// Name → size for every file in the shared vector tile cache.
  ///
  /// One directory listing instead of a `stat` per claimed tile: a package can
  /// claim several hundred, and this runs whenever the Reisen list loads.
  Future<Map<String, int>> _tileIndex() async {
    final out = <String, int>{};
    try {
      final dir = await TileCache.vectorCacheFolder();
      await for (final e in dir.list()) {
        if (e is File) out[e.path.split('/').last] = await e.length();
      }
    } catch (_) {}
    return out;
  }

  /// Rewrite the tiles part to match reality.
  ///
  /// This is what keeps the badge honest. The tile cache is a shared LRU: it can
  /// evict our prefetched tiles whenever the user browses the map, and the app
  /// can be reinstalled or its cache cleared. A manifest records what ONE
  /// download achieved, so trusting its `stored` count forever would leave
  /// "Offline verfügbar" on a package whose tiles are long gone — precisely the
  /// lie that makes an offline feature worthless. Counting the files instead
  /// turns eviction into an honest "Unvollständig".
  OfflineManifest _reconcileTiles(
      OfflineManifest m, Directory dir, Map<String, int> tileIndex) {
    final part = m.partFor(OfflinePartKind.tiles);
    if (part == null || part.expected == 0) return m;

    final claimed = _tileListSync(dir);
    if (claimed.isEmpty) return m;

    var present = 0;
    var bytes = 0;
    for (final name in claimed) {
      final size = tileIndex[name];
      if (size != null) {
        present++;
        bytes += size;
      }
    }
    if (present == part.stored && bytes == part.bytes) return m;

    final evicted = part.stored - present;
    return m.withPart(OfflinePart(
      kind: OfflinePartKind.tiles,
      expected: part.expected,
      stored: present,
      bytes: bytes,
      note: evicted > 0
          ? '$evicted Kachel(n) aus dem Kartencache verdrängt — neu laden'
          : part.note,
    ));
  }

  List<String> _tileListSync(Directory packageDir) {
    try {
      final f = File('${packageDir.path}/$_tilesFile');
      if (!f.existsSync()) return const [];
      return f
          .readAsStringSync()
          .split('\n')
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty)
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  Future<void> writeManifest(OfflineManifest manifest) async {
    final dir = await _packageDir(manifest.journeyKey, create: true);
    await File('${dir.path}/$_manifestFile')
        .writeAsString(json.encode(manifest.toJson()));
  }

  /// Every package we hold. Used for the storage overview and for the
  /// cross-package tile reference check in [delete].
  Future<List<OfflineManifest>> allManifests() async {
    final out = <OfflineManifest>[];
    try {
      final root = await _root();
      // Index the tile cache once for the whole sweep, not once per package.
      final tileIndex = await _tileIndex();
      await for (final entry in root.list()) {
        if (entry is! Directory) continue;
        try {
          final f = File('${entry.path}/$_manifestFile');
          if (!await f.exists()) continue;
          final decoded = json.decode(await f.readAsString());
          if (decoded is! Map<String, dynamic>) continue;
          final m = OfflineManifest.fromJson(decoded);
          if (m != null) out.add(_reconcileTiles(m, entry, tileIndex));
        } catch (_) {
          // One unreadable package must not hide the others.
        }
      }
    } catch (_) {}
    return out;
  }

  /// Bytes held by all packages — the package folders plus the map tiles they
  /// claim. Tiles are counted from their manifests rather than by measuring the
  /// shared tile cache, so browsing tiles aren't billed to a package.
  Future<int> totalBytes() async {
    var total = 0;
    for (final m in await allManifests()) {
      total += m.totalBytes;
    }
    return total;
  }

  // --- writing parts --------------------------------------------------------

  Future<int> writeJson(
      String journeyKey, String name, Map<String, dynamic> raw) async {
    final dir = await _packageDir(journeyKey, create: true);
    final body = json.encode(raw);
    await File('${dir.path}/$name').writeAsString(body);
    return utf8.encode(body).length;
  }

  Future<int> writeText(String journeyKey, String name, String body) async {
    final dir = await _packageDir(journeyKey, create: true);
    await File('${dir.path}/$name').writeAsString(body);
    return utf8.encode(body).length;
  }

  static String planName(String zuglaufId) => 'plan_${_hash(zuglaufId)}.json';

  static String coachName(String cacheKey) => 'coach_${_hash(cacheKey)}.json';

  static String stationName(String slug) => 'station_$slug.txt';

  Future<void> writeTileList(String journeyKey, List<String> files) async {
    final dir = await _packageDir(journeyKey, create: true);
    await File('${dir.path}/$_tilesFile').writeAsString(files.join('\n'));
  }

  Future<List<String>> _tileList(Directory packageDir) async {
    try {
      final f = File('${packageDir.path}/$_tilesFile');
      if (!await f.exists()) return const [];
      final body = await f.readAsString();
      return body
          .split('\n')
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty)
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  // --- reading parts back (the offline fallback) ----------------------------

  /// Search every package for a stored payload named [name].
  ///
  /// Scanning rather than indexing is deliberate: there are as many packages as
  /// the user has saved journeys (a handful), and an index would be one more
  /// thing that can disagree with the disk. The same leg appearing in two
  /// packages is fine — both hold the same upstream payload.
  Future<File?> _findInAnyPackage(String name) async {
    try {
      final root = await _root();
      await for (final entry in root.list()) {
        if (entry is! Directory) continue;
        final f = File('${entry.path}/$name');
        if (await f.exists()) return f;
      }
    } catch (_) {}
    return null;
  }

  Future<Map<String, dynamic>?> _readJsonAnywhere(String name) async {
    try {
      final f = await _findInAnyPackage(name);
      if (f == null) return null;
      final decoded = json.decode(await f.readAsString());
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  /// Raw `/mob/zuglauf` payload for a leg, if any package carries it.
  Future<Map<String, dynamic>?> readPlan(String zuglaufId) =>
      _readJsonAnywhere(planName(zuglaufId));

  /// Raw vehicle-sequence payload for a train stop, if any package carries it.
  Future<Map<String, dynamic>?> readCoach(String cacheKey) =>
      _readJsonAnywhere(coachName(cacheKey));

  /// Raw bahnhof.de body for a station, if any package carries it.
  Future<String?> readStationMap(String slug) async {
    try {
      final f = await _findInAnyPackage(stationName(slug));
      return f == null ? null : await f.readAsString();
    } catch (_) {
      return null;
    }
  }

  /// When the package holding [journeyKey] was fetched — the "Stand: vor 3 h"
  /// the UI must show alongside any offline data.
  Future<DateTime?> fetchedAt(String journeyKey) async =>
      (await readManifest(journeyKey))?.fetchedAt;

  // --- deleting -------------------------------------------------------------

  /// Drop a package and reclaim its tiles.
  ///
  /// Tiles are only deleted when no OTHER package lists them, so removing the
  /// Hamburg trip can't blank out the map of the Bremen trip that shares its
  /// corridor. Tiles the layer cached through ordinary browsing are never
  /// touched — we only ever delete names this package's `tiles.txt` claims.
  Future<void> delete(String journeyKey) async {
    try {
      final dir = await _packageDir(journeyKey);
      if (!await dir.exists()) return;

      final mine = (await _tileList(dir)).toSet();
      if (mine.isNotEmpty) {
        final root = await _root();
        final keep = <String>{};
        await for (final entry in root.list()) {
          if (entry is! Directory) continue;
          if (entry.path == dir.path) continue;
          keep.addAll(await _tileList(entry));
        }
        final orphans = mine.difference(keep);
        if (orphans.isNotEmpty) {
          final tileDir = await TileCache.vectorCacheFolder();
          for (final name in orphans) {
            try {
              final f = File('${tileDir.path}/$name');
              if (await f.exists()) await f.delete();
            } catch (_) {/* raced or already gone */}
          }
        }
        AppLog.log(
            'offline package deleted: ${mine.length} tiles claimed, '
            '${mine.difference(keep).length} freed',
            tag: 'offline');
      }

      await dir.delete(recursive: true);
    } catch (e) {
      AppLog.log('offline package delete failed ($e)', tag: 'offline');
    }
  }

  /// Remove every package. Exposed for the "Speicher freigeben" action.
  Future<void> deleteAll() async {
    for (final m in await allManifests()) {
      await delete(m.journeyKey);
    }
  }
}
