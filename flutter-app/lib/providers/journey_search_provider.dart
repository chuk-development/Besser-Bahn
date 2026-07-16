import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/station.dart';
import '../core/app_log.dart';
import '../models/journey.dart';
import '../models/search_options.dart';
import '../utils/journey_highlights.dart';
import 'prediction_provider.dart';
import 'service_providers.dart';
import 'settings_provider.dart';

enum JourneySortMode { departure, arrival, duration, transfers, reliability }

/// Coarse transport categories for the multimodal filter. Each maps to the
/// Vendo `VerkehrsmittelModel` values sent with the search, so the backend
/// only ever computes the modes the user wants. The Fern/Regio split mirrors
/// the DB Navigator's own `verkehrsmittelListFern` (ICE + IC/EC + IR).
enum ProductCategory {
  fern('Fernverkehr', [
    'HOCHGESCHWINDIGKEITSZUEGE',
    'INTERCITYUNDEUROCITYZUEGE',
    'INTERREGIOUNDSCHNELLZUEGE',
  ]),
  regional('Regional', ['NAHVERKEHRSONSTIGEZUEGE', 'ANRUFPFLICHTIGEVERKEHRE']),
  sbahn('S-Bahn', ['SBAHNEN']),
  ubahn('U-Bahn', ['UBAHN']),
  tram('Tram', ['STRASSENBAHN']),
  bus('Bus & Fähre', ['BUSSE', 'SCHIFFE']);

  final String label;

  /// Vendo `verkehrsmittel` codes this category selects.
  final List<String> vendoCodes;
  const ProductCategory(this.label, this.vendoCodes);

