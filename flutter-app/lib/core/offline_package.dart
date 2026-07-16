import 'dart:math' as math;

/// Offline travel package (#29) — the pure model + rules.
///
/// Everything in this file is deliberately free of I/O, Flutter and Riverpod so
/// the interesting decisions ("is this package still trustworthy?", "how many
/// tiles does this route need?") are testable without a device. The disk side
/// lives in `services/offline_package_service.dart`.
///
/// Design rule that everything else follows: **a package's state is derived
/// from what is actually on disk, never from a stored "downloaded" flag.** The
/// map tile cache is a shared LRU and can evict our tiles behind our back, so a
/// flag would eventually lie. Recomputing from disk means eviction shows up
/// honestly as [OfflinePackageState.partial] instead.

/// A package older than this is shown as "veraltet". Realtime-flavoured data
/// (platforms, coach order, disruptions) goes off quickly; six hours is roughly
/// "you packed this before you left home this morning".
const Duration kOfflineStaleAfter = Duration(hours: 6);

/// How long before departure an already-downloaded package is refreshed on its
/// own, while there is still network. Only maintains packages the user asked
/// for — we never auto-download a package that was never requested.
const Duration kOfflineAutoRefreshWindow = Duration(hours: 12);

/// Zoom range prefetched along the route corridor.
///
/// z9–z11 is the "where am I, and what's the next town" band — z9 ≈ 48 km per
/// tile, z11 ≈ 12 km. Station-level detail is the Bahnhofskarte's job (it has
/// its own indoor tiles), and z12+ over a long route runs to hundreds of MB.
/// z8 was measured and dropped: those tiles cost ~240 KB EACH (a low-zoom tile
/// packs a whole country's features) to show a country-scale view nobody needs
/// while riding — the same bytes buy far more at z10/z11.
const int kOfflineTileMinZoom = 9;
const int kOfflineTileMaxZoom = 11;

/// Hard ceiling on tiles per package, so a Flensburg→Garmisch trip can't quietly
/// eat the disk. Reaching it marks the tile part incomplete rather than
/// pretending the corridor is fully covered.
const int kOfflineMaxTiles = 600;

/// Byte budget per package's tiles — the constraint that actually matters, since
/// tile size varies ~4× across this zoom band (measured: ~250 KB at z9, ~60 KB
/// at z11). A count-only cap would let one long route claim 60 MB+ and quietly
/// evict every other package out of the shared tile cache. Sized so a few
/// packages coexist inside the map cache's ceiling rather than fighting over it.
const int kOfflineMaxTileBytes = 25 * 1024 * 1024;

/// The parts a package is made of. Order is display order.
enum OfflinePartKind { plan, wagenreihung, stationMap, tiles, ticket }

extension OfflinePartKindLabel on OfflinePartKind {
  String get label => switch (this) {
        OfflinePartKind.plan => 'Reiseplan',
        OfflinePartKind.wagenreihung => 'Wagenreihung',
        OfflinePartKind.stationMap => 'Bahnhofskarten',
        OfflinePartKind.tiles => 'Kartenkacheln',
        OfflinePartKind.ticket => 'Ticket',
      };

  String get id => name;

  static OfflinePartKind? byId(String id) {
    for (final k in OfflinePartKind.values) {
      if (k.name == id) return k;
    }
    return null;
  }
}

/// One part's outcome. [expected] is how many items the journey needs,
/// [stored] how many we actually hold. `expected == 0` means the journey has no
/// such source at all (e.g. no ticket booked) — that is *not* a failure, it is
/// simply nothing to carry, and [isComplete] treats it as done.
class OfflinePart {
  final OfflinePartKind kind;
  final int expected;
  final int stored;
  final int bytes;

  /// Why this part is short, in German, for the detail sheet. Null when fine.
  final String? note;

  const OfflinePart({
    required this.kind,
    required this.expected,
    required this.stored,
    this.bytes = 0,
    this.note,
  });

  bool get isComplete => stored >= expected;

  /// Nothing to carry — the journey has no such source.
  bool get isEmptySource => expected == 0;

  Map<String, dynamic> toJson() => {
        'kind': kind.name,
        'expected': expected,
        'stored': stored,
        'bytes': bytes,
        if (note != null) 'note': note,
      };

  static OfflinePart? fromJson(Map<String, dynamic> json) {
    final kind = OfflinePartKindLabel.byId(json['kind'] as String? ?? '');
    if (kind == null) return null;
    return OfflinePart(
      kind: kind,
      expected: (json['expected'] as num?)?.toInt() ?? 0,
      stored: (json['stored'] as num?)?.toInt() ?? 0,
      bytes: (json['bytes'] as num?)?.toInt() ?? 0,
      note: json['note'] as String?,
    );
  }
}

