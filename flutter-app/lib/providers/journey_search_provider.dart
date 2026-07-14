import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/station.dart';
import '../core/app_log.dart';
import '../models/journey.dart';
import 'prediction_provider.dart';
import 'service_providers.dart';
import 'settings_provider.dart';

enum JourneySortMode { departure, arrival, duration, transfers, reliability }

/// Coarse transport categories for the multimodal filter. The journey search
/// already returns every mode (bus, tram, U-/S-Bahn, regional, long-distance);
/// this lets the user hide modes client-side without re-querying.
enum ProductCategory {
  fern('Fernverkehr'),
  regional('Regional'),
  sbahn('S-Bahn'),
  ubahn('U-Bahn'),
  tram('Tram'),
  bus('Bus & Fähre');

  final String label;
  const ProductCategory(this.label);

  /// Map a HAFAS/Vendo product string to its category.
  static ProductCategory of(String? product) {
    switch (product) {
      case 'nationalExpress':
      case 'national':
        return ProductCategory.fern;
      case 'suburban':
        return ProductCategory.sbahn;
      case 'subway':
        return ProductCategory.ubahn;
      case 'tram':
        return ProductCategory.tram;
      case 'bus':
      case 'ferry':
        return ProductCategory.bus;
      case 'regional':
      default:
        return ProductCategory.regional;
    }
  }
}

class JourneySearchState {
  final Station? from;
  final Station? to;
  final DateTime? dateTime;
  final bool isArrival;
  final JourneyResult? result;
  final bool isLoading;
  final String? error;
  final JourneySortMode sortMode;

  /// Which transport categories to show. All enabled by default (full
  /// multimodal); the user can hide modes (e.g. only Fernverkehr).
  final Set<ProductCategory> products;

  JourneySearchState({
    this.from,
    this.to,
    this.dateTime,
    this.isArrival = false,
    this.result,
    this.isLoading = false,
    this.error,
    this.sortMode = JourneySortMode.departure,
    Set<ProductCategory>? products,
  }) : products = products ?? ProductCategory.values.toSet();

  /// Whether the search should be by arrival. Only meaningful with a chosen
  /// time — "arrive now" is nonsense, so "Jetzt" (no time) always means
  /// departure regardless of the toggle's last value.
  bool get useArrival => dateTime != null && isArrival;

  JourneySearchState copyWith({
    Station? from,
    Station? to,
    DateTime? dateTime,
    bool? isArrival,
    JourneyResult? result,
    bool? isLoading,
    String? error,
    JourneySortMode? sortMode,
    Set<ProductCategory>? products,
    bool clearDateTime = false,
  }) {
    return JourneySearchState(
      from: from ?? this.from,
      to: to ?? this.to,
      dateTime: clearDateTime ? null : (dateTime ?? this.dateTime),
      isArrival: isArrival ?? this.isArrival,
      result: result ?? this.result,
      isLoading: isLoading ?? this.isLoading,
      error: error,
      sortMode: sortMode ?? this.sortMode,
      products: products ?? this.products,
    );
  }

  /// True when [journey] uses only currently-enabled transport categories
  /// (walking legs ignored).
  bool _passesProductFilter(Journey journey) {
    if (products.length == ProductCategory.values.length) return true;
    return journey.legs
        .where((l) => !l.isWalking)
        .every((l) => products.contains(ProductCategory.of(l.line?.product)));
  }

  List<Journey> get sortedJourneys {
    if (result == null) return [];
    final journeys =
        result!.journeys.where(_passesProductFilter).toList();
    switch (sortMode) {
      case JourneySortMode.departure:
        journeys.sort((a, b) =>
            (a.departure ?? DateTime(0)).compareTo(b.departure ?? DateTime(0)));
      case JourneySortMode.arrival:
        journeys.sort((a, b) =>
            (a.arrival ?? DateTime(0)).compareTo(b.arrival ?? DateTime(0)));
      case JourneySortMode.duration:
        journeys.sort((a, b) =>
            (a.duration ?? Duration.zero).compareTo(b.duration ?? Duration.zero));
      case JourneySortMode.transfers:
        journeys.sort((a, b) => a.transfers.compareTo(b.transfers));
      case JourneySortMode.reliability:
        // Needs the per-journey prediction, which is async and lives in its
        // own provider — sorted by [reliabilitySortedJourneysProvider], which
        // starts from this (departure-ordered) list.
        journeys.sort((a, b) =>
            (a.departure ?? DateTime(0)).compareTo(b.departure ?? DateTime(0)));
    }
    return journeys;
  }
}