  /// The `verkehrsmittel` array for a set of categories. All categories
  /// selected → `['ALL']`, matching the Navigator's own default request.
  static List<String> codesFor(Set<ProductCategory> cats) {
    if (cats.isEmpty || cats.length == ProductCategory.values.length) {
      return const ['ALL'];
    }
    return [for (final c in cats) ...c.vendoCodes];
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

  /// Only show connections the Deutschlandticket already covers. Asked for in
  /// #18 ("existiert auf der bahn.de Website"); the backend does the work.
  final bool onlyDeutschlandTicket;

  /// The transfer profile's minimum was dropped because nothing matched it —
  /// the results below have changes this rider may not manage. Told to them
  /// rather than silently handing back tight connections.
  final bool transferProfileRelaxed;

  /// Max. changes / min. transfer time / via station — the backend-enforced
  /// part of the search the rider steers (#19).
  final SearchOptions options;

  /// Bumped once per [JourneySearchNotifier.search] that lands results.
  /// Deliberately NOT touched by "Früher"/"Später", which also replace
  /// [result] — the search form folds itself away on a fresh search, and a
  /// form the rider just reopened must survive them paging the list.
  final int resultSerial;

  JourneySearchState({
    this.from,
    this.to,
    this.dateTime,
    this.isArrival = false,
    this.result,
    this.isLoading = false,
    this.error,
    this.sortMode = JourneySortMode.departure,
    this.onlyDeutschlandTicket = false,
    this.transferProfileRelaxed = false,
    this.options = const SearchOptions(),
    this.resultSerial = 0,
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
    bool? onlyDeutschlandTicket,
    bool? transferProfileRelaxed,
    SearchOptions? options,
    int? resultSerial,
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
      onlyDeutschlandTicket:
          onlyDeutschlandTicket ?? this.onlyDeutschlandTicket,
      transferProfileRelaxed:
          transferProfileRelaxed ?? this.transferProfileRelaxed,
      options: options ?? this.options,
      resultSerial: resultSerial ?? this.resultSerial,
    );
  }

  List<Journey> get sortedJourneys {
    if (result == null) return [];
    // No client-side product filter: the backend already searched for exactly
    // the selected modes. Re-filtering here would drop connections it
    // deliberately returned (e.g. a feeder bus on an otherwise regional trip).
    final journeys = result!.journeys.toList();
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
  /// instead. The filter is part of the query, so this re-runs the search.
  void toggleProduct(ProductCategory cat) {
    final next = Set<ProductCategory>.from(state.products);
    if (!next.remove(cat)) next.add(cat);
    if (next.isEmpty) next.addAll(ProductCategory.values);
    state = state.copyWith(products: next);
    if (state.result != null) search();
  }

  void setAllProducts() {
    state = state.copyWith(products: ProductCategory.values.toSet());
    if (state.result != null) search();
  }

  /// Restrict the search to Deutschlandticket-covered connections. Like the
  /// product filter this is part of the query, so it re-runs the search.
  void toggleOnlyDeutschlandTicket() {
    state = state.copyWith(
        onlyDeutschlandTicket: !state.onlyDeutschlandTicket);
    if (state.result != null) search();
  }

  /// Apply max. changes / min. transfer time / via (#19). Backend-enforced, so
  /// like the other query parts this re-runs the search — but only if the
  /// options actually changed, since the sheet applies on every close.
  void setOptions(SearchOptions options) {
    if (options == state.options) return;
    state = state.copyWith(options: options);
    if (state.result != null) search();
  }

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
      final settings = ref.read(settingsProvider);
      final party = settings.searchParty;
      final options = state.options;
      // Ask DB for transfers this rider can actually make, instead of judging
      // 5-minute changes after the fact (#19). An explicit wish from the
      // options sheet wins over the profile's guess; null for fast/normal.
      final fromProfile = options.minTransferMinutes == null;
      final minTransfer = options.minTransferMinutes ??
          settings.transferProfile.minTransferMinutes;

      Future<JourneyResult> run({int? minTransferMinutes}) =>
          vendo.searchJourneys(
            fromLocationId: from!.vendoLocationId,
            toLocationId: to!.vendoLocationId,
            dateTime: state.dateTime ?? DateTime.now(),
            isArrival: state.useArrival,
            firstClass: party.firstClass,
            reisende: party.toReisendeJson(),
            deutschlandTicket: party.deutschlandTicket,
            verkehrsmittel: ProductCategory.codesFor(state.products),
            nurDeutschlandTicketVerbindungen: state.onlyDeutschlandTicket,
            minTransferMinutes: minTransferMinutes,
            maxTransfers: options.maxTransfers,
            viaLocations: options.viaLocationsJson,
          );

      var result = await run(minTransferMinutes: minTransfer);
      var relaxed = false;
      // A profile that's too demanding for the route comes back empty — the
      // backend answers an impossible constraint with an empty list, not an
      // error. Showing "nothing found" would be a lie: connections exist, they
      // just have tight changes. Retry unconstrained and say so.
      //
      // Only for the *profile's* minimum. A number the rider typed into the
      // options sheet is a filter like any other — quietly ignoring it would
      // be worse than an empty list they know how to widen.
      if (result.journeys.isEmpty && minTransfer != null && fromProfile) {
        AppLog.log('no journeys with minUmstiegsdauer=$minTransfer — retrying',
            tag: 'journey');
        result = await run();
        relaxed = result.journeys.isNotEmpty;
      }
      AppLog.log('vendo result: ${result.journeys.length} journeys'
          '${relaxed ? " (profile relaxed)" : ""}', tag: 'journey');
      state = state.copyWith(
          result: result,
          isLoading: false,
          transferProfileRelaxed: relaxed,
          resultSerial: state.resultSerial + 1);
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
      final settings = ref.read(settingsProvider);
      final party = settings.searchParty;
      final options = state.options;
      // The constraints have to travel with the paged request too — the
      // context token scrolls the window, it doesn't carry the wish. Without
      // them, "Später" would append the very 5-minute changes the first page
      // was searched to avoid.
      //
      // Deliberately no relax-retry here: an empty page means this end of the
      // window has nothing left, not that the profile is too strict — the
      // first page already proved connections exist.
      final more = await vendo.searchJourneys(
        fromLocationId: state.from!.vendoLocationId,
        toLocationId: state.to!.vendoLocationId,
        dateTime: state.dateTime ?? DateTime.now(),
        isArrival: state.useArrival,
        context: token,
        firstClass: party.firstClass,
        reisende: party.toReisendeJson(),
        deutschlandTicket: party.deutschlandTicket,
        verkehrsmittel: ProductCategory.codesFor(state.products),
        nurDeutschlandTicketVerbindungen: state.onlyDeutschlandTicket,
        minTransferMinutes: state.transferProfileRelaxed
            ? null
            : options.minTransferMinutes ??
                settings.transferProfile.minTransferMinutes,
        maxTransfers: options.maxTransfers,
        viaLocations: options.viaLocationsJson,
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

/// Which connection is the fastest / cheapest / safest / best compromise of
/// the current result list (#11, point 9).
///
/// Reads the same per-journey predictions the badges and the reliability sort
/// already request, so the labels fill in as those land — no extra traffic.
final journeyHighlightsProvider =
    Provider.autoDispose<Map<JourneyHighlight, Journey>>((ref) {
  final journeys = ref.watch(journeySearchProvider).sortedJourneys;
  return journeyHighlights(
    journeys,
    (j) => ref
        .watch(journeyPredictionProvider(PredictionRequest(j)))
        .asData
        ?.value
        ?.reliabilityScore,
  );
});

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