/// What we wrote to disk for one journey, and when.
class OfflineManifest {
  /// Bump when the on-disk layout changes — a mismatch is treated as "missing"
  /// (re-download), never migrated.
  static const int currentVersion = 1;

  final String journeyKey;
  final int fetchedAtMs;
  final List<OfflinePart> parts;

  const OfflineManifest({
    required this.journeyKey,
    required this.fetchedAtMs,
    required this.parts,
  });

  DateTime get fetchedAt => DateTime.fromMillisecondsSinceEpoch(fetchedAtMs);

  int get totalBytes => parts.fold(0, (sum, p) => sum + p.bytes);

  /// Parts that actually had something to fetch.
  Iterable<OfflinePart> get sourcedParts => parts.where((p) => !p.isEmptySource);

  /// True when every part that had a source is fully stored.
  bool get isComplete => sourcedParts.every((p) => p.isComplete);

  /// True when not a single item was stored — the download ran but produced
  /// nothing usable.
  bool get isBarren => parts.every((p) => p.stored == 0);

  OfflinePart? partFor(OfflinePartKind kind) {
    for (final p in parts) {
      if (p.kind == kind) return p;
    }
    return null;
  }

  /// Replace one part, keeping order. Used to reconcile a manifest with what is
  /// actually on disk right now — see `OfflineStore.readManifest`. A manifest is
  /// a record of a past download, not a promise about the present.
  OfflineManifest withPart(OfflinePart replacement) => OfflineManifest(
        journeyKey: journeyKey,
        fetchedAtMs: fetchedAtMs,
        parts: [
          for (final p in parts) p.kind == replacement.kind ? replacement : p,
        ],
      );

  Duration ageAt(DateTime now) => now.difference(fetchedAt);

  Map<String, dynamic> toJson() => {
        'v': currentVersion,
        'journeyKey': journeyKey,
        'fetchedAtMs': fetchedAtMs,
        'parts': parts.map((p) => p.toJson()).toList(),
      };

  /// Tolerant parse. Returns null on a version mismatch or anything malformed —
  /// the caller then treats the package as missing and re-downloads, which is
  /// always safe.
  static OfflineManifest? fromJson(Map<String, dynamic> json) {
    if ((json['v'] as num?)?.toInt() != currentVersion) return null;
    final key = json['journeyKey'] as String?;
    final fetched = (json['fetchedAtMs'] as num?)?.toInt();
    if (key == null || key.isEmpty || fetched == null) return null;
    final parts = (json['parts'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(OfflinePart.fromJson)
        .whereType<OfflinePart>()
        .toList(growable: false);
    return OfflineManifest(
      journeyKey: key,
      fetchedAtMs: fetched,
      parts: parts,
    );
  }
}

/// The one thing the user actually reads. Never invent a state that claims more
/// than the disk supports.
enum OfflinePackageState {
  /// Never downloaded (or dropped/invalidated).
  missing,

  /// A download is running right now.
  downloading,

  /// A download ran but stored nothing usable.
  failed,

  /// Some of it is here, some isn't — usable, but say so.
  partial,

  /// Complete, but old enough that we won't vouch for it.
  stale,

  /// Complete and fresh.
  ready,
}

/// Decide what to show for one journey.
///
/// Precedence — deliberate, and the reason this is a pure function:
/// `downloading` > `missing` > `failed` > `stale` > `partial` > `ready`.
/// Staleness outranks incompleteness because age is the trust-critical signal:
/// a rider who sees "unvollständig" may still board on it, but they must never
/// board on twelve-hour-old platform data believing it is current.
OfflinePackageState packageState({
  required OfflineManifest? manifest,
  bool downloading = false,
  required DateTime now,
  Duration staleAfter = kOfflineStaleAfter,
}) {
  if (downloading) return OfflinePackageState.downloading;
  if (manifest == null) return OfflinePackageState.missing;
  if (manifest.isBarren) return OfflinePackageState.failed;
  if (manifest.ageAt(now) > staleAfter) return OfflinePackageState.stale;
  if (!manifest.isComplete) return OfflinePackageState.partial;
  return OfflinePackageState.ready;
}

extension OfflinePackageStateLabel on OfflinePackageState {
  /// Short chip label.
  String get label => switch (this) {
        OfflinePackageState.missing => 'Nicht geladen',
        OfflinePackageState.downloading => 'Lädt…',
        OfflinePackageState.failed => 'Fehlgeschlagen',
        OfflinePackageState.partial => 'Unvollständig',
        OfflinePackageState.stale => 'Veraltet',
        OfflinePackageState.ready => 'Offline verfügbar',
      };

  /// Whether the app can fall back to this package's data when offline.
  bool get hasUsableData =>
      this == OfflinePackageState.ready ||
      this == OfflinePackageState.stale ||
      this == OfflinePackageState.partial;
}

/// Should we quietly top this package up right now?
///
/// Only for packages the user already asked for ([OfflinePackageState.missing]
/// is excluded on purpose — an offline package is an opt-in, not something we
/// download behind their back), only while there is network, and only in the
/// run-up to departure, where fresh data is worth the bytes.
bool shouldAutoRefresh({
  required OfflinePackageState state,
  required bool online,
  required DateTime now,
  DateTime? departure,
  Duration window = kOfflineAutoRefreshWindow,
}) {
  if (!online) return false;
  if (departure == null) return false;
  // Only refresh what exists and is no longer trustworthy.
  if (state != OfflinePackageState.stale &&
      state != OfflinePackageState.partial &&
      state != OfflinePackageState.failed) {
    return false;
  }
  if (now.isAfter(departure)) return false;
  return !now.isBefore(departure.subtract(window));
}

// ---------------------------------------------------------------------------
// Formatting — German, house style (abbreviated: "vor 3 min", not "Minuten").
// ---------------------------------------------------------------------------

/// "Stand" line for cached data: how old it is, in words the user can act on.
String offlineAgeLabel(Duration age) {
  if (age.isNegative || age.inMinutes < 1) return 'gerade eben';
  if (age.inMinutes < 60) return 'vor ${age.inMinutes} min';
  if (age.inHours < 24) return 'vor ${age.inHours} h';
  return 'vor ${age.inDays} d';
}

/// Package size, German decimal comma. Deliberately coarse — the user is
/// deciding "can I afford this", not auditing bytes.
String offlineSizeLabel(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).round()} KB';
  final mb = bytes / (1024 * 1024);
  return '${mb.toStringAsFixed(1).replaceAll('.', ',')} MB';
}