class JourneySearchNotifier extends Notifier<JourneySearchState> {
  @override
  JourneySearchState build() => JourneySearchState();

  void setFrom(Station? station) => state = state.copyWith(from: station);
  void setTo(Station? station) => state = state.copyWith(to: station);
  void setDateTime(DateTime? dt) => state = state.copyWith(dateTime: dt);
  void setIsArrival(bool val) => state = state.copyWith(isArrival: val);

  /// Back to "Jetzt": clear the chosen time and fall back to departure (an
  /// arrival search only makes sense with a fixed time).
  void resetToNow() =>
      state = state.copyWith(clearDateTime: true, isArrival: false);
  void setSortMode(JourneySortMode mode) =>
      state = state.copyWith(sortMode: mode);

  /// Toggle a transport category in the multimodal filter. Never lets the user
  /// deselect the last category (that would hide everything) — re-enabling all
  /// instead.
  void toggleProduct(ProductCategory cat) {
    final next = Set<ProductCategory>.from(state.products);
    if (!next.remove(cat)) next.add(cat);
    if (next.isEmpty) next.addAll(ProductCategory.values);
    state = state.copyWith(products: next);
  }

  void setAllProducts() =>
      state = state.copyWith(products: ProductCategory.values.toSet());

  void swapStations() {
    state = state.copyWith(from: state.to, to: state.from);
  }

  /// Search with optional text fallback for unresolved station names
  Future<void> search({String? fromText, String? toText}) async {
    state = state.copyWith(isLoading: true, error: null);

    try {
      final hafas = ref.read(hafasServiceProvider);

      // Auto-resolve stations from text if not selected from dropdown
      var from = state.from;
      var to = state.to;

      if (from == null && fromText != null && fromText.trim().length >= 2) {
        final results = await hafas.searchStations(fromText.trim());
        if (results.isNotEmpty) {
          from = results.first;
          state = state.copyWith(from: from);
        }
      }

      if (to == null && toText != null && toText.trim().length >= 2) {
        final results = await hafas.searchStations(toText.trim());
        if (results.isNotEmpty) {
          to = results.first;
          state = state.copyWith(to: to);
        }
      }

      if (from == null || to == null) {
        state = state.copyWith(
          isLoading: false,
          error: from == null && to == null
              ? 'Start und Ziel eingeben.'
              : from == null
                  ? 'Startstation nicht gefunden.'
                  : 'Zielstation nicht gefunden.',
        );
        return;
      }

      AppLog.log('search ${from.name} (${from.id}) → ${to.name} (${to.id}) '
          'at ${state.dateTime ?? "now"} '
          '${state.useArrival ? "[arrival]" : "[departure]"}', tag: 'journey');

      // DB Vendo (DB Navigator backend) is the only working journey source:
      // it returns journeys WITH prices and is not Akamai-gated. The old
      // bahn.de-website journey POST (OPS_BLOCKED) and the public HAFAS mirror
      // (chronically down) were removed — they never succeeded and only added a
      // multi-second hang before the real error surfaced.
      final vendo = ref.read(vendoServiceProvider);
      final party = ref.read(settingsProvider).searchParty;
      final result = await vendo.searchJourneys(
        fromLocationId: from.vendoLocationId,
        toLocationId: to.vendoLocationId,
        dateTime: state.dateTime ?? DateTime.now(),
        isArrival: state.useArrival,
        firstClass: party.firstClass,
        reisende: party.toReisendeJson(),
        deutschlandTicket: party.deutschlandTicket,
      );
      AppLog.log('vendo result: ${result.journeys.length} journeys',
          tag: 'journey');
      state = state.copyWith(result: result, isLoading: false);
    } catch (e) {
      AppLog.log('search FAILED: $e', tag: 'journey');
      state = state.copyWith(error: 'Fehler: $e', isLoading: false);
    }
  }

