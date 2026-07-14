import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/station.dart';
import '../utils/geo_query.dart';
import 'service_providers.dart';

/// Debounced station search provider.
///
/// Riverpod 3 dropped the separate `AutoDisposeAsyncNotifier` base class — a
/// plain [AsyncNotifier] is used for both, with auto-dispose selected on the
/// provider (`AsyncNotifierProvider.autoDispose`).
class StationSearchNotifier extends AsyncNotifier<List<Station>> {
  Timer? _debounce;

  /// Set while the current results are stops near a pasted coordinate rather
  /// than name matches — lets the field explain where the list came from.
  GeoQuery? _geo;
  GeoQuery? get geoQuery => _geo;

  @override
  Future<List<Station>> build() async => [];

  void search(String query) {
    _debounce?.cancel();
    // A coordinate or map link → offer the nearest stops instead of searching
    // for a station literally named "53.4, 14.5" (#11). Useful exactly where
    // the normal search gives up: a place with no address or stop name.
    final geo = parseGeoQuery(query);
    if (geo != null) {
      _geo = geo;
      _debounce = Timer(const Duration(milliseconds: 300), () async {
        state = const AsyncLoading();
        try {
          state = AsyncData(await ref.read(hafasServiceProvider).nearbyStations(
                latitude: geo.latitude,
                longitude: geo.longitude,
              ));
        } catch (e) {
          state = AsyncError(e, StackTrace.current);
        }
      });
      return;
    }
    _geo = null;
    if (query.length < 2) {
      state = const AsyncData([]);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 300), () async {
      state = const AsyncLoading();
      try {
        final results = await ref.read(hafasServiceProvider).searchStations(query);
        state = AsyncData(results);
      } catch (e) {
        state = AsyncError(e, StackTrace.current);
      }
    });
  }

  void clear() {
    _debounce?.cancel();
    _geo = null;
    state = const AsyncData([]);
  }
}

final stationSearchProvider =
    AsyncNotifierProvider.autoDispose<StationSearchNotifier, List<Station>>(
        StationSearchNotifier.new);
