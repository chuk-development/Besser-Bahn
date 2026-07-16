import 'package:besser_bahn/core/offline_package.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pure-logic tests for the offline travel package (#29).
///
/// The rules worth pinning down are the honesty rules: a package must never
/// report a state better than what it actually holds, and "how old is this?"
/// must stay correct as the clock moves.

OfflineManifest manifestOf(
  List<OfflinePart> parts, {
  DateTime? fetchedAt,
  String key = 'k',
}) =>
    OfflineManifest(
      journeyKey: key,
      fetchedAtMs:
          (fetchedAt ?? DateTime(2026, 7, 16, 12)).millisecondsSinceEpoch,
      parts: parts,
    );

OfflinePart part(
  OfflinePartKind kind, {
  required int expected,
  required int stored,
  int bytes = 0,
}) =>
    OfflinePart(kind: kind, expected: expected, stored: stored, bytes: bytes);

void main() {
  final now = DateTime(2026, 7, 16, 12);

  group('packageState', () {
    test('no manifest → missing', () {
      expect(packageState(manifest: null, now: now), OfflinePackageState.missing);
    });

    test('downloading outranks everything, even a missing package', () {
      expect(
        packageState(manifest: null, downloading: true, now: now),
        OfflinePackageState.downloading,
      );
    });

    test('complete and fresh → ready', () {
      final m = manifestOf(
        [part(OfflinePartKind.plan, expected: 2, stored: 2)],
        fetchedAt: now,
      );
      expect(packageState(manifest: m, now: now), OfflinePackageState.ready);
    });

    test('a download that stored nothing → failed, not ready', () {
      final m = manifestOf(
        [
          part(OfflinePartKind.plan, expected: 2, stored: 0),
          part(OfflinePartKind.tiles, expected: 5, stored: 0),
        ],
        fetchedAt: now,
      );
      expect(packageState(manifest: m, now: now), OfflinePackageState.failed);
    });

    test('some parts short → partial', () {
      final m = manifestOf(
        [
          part(OfflinePartKind.plan, expected: 2, stored: 2),
          part(OfflinePartKind.stationMap, expected: 3, stored: 1),
        ],
        fetchedAt: now,
      );
      expect(packageState(manifest: m, now: now), OfflinePackageState.partial);
    });

    test('a source with nothing to fetch does not make a package partial', () {
      // expected == 0 means "this journey has no ticket", not "we failed".
      final m = manifestOf(
        [
          part(OfflinePartKind.plan, expected: 1, stored: 1),
          part(OfflinePartKind.ticket, expected: 0, stored: 0),
        ],
        fetchedAt: now,
      );
      expect(packageState(manifest: m, now: now), OfflinePackageState.ready);
    });

    test('age beyond the threshold → stale', () {
      final m = manifestOf(
        [part(OfflinePartKind.plan, expected: 1, stored: 1)],
        fetchedAt: now.subtract(kOfflineStaleAfter + const Duration(minutes: 1)),
      );
      expect(packageState(manifest: m, now: now), OfflinePackageState.stale);
    });

    test('exactly at the threshold is still fresh', () {
      final m = manifestOf(
        [part(OfflinePartKind.plan, expected: 1, stored: 1)],
        fetchedAt: now.subtract(kOfflineStaleAfter),
      );
      expect(packageState(manifest: m, now: now), OfflinePackageState.ready);
    });

    test('stale outranks partial — age is the trust-critical signal', () {
      // A rider may board on "unvollständig"; they must not board on
      // twelve-hour-old platform data believing it is current.
      final m = manifestOf(
        [
          part(OfflinePartKind.plan, expected: 2, stored: 2),
          part(OfflinePartKind.stationMap, expected: 3, stored: 1),
        ],
        fetchedAt: now.subtract(const Duration(hours: 12)),
      );
      expect(packageState(manifest: m, now: now), OfflinePackageState.stale);
    });

    test('failed outranks stale — nothing stored is nothing stored', () {
      final m = manifestOf(
        [part(OfflinePartKind.plan, expected: 2, stored: 0)],
        fetchedAt: now.subtract(const Duration(days: 3)),
      );
      expect(packageState(manifest: m, now: now), OfflinePackageState.failed);
    });

    test('a custom stale window is honoured', () {
      final m = manifestOf(
        [part(OfflinePartKind.plan, expected: 1, stored: 1)],
        fetchedAt: now.subtract(const Duration(minutes: 30)),
      );
      expect(
        packageState(
            manifest: m, now: now, staleAfter: const Duration(minutes: 10)),
        OfflinePackageState.stale,
      );
    });
  });

  group('state labels', () {
    test('every state has a label and a defined usability', () {
      for (final s in OfflinePackageState.values) {
        expect(s.label, isNotEmpty);
      }
      expect(OfflinePackageState.ready.hasUsableData, isTrue);
      expect(OfflinePackageState.stale.hasUsableData, isTrue);
      expect(OfflinePackageState.partial.hasUsableData, isTrue);
      expect(OfflinePackageState.missing.hasUsableData, isFalse);
      expect(OfflinePackageState.failed.hasUsableData, isFalse);
      expect(OfflinePackageState.downloading.hasUsableData, isFalse);
    });
  });

  group('manifest', () {
    test('round-trips through JSON', () {
      final m = manifestOf([
        part(OfflinePartKind.plan, expected: 2, stored: 2, bytes: 1000),
        OfflinePart(
          kind: OfflinePartKind.tiles,
          expected: 10,
          stored: 4,
          bytes: 2048,
          note: 'gekappt',
        ),
      ]);
      final back = OfflineManifest.fromJson(m.toJson());
      expect(back, isNotNull);
      expect(back!.journeyKey, m.journeyKey);
      expect(back.fetchedAtMs, m.fetchedAtMs);
      expect(back.parts.length, 2);
      expect(back.totalBytes, 3048);
      expect(back.partFor(OfflinePartKind.tiles)!.note, 'gekappt');
      expect(back.partFor(OfflinePartKind.tiles)!.stored, 4);
    });

    test('a version mismatch reads as missing rather than migrating', () {
      final json = manifestOf([part(OfflinePartKind.plan, expected: 1, stored: 1)])
          .toJson();
      json['v'] = OfflineManifest.currentVersion + 1;
      expect(OfflineManifest.fromJson(json), isNull);
    });

    test('malformed manifests are rejected, not guessed at', () {
      expect(OfflineManifest.fromJson({'v': OfflineManifest.currentVersion}), isNull);
      expect(
        OfflineManifest.fromJson(
            {'v': OfflineManifest.currentVersion, 'journeyKey': '', 'fetchedAtMs': 1}),
        isNull,
      );
    });

    test('an unknown part kind is dropped, the rest survives', () {
      final json = manifestOf([part(OfflinePartKind.plan, expected: 1, stored: 1)])
          .toJson();
      (json['parts'] as List).add({'kind': 'hyperloop', 'expected': 1, 'stored': 1});
      final back = OfflineManifest.fromJson(json);
      expect(back!.parts.length, 1);
      expect(back.parts.single.kind, OfflinePartKind.plan);
    });

    test('totalBytes sums parts; isComplete ignores empty sources', () {
      final m = manifestOf([
        part(OfflinePartKind.plan, expected: 1, stored: 1, bytes: 500),
        part(OfflinePartKind.ticket, expected: 0, stored: 0),
      ]);
      expect(m.totalBytes, 500);
      expect(m.isComplete, isTrue);
      expect(m.isBarren, isFalse);
      expect(m.sourcedParts.length, 1);
    });

    test('ageAt measures from fetchedAt', () {
      final m = manifestOf(
        [part(OfflinePartKind.plan, expected: 1, stored: 1)],
        fetchedAt: now.subtract(const Duration(hours: 2)),
      );
      expect(m.ageAt(now), const Duration(hours: 2));
    });
  });

  group('withPart — reconciling a manifest with the disk', () {
    // The tile cache is a shared LRU that can evict our tiles at any time, so a
    // package's state has to follow the files, not the download record.
    test('replacing the tiles part in place turns ready into partial', () {
      final m = manifestOf([
        part(OfflinePartKind.plan, expected: 1, stored: 1, bytes: 10),
        part(OfflinePartKind.tiles, expected: 100, stored: 100, bytes: 5000),
      ], fetchedAt: now);
      expect(packageState(manifest: m, now: now), OfflinePackageState.ready);

      // Half the tiles got evicted behind our back.
      final evicted = m.withPart(part(OfflinePartKind.tiles,
          expected: 100, stored: 50, bytes: 2500));

      expect(packageState(manifest: evicted, now: now),
          OfflinePackageState.partial);
      expect(evicted.totalBytes, 2510);
      expect(evicted.parts.length, 2);
      // Order and the untouched part survive.
      expect(evicted.parts.first.kind, OfflinePartKind.plan);
      expect(evicted.partFor(OfflinePartKind.plan)!.stored, 1);
      // Identity is preserved — it's the same package, re-measured.
      expect(evicted.journeyKey, m.journeyKey);
      expect(evicted.fetchedAtMs, m.fetchedAtMs);
    });

    test('losing every tile does not fake a failed package', () {
      // Other parts still hold data, so this is partial, not failed.
      final m = manifestOf([
        part(OfflinePartKind.plan, expected: 1, stored: 1, bytes: 10),
        part(OfflinePartKind.tiles, expected: 100, stored: 0, bytes: 0),
      ], fetchedAt: now);
      expect(packageState(manifest: m, now: now), OfflinePackageState.partial);
      expect(m.isBarren, isFalse);
    });
  });

  group('tile budget constants', () {
    test('the corridor zoom band is the one the byte budget was sized for', () {
      // Measured against OpenFreeMap: ~250 KB/tile at z9 down to ~60 KB at z11.
      // If this band widens, re-measure — the budget is not a free parameter.
      expect(kOfflineTileMinZoom, 9);
      expect(kOfflineTileMaxZoom, 11);
      expect(kOfflineMaxTileBytes, 25 * 1024 * 1024);
      expect(kOfflineMaxTiles, 600);
    });

    test('the default corridor stays inside the tile ceiling for a long route', () {
      // Hamburg → Munich, sampled coarsely; the real polyline is denser but the
      // corridor width (and so the tile count per zoom) is the same.
      final route = [
        (lat: 53.5528, lng: 10.0067),
        (lat: 52.3759, lng: 9.7320),
        (lat: 51.3397, lng: 9.4936),
        (lat: 50.1109, lng: 8.6821),
        (lat: 49.4521, lng: 11.0767),
        (lat: 48.1351, lng: 11.5820),
      ];
      final tiles = tilesAlongRoute(route);
      expect(tiles.length, lessThanOrEqualTo(kOfflineMaxTiles));
      expect(tiles.every((t) =>
          t.z >= kOfflineTileMinZoom && t.z <= kOfflineTileMaxZoom), isTrue);
    });
  });

  group('shouldAutoRefresh', () {
    final departure = now.add(const Duration(hours: 3));

    test('refreshes a stale package shortly before departure', () {
      expect(
        shouldAutoRefresh(
          state: OfflinePackageState.stale,
          online: true,
          now: now,
          departure: departure,
        ),
        isTrue,
      );
    });

    test('never downloads a package the user did not ask for', () {
      expect(
        shouldAutoRefresh(
          state: OfflinePackageState.missing,
          online: true,
          now: now,
          departure: departure,
        ),
        isFalse,
      );
    });

    test('offline → no attempt', () {
      expect(
        shouldAutoRefresh(
          state: OfflinePackageState.stale,
          online: false,
          now: now,
          departure: departure,
        ),
        isFalse,
      );
    });

    test('a fresh package is left alone', () {
      expect(
        shouldAutoRefresh(
          state: OfflinePackageState.ready,
          online: true,
          now: now,
          departure: departure,
        ),
        isFalse,
      );
    });

    test('does nothing while a download is already running', () {
      expect(
        shouldAutoRefresh(
          state: OfflinePackageState.downloading,
          online: true,
          now: now,
          departure: departure,
        ),
        isFalse,
      );
    });

    test('outside the window → no attempt', () {
      expect(
        shouldAutoRefresh(
          state: OfflinePackageState.stale,
          online: true,
          now: now,
          departure: now.add(kOfflineAutoRefreshWindow + const Duration(hours: 1)),
        ),
        isFalse,
      );
    });

    test('after departure → too late to be worth bytes', () {
      expect(
        shouldAutoRefresh(
          state: OfflinePackageState.stale,
          online: true,
          now: now,
          departure: now.subtract(const Duration(minutes: 1)),
        ),
        isFalse,
      );
    });

    test('a journey with no departure time is never auto-refreshed', () {
      expect(
        shouldAutoRefresh(
          state: OfflinePackageState.stale,
          online: true,
          now: now,
          departure: null,
        ),
        isFalse,
      );
    });

    test('retries a failed package inside the window', () {
      expect(
        shouldAutoRefresh(
          state: OfflinePackageState.failed,
          online: true,
          now: now,
          departure: departure,
        ),
        isTrue,
      );
    });
  });

  group('offlineAgeLabel', () {
    test('reads as something a rider can act on', () {
      expect(offlineAgeLabel(Duration.zero), 'gerade eben');
      expect(offlineAgeLabel(const Duration(seconds: 30)), 'gerade eben');
      expect(offlineAgeLabel(const Duration(minutes: 5)), 'vor 5 min');
      expect(offlineAgeLabel(const Duration(minutes: 59)), 'vor 59 min');
      expect(offlineAgeLabel(const Duration(hours: 1)), 'vor 1 h');
      expect(offlineAgeLabel(const Duration(hours: 23)), 'vor 23 h');
      expect(offlineAgeLabel(const Duration(days: 2)), 'vor 2 d');
    });

    test('clock skew reads as "gerade eben", never a negative age', () {
      expect(offlineAgeLabel(const Duration(minutes: -5)), 'gerade eben');
    });
  });

  group('offlineSizeLabel', () {
    test('scales and uses a German decimal comma', () {
      expect(offlineSizeLabel(0), '0 B');
      expect(offlineSizeLabel(512), '512 B');
      expect(offlineSizeLabel(1024), '1 KB');
      expect(offlineSizeLabel(1536), '2 KB');
      expect(offlineSizeLabel(1024 * 1024), '1,0 MB');
      expect(offlineSizeLabel(8 * 1024 * 1024 + 512 * 1024), '8,5 MB');
      expect(offlineSizeLabel(25 * 1024 * 1024), '25,0 MB');
    });
  });

  group('tileForLatLng', () {
    test('matches the known slippy tile for Berlin Hbf at z12', () {
      expect(tileForLatLng(52.5200, 13.4050, 12), const TileRef(12, 2200, 1343));
    });

    test('z0 is a single tile whatever the coordinate', () {
      expect(tileForLatLng(52.52, 13.405, 0), const TileRef(0, 0, 0));
      expect(tileForLatLng(-33.9, 151.2, 0), const TileRef(0, 0, 0));
    });

    test('clamps beyond the Mercator limit instead of going out of range', () {
      final t = tileForLatLng(89.9, 0, 4);
      expect(t.y, inInclusiveRange(0, 15));
      expect(t.x, inInclusiveRange(0, 15));
    });
  });

  group('tilesAlongRoute', () {
    final berlin = (lat: 52.5200, lng: 13.4050);
    final hamburg = (lat: 53.5528, lng: 10.0067);

    test('no points → no tiles', () {
      expect(tilesAlongRoute(const []), isEmpty);
    });

    test('covers every requested zoom', () {
      final tiles = tilesAlongRoute([berlin], minZoom: 8, maxZoom: 11);
      expect(tiles.map((t) => t.z).toSet(), {8, 9, 10, 11});
    });

    test('includes a buffer ring around each point', () {
      final tiles =
          tilesAlongRoute([berlin], minZoom: 12, maxZoom: 12, buffer: 1);
      // 3x3 around the centre tile.
      expect(tiles.length, 9);
      expect(tiles, contains(const TileRef(12, 2200, 1343)));
      expect(tiles, contains(const TileRef(12, 2199, 1342)));
      expect(tiles, contains(const TileRef(12, 2201, 1344)));
    });

    test('buffer 0 is just the tile itself', () {
      final tiles =
          tilesAlongRoute([berlin], minZoom: 12, maxZoom: 12, buffer: 0);
      expect(tiles, [const TileRef(12, 2200, 1343)]);
    });

    test('deduplicates overlapping points', () {
      final many = List.filled(50, berlin);
      final tiles = tilesAlongRoute(many, minZoom: 12, maxZoom: 12, buffer: 1);
      expect(tiles.length, 9);
      expect(tiles.toSet().length, tiles.length);
    });

    test('a longer route needs more tiles than a single point', () {
      final one = tilesAlongRoute([berlin], minZoom: 10, maxZoom: 10);
      final two = tilesAlongRoute([berlin, hamburg], minZoom: 10, maxZoom: 10);
      expect(two.length, greaterThan(one.length));
    });

    test('honours the cap, and keeps the low zooms when it bites', () {
      // Truncation must leave a usable wide overview, not a random patch of
      // detail — so low zooms are emitted first.
      final tiles =
          tilesAlongRoute([berlin, hamburg], minZoom: 8, maxZoom: 14, maxTiles: 12);
      expect(tiles.length, 12);
      expect(tiles.every((t) => t.z <= 9), isTrue);
      expect(tiles.any((t) => t.z == 8), isTrue);
    });

    test('maxTiles of zero yields nothing', () {
      expect(tilesAlongRoute([berlin], maxTiles: 0), isEmpty);
    });

    test('is deterministic across runs', () {
      final a = tilesAlongRoute([berlin, hamburg], minZoom: 9, maxZoom: 10);
      final b = tilesAlongRoute([berlin, hamburg], minZoom: 9, maxZoom: 10);
      expect(a, b);
    });

    test('never emits a tile outside the zoom grid', () {
      // A point at the antimeridian/pole corner would otherwise buffer off-grid.
      final tiles = tilesAlongRoute(
        [(lat: 85.0, lng: 179.9)],
        minZoom: 3,
        maxZoom: 3,
        buffer: 2,
      );
      for (final t in tiles) {
        expect(t.x, inInclusiveRange(0, 7));
        expect(t.y, inInclusiveRange(0, 7));
      }
    });
  });

  group('TileRef', () {
    test('value equality, so dedupe works', () {
      expect(const TileRef(1, 2, 3), const TileRef(1, 2, 3));
      expect(const TileRef(1, 2, 3).hashCode, const TileRef(1, 2, 3).hashCode);
      expect(const TileRef(1, 2, 3), isNot(const TileRef(1, 2, 4)));
    });
  });
}