  /// Load earlier connections by replaying the Vendo `frueherContext` token,
  /// prepending the (deduped) results and advancing the earlier token.
  Future<void> loadEarlier() => _loadMore(earlier: true);

  /// Load later connections via the `spaeterContext` token.
  Future<void> loadLater() => _loadMore(earlier: false);

  Future<void> _loadMore({required bool earlier}) async {
    final current = state.result;
    final token = earlier ? current?.earlierRef : current?.laterRef;
    if (token == null || state.from == null || state.to == null) return;

    state = state.copyWith(isLoading: true, error: null);
    try {
      final vendo = ref.read(vendoServiceProvider);
      final party = ref.read(settingsProvider).searchParty;
      final more = await vendo.searchJourneys(
        fromLocationId: state.from!.vendoLocationId,
        toLocationId: state.to!.vendoLocationId,
        dateTime: state.dateTime ?? DateTime.now(),
        isArrival: state.useArrival,
        context: token,
        firstClass: party.firstClass,
        reisende: party.toReisendeJson(),
        deutschlandTicket: party.deutschlandTicket,
      );

      // Dedupe against what we already show (paged windows can overlap).
      final existing = current?.journeys ?? const [];
      final seen = existing.map(_journeyKey).toSet();
      final fresh =
          more.journeys.where((j) => seen.add(_journeyKey(j))).toList();

      final combined = JourneyResult(
        journeys: earlier
            ? [...fresh, ...existing]
            : [...existing, ...fresh],
        // Advance only the token we scrolled; keep the other end intact.
        earlierRef: earlier ? more.earlierRef : current?.earlierRef,
        laterRef: earlier ? current?.laterRef : more.laterRef,
      );
      state = state.copyWith(result: combined, isLoading: false);
    } catch (e) {
      AppLog.log('loadMore(${earlier ? "earlier" : "later"}) failed: $e',
          tag: 'journey');
      state = state.copyWith(isLoading: false);
    }
  }

  /// Stable identity for a journey, to dedupe overlapping paged windows.
  String _journeyKey(Journey j) =>
      j.refreshToken ??
      '${j.departure?.toIso8601String()}|${j.arrival?.toIso8601String()}'
          '|${j.legs.firstOrNull?.line?.name ?? ''}';

  void clear() {
    state = JourneySearchState();
  }
}

final journeySearchProvider =
    NotifierProvider<JourneySearchNotifier, JourneySearchState>(
        JourneySearchNotifier.new);

/// The result list the UI renders — [JourneySearchState.sortedJourneys], except
/// in `reliability` mode, where it's re-ordered by the prediction model.
///
/// Separate from the state getter because the score is async: each journey's
/// prediction is its own request. Predictions stream in, so the list settles
/// rather than appearing sorted at once — journeys still waiting on (or
/// missing) a score keep their departure order at the bottom instead of
/// jumping around. The requests are the same ones the badges already make, so
/// this mode costs nothing extra.
final reliabilitySortedJourneysProvider =
    Provider.autoDispose<List<Journey>>((ref) {
  final state = ref.watch(journeySearchProvider);
  final journeys = state.sortedJourneys;
  if (state.sortMode != JourneySortMode.reliability) return journeys;

  final scored = <({Journey journey, double? score, int order})>[
    for (final (i, j) in journeys.indexed)
      (
        journey: j,
        score: ref
            .watch(journeyPredictionProvider(PredictionRequest(j)))
            .asData
            ?.value
            ?.reliabilityScore,
        order: i,
      ),
  ];
  // The index tiebreaker keeps this stable (List.sort isn't), so equal or
  // still-unscored connections hold their departure order instead of shuffling
  // on every rebuild as predictions land.
  scored.sort((a, b) {
    if (a.score == null && b.score == null) return a.order.compareTo(b.order);
    if (a.score == null) return 1; // unscored last — not "least reliable"
    if (b.score == null) return -1;
    final byScore = b.score!.compareTo(a.score!); // most reliable first
    return byScore != 0 ? byScore : a.order.compareTo(b.order);
  });
  return [for (final e in scored) e.journey];
});