// ---------------------------------------------------------------------------
// Tile geometry — pure slippy-map math, so the corridor calculation is testable.
// ---------------------------------------------------------------------------

/// One slippy-map tile.
class TileRef {
  final int z;
  final int x;
  final int y;

  const TileRef(this.z, this.x, this.y);

  @override
  bool operator ==(Object other) =>
      other is TileRef && other.z == z && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(z, x, y);

  @override
  String toString() => '$z/$x/$y';
}

/// Slippy-map tile containing [lat]/[lng] at [z]. Standard OSM formula;
/// latitude is clamped to the Web-Mercator limit so a bogus coordinate can't
/// produce an out-of-range tile.
TileRef tileForLatLng(double lat, double lng, int z) {
  final n = 1 << z;
  final clampedLat = lat.clamp(-85.05112878, 85.05112878);
  final latRad = clampedLat * math.pi / 180.0;
  final x = ((lng + 180.0) / 360.0 * n).floor();
  final y = ((1.0 - math.log(math.tan(latRad) + 1.0 / math.cos(latRad)) / math.pi) /
          2.0 *
          n)
      .floor();
  return TileRef(z, x.clamp(0, n - 1), y.clamp(0, n - 1));
}

/// The tiles a route corridor needs, for every zoom in [minZoom]..[maxZoom].
///
/// [points] is the route polyline (lat/lng). Each point's tile plus a [buffer]
/// ring around it is included, so the corridor stays covered when the rider pans
/// slightly off the line. Result is deduped and deterministic (sorted by z, x,
/// y), and truncated at [maxTiles] — the caller compares the returned length
/// against [maxTiles] to know whether the corridor was fully covered.
///
/// Low zooms first: if we do hit the cap, what survives is the wide overview
/// (still a usable map) rather than a random patch of detail.
List<TileRef> tilesAlongRoute(
  List<({double lat, double lng})> points, {
  int minZoom = kOfflineTileMinZoom,
  int maxZoom = kOfflineTileMaxZoom,
  int buffer = 1,
  int maxTiles = kOfflineMaxTiles,
}) {
  if (points.isEmpty || maxTiles <= 0) return const [];
  final out = <TileRef>{};
  for (var z = minZoom; z <= maxZoom; z++) {
    final atZoom = <TileRef>{};
    final n = 1 << z;
    for (final p in points) {
      final t = tileForLatLng(p.lat, p.lng, z);
      for (var dx = -buffer; dx <= buffer; dx++) {
        for (var dy = -buffer; dy <= buffer; dy++) {
          final x = t.x + dx;
          final y = t.y + dy;
          if (x < 0 || y < 0 || x >= n || y >= n) continue;
          atZoom.add(TileRef(z, x, y));
        }
      }
    }
    final sorted = atZoom.toList()
      ..sort((a, b) => a.x != b.x ? a.x.compareTo(b.x) : a.y.compareTo(b.y));
    for (final t in sorted) {
      if (out.length >= maxTiles) return out.toList(growable: false);
      out.add(t);
    }
  }
  return out.toList(growable: false);
}
