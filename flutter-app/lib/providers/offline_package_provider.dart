import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/app_log.dart';
import '../core/offline_package.dart';
import '../models/journey.dart';
import '../services/offline_package_service.dart';
import '../services/offline_store.dart';
import 'account_provider.dart';
import 'connectivity_provider.dart';
import 'service_providers.dart';

final offlineStoreProvider =
    Provider<OfflineStore>((ref) => OfflineStore.instance);

final offlinePackageServiceProvider = Provider<OfflinePackageService>((ref) {
  return OfflinePackageService(
    vendo: ref.watch(vendoServiceProvider),
    coach: ref.watch(coachSequenceServiceProvider),
    stationMap: ref.watch(stationMapServiceProvider),
    store: ref.watch(offlineStoreProvider),
  );
});

/// What one journey's package looks like right now.
///
/// [state] is a getter, not a field, on purpose: a package goes stale by the
/// clock, so a state computed once at load time would keep claiming "Offline
/// verfügbar" hours after it stopped being true. Deriving it per read means the
/// badge is honest at the moment it's rendered.
class OfflinePackageStatus {
  final OfflineManifest? manifest;
  final bool downloading;

  /// Set only while [downloading].
  final OfflineDownloadProgress? progress;

  const OfflinePackageStatus({
    this.manifest,
    this.downloading = false,
    this.progress,
  });

  static const none = OfflinePackageStatus();

  OfflinePackageState get state => packageState(
        manifest: manifest,
        downloading: downloading,
        now: DateTime.now(),
      );

  /// "vor 3 h" — the age that has to accompany any offline data.
  String? get ageLabel {
    final m = manifest;
    if (m == null) return null;
    return offlineAgeLabel(m.ageAt(DateTime.now()));
  }

  int get bytes => manifest?.totalBytes ?? 0;

  String get sizeLabel => offlineSizeLabel(bytes);

  OfflinePackageStatus copyWith({
    OfflineManifest? manifest,
    bool? downloading,
    OfflineDownloadProgress? progress,
  }) =>
      OfflinePackageStatus(
        manifest: manifest ?? this.manifest,
        downloading: downloading ?? this.downloading,
        progress: progress,
      );
}

/// Every journey's package, keyed by `SavedJourney.key`.
///
/// One notifier for all keys rather than a family: this Riverpod version ships
/// no family notifier (same reason `ticketProvider` is a `FutureProvider.family`),
/// and a download outlives the tile that started it anyway — keeping the map
/// here means scrolling away from a downloading row can't orphan it.
class OfflinePackagesNotifier
    extends Notifier<Map<String, OfflinePackageStatus>> {
  @override
  Map<String, OfflinePackageStatus> build() {
    _loadAll();
    return const {};
  }

  Future<void> _loadAll() async {
    final manifests = await ref.read(offlineStoreProvider).allManifests();
    state = {
      for (final m in manifests) m.journeyKey: OfflinePackageStatus(manifest: m),
    };
  }

  /// Status for one journey. Unknown key = nothing downloaded.
  OfflinePackageStatus statusFor(String journeyKey) =>
      state[journeyKey] ?? OfflinePackageStatus.none;

  void _put(String key, OfflinePackageStatus status) {
    state = {...state, key: status};
  }

  /// Download (or refresh) a journey's package. A second call while one is in
  /// flight is a no-op.
  Future<void> download(String journeyKey, Journey journey) async {
    final current = statusFor(journeyKey);
    if (current.downloading) return;

    // Keep the old manifest visible while refreshing — the rider should still
    // see what they currently have, not an empty row.
    _put(journeyKey, current.copyWith(downloading: true));

    try {
      final manifest = await ref.read(offlinePackageServiceProvider).download(
            journey,
            journeyKey: journeyKey,
            ticket: await _ticketInfo(journeyKey),
            onProgress: (p) {
              if (!statusFor(journeyKey).downloading) return;
              _put(
                  journeyKey,
                  OfflinePackageStatus(
                    manifest: current.manifest,
                    downloading: true,
                    progress: p,
                  ));
            },
          );
      _put(journeyKey, OfflinePackageStatus(manifest: manifest));
    } catch (e) {
      AppLog.log('offline package download failed ($e)', tag: 'offline');
      // Fall back to whatever was already there; a failed refresh must not
      // destroy a package that still works.
      _put(journeyKey, OfflinePackageStatus(manifest: current.manifest));
      rethrow;
    }
  }

  Future<void> delete(String journeyKey) async {
    await ref.read(offlineStoreProvider).delete(journeyKey);
    final next = {...state}..remove(journeyKey);
    state = next;
  }

  Future<void> deleteAll() async {
    await ref.read(offlineStoreProvider).deleteAll();
    state = const {};
  }

  /// Total bytes across every package.
  int get totalBytes =>
      state.values.fold(0, (sum, s) => sum + s.bytes);

  /// Does a ticket exist for this journey, and is it already cached?
  ///
  /// Resolved here rather than in the service: tickets are DB-account state and
  /// the download service deliberately knows nothing about auth.
  Future<OfflineTicketInfo> _ticketInfo(String journeyKey) async {
    try {
      final trips = await ref.read(ticketTripsProvider.future);
      final match = trips.where((t) => t.journeyKey == journeyKey).firstOrNull;
      if (match == null) return (exists: false, cached: false);
      return (exists: true, cached: await isTicketCachedOffline(match.ticketKey));
    } catch (_) {
      // Not logged in / list unavailable → "no ticket", rather than claiming
      // one is missing.
      return (exists: false, cached: false);
    }
  }
}

final offlinePackagesProvider = NotifierProvider<OfflinePackagesNotifier,
    Map<String, OfflinePackageStatus>>(OfflinePackagesNotifier.new);

/// One journey's status. Watch this from a row so only that row rebuilds.
final offlinePackageProvider =
    Provider.family<OfflinePackageStatus, String>((ref, journeyKey) {
  return ref.watch(offlinePackagesProvider)[journeyKey] ??
      OfflinePackageStatus.none;
});

/// Total bytes held by all packages, for the storage row in Settings.
final offlinePackagesSizeProvider = Provider<int>((ref) {
  final all = ref.watch(offlinePackagesProvider);
  return all.values.fold(0, (sum, s) => sum + s.bytes);
});

/// Fire the "keep it fresh before departure" top-up (#29).
///
/// The decision is [shouldAutoRefresh] — a pure function — so this is only
/// plumbing. Safe to call on every build: the in-flight guard in [
/// OfflinePackagesNotifier.download] makes a repeat call a no-op, and
/// [shouldAutoRefresh] returns false once the package is fresh again.
void maybeAutoRefreshPackage(WidgetRef ref, String journeyKey, Journey journey) {
  final status = ref.read(offlinePackageProvider(journeyKey));
  if (!shouldAutoRefresh(
    state: status.state,
    online: !ref.read(isOfflineProvider),
    now: DateTime.now(),
    departure: journey.plannedDeparture ?? journey.departure,
  )) {
    return;
  }
  // Fire-and-forget: a background courtesy, never something the user waits on.
  Future.microtask(() async {
    try {
      await ref
          .read(offlinePackagesProvider.notifier)
          .download(journeyKey, journey);
    } catch (_) {
      // Already logged; an auto-refresh that fails leaves the old package.
    }
  });
}
