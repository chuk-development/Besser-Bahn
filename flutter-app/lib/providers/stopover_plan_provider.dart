import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/app_log.dart';
import '../models/journey.dart';
import '../models/station.dart';
import '../utils/stopover_plan.dart';
import 'service_providers.dart';
import 'settings_provider.dart';
import '../core/extensions.dart';

/// What a stopover plan is asked for: get from [from] to [to], be there by
/// [deadline], and break the trip at [hub] on the way.
class StopoverPlanArgs {
  final Station from;
  final Station hub;
  final Station to;

  /// When the rider has to be at [to] — the appointment, not a train time.
  final DateTime deadline;

  const StopoverPlanArgs({
    required this.from,
    required this.hub,
    required this.to,
    required this.deadline,
  });

  StopoverPlanArgs copyWith({DateTime? deadline}) => StopoverPlanArgs(
    from: from,
    hub: hub,
    to: to,
    deadline: deadline ?? this.deadline,
  );
}

class StopoverPlanState {
  final StopoverPlanArgs? args;

  /// Minimum time the rider wants at the hub.
  final int stayMinutes;

  /// hub → to, nailed to the appointment: the latest one that still makes it.
  final Journey? secondLeg;

  /// from → hub, everything that leaves at least [stayMinutes] at the hub.
  final List<Journey> firstOptions;

  /// The one the rider picked out of [firstOptions].
  final Journey? firstLeg;

  /// Vendo's "earlier" token for the first-leg search, so the rider can keep
  /// walking backwards through the morning.
  final String? firstEarlierRef;

  /// First-leg connections the search returned but the stay filter dropped —
  /// the difference between "nothing runs" and "nothing gives you an hour".
  final int hiddenFirstCount;

  final bool isLoading;
  final String? error;

  const StopoverPlanState({
    this.args,
    this.stayMinutes = kDefaultStayMinutes,
    this.secondLeg,
    this.firstOptions = const [],
    this.firstLeg,
    this.firstEarlierRef,
    this.hiddenFirstCount = 0,
    this.isLoading = false,
    this.error,
  });

  /// When the second leg leaves the hub — the wall the first leg has to be in
  /// front of.
  DateTime? get hubDeparture =>
      secondLeg?.departure ?? secondLeg?.plannedDeparture;

  /// The stay the picked combination actually gives, which is at least
  /// [stayMinutes] and usually more.
  Duration? get plannedStay {
    final first = firstLeg;
    final second = secondLeg;
    if (first == null || second == null) return null;
    return stayBetween(first, second);
  }

  StopoverPlanState copyWith({
    StopoverPlanArgs? args,
    int? stayMinutes,
    Journey? secondLeg,
    List<Journey>? firstOptions,
    Journey? firstLeg,
    String? firstEarlierRef,
    int? hiddenFirstCount,
    bool? isLoading,
    String? error,
    bool clearFirstLeg = false,
    bool clearSecondLeg = false,
  }) => StopoverPlanState(
    args: args ?? this.args,
    stayMinutes: stayMinutes ?? this.stayMinutes,
    secondLeg: clearSecondLeg ? null : (secondLeg ?? this.secondLeg),
    firstOptions: firstOptions ?? this.firstOptions,
    firstLeg: clearFirstLeg ? null : (firstLeg ?? this.firstLeg),
    firstEarlierRef: firstEarlierRef ?? this.firstEarlierRef,
    hiddenFirstCount: hiddenFirstCount ?? this.hiddenFirstCount,
    isLoading: isLoading ?? this.isLoading,
    // Never sticky: an error belongs to the load that produced it.
    error: error,
  );
}

class StopoverPlanNotifier extends Notifier<StopoverPlanState> {
  @override
  StopoverPlanState build() => const StopoverPlanState();

  /// Begin a plan. Called before pushing the screen, the same way the station
  /// map is loaded before it is shown, so the screen only ever watches.
  void start(StopoverPlanArgs args, {int? stayMinutes}) {
    state = StopoverPlanState(
      args: args,
      stayMinutes: stayMinutes ?? kDefaultStayMinutes,
      isLoading: true,
    );
    load();
  }

  /// A later or earlier appointment moves both legs, so this reloads everything.
  void setDeadline(DateTime deadline) {
    final args = state.args;
    if (args == null || args.deadline == deadline) return;
    state = state.copyWith(
      args: args.copyWith(deadline: deadline),
      clearFirstLeg: true,
      clearSecondLeg: true,
      isLoading: true,
    );
    load();
  }

  /// The stay only constrains the *first* leg — the train to the appointment is
  /// unchanged, so this re-searches one half instead of both.
  void setStayMinutes(int minutes) {
    if (minutes == state.stayMinutes) return;
    state = state.copyWith(stayMinutes: minutes, clearFirstLeg: true);
    if (state.secondLeg == null) {
      load();
    } else {
      loadFirstLegs();
    }
  }

  void selectFirstLeg(Journey? journey) => state = journey == null
      ? state.copyWith(clearFirstLeg: true)
      : state.copyWith(firstLeg: journey);

  /// Both halves: the train to the appointment, then everything that gets to the
  /// hub in time to still catch it with the wanted stay in between.
  Future<void> load() async {
    final args = state.args;
    if (args == null) return;
    state = state.copyWith(isLoading: true, error: null);
    try {
      final result = await _search(
        from: args.hub,
        to: args.to,
        arriveBy: args.deadline,
      );
      final second = latestArrivingBy(result.journeys, args.deadline);
      if (second == null) {
        state = state.copyWith(
          isLoading: false,
          clearSecondLeg: true,
          firstOptions: const [],
          error:
              'Ab ${args.hub.name} ist ${args.to.name} um '
              '${_hhmm(args.deadline)} nicht erreichbar. '
              'Späteren Termin wählen.',
        );
        return;
      }
      state = state.copyWith(secondLeg: second, isLoading: false);
      await loadFirstLegs();
    } catch (e) {
      AppLog.log('stopover plan failed: $e', tag: 'stopover');
      state = state.copyWith(isLoading: false, error: 'Fehler: $e');
    }
  }

  /// from → hub, arriving early enough to still have [stayMinutes] before the
  /// second leg goes.
  Future<void> loadFirstLegs() async {
    final args = state.args;
    final hubDeparture = state.hubDeparture;
    if (args == null || hubDeparture == null) return;
    state = state.copyWith(isLoading: true, error: null);
    try {
      // Ask for arrival at the hub by "second leg leaves − wanted stay". DB then
      // returns the window ending there, which is exactly the set that qualifies
      // — plus a few just outside it, which the filter below drops.
      final target = hubDeparture.subtract(
        Duration(minutes: state.stayMinutes),
      );
      final result = await _search(
        from: args.from,
        to: args.hub,
        arriveBy: target,
      );
      final options = firstLegOptions(
        result.journeys,
        hubDeparture,
        minStayMinutes: state.stayMinutes,
      );
      state = state.copyWith(
        firstOptions: options,
        firstEarlierRef: result.earlierRef,
        hiddenFirstCount: result.journeys.length - options.length,
        isLoading: false,
      );
    } catch (e) {
      AppLog.log('stopover first legs failed: $e', tag: 'stopover');
      state = state.copyWith(isLoading: false, error: 'Fehler: $e');
    }
  }

  /// Walk the first leg further back in time — more time at the hub, earlier
  /// start. Same paging the result list uses, scoped to leg 1.
  Future<void> loadEarlierFirstLegs() async {
    final args = state.args;
    final token = state.firstEarlierRef;
    final hubDeparture = state.hubDeparture;
    if (args == null || token == null || hubDeparture == null) return;
    state = state.copyWith(isLoading: true, error: null);
    try {
      final target = hubDeparture.subtract(
        Duration(minutes: state.stayMinutes),
      );
      final result = await _search(
        from: args.from,
        to: args.hub,
        arriveBy: target,
        context: token,
      );
      final fresh = firstLegOptions(
        result.journeys,
        hubDeparture,
        minStayMinutes: state.stayMinutes,
      );
      // Paged windows overlap — dedupe against what is already listed.
      final seen = state.firstOptions.map(_key).toSet();
      final merged = [
        ...fresh.where((j) => seen.add(_key(j))),
        ...state.firstOptions,
      ];
      state = state.copyWith(
        firstOptions: merged,
        firstEarlierRef: result.earlierRef,
        hiddenFirstCount:
            state.hiddenFirstCount + (result.journeys.length - fresh.length),
        isLoading: false,
      );
    } catch (e) {
      AppLog.log('stopover earlier failed: $e', tag: 'stopover');
      state = state.copyWith(isLoading: false, error: 'Fehler: $e');
    }
  }

  /// One arrival search, with the rider's party and transfer profile — the two
  /// halves have to be priced and paced like any other search, or the plan is
  /// not comparable to the connection it came from.
  Future<JourneyResult> _search({
    required Station from,
    required Station to,
    required DateTime arriveBy,
    String? context,
  }) {
    final settings = ref.read(settingsProvider);
    final party = settings.searchParty;
    return ref
        .read(vendoServiceProvider)
        .searchJourneys(
          fromLocationId: from.vendoLocationId,
          toLocationId: to.vendoLocationId,
          dateTime: arriveBy,
          isArrival: true,
          context: context,
          firstClass: party.firstClass,
          reisende: party.toReisendeJson(),
          deutschlandTicket: party.deutschlandTicket,
          minTransferMinutes: settings.transferProfile.minTransferMinutes,
        );
  }

  String _key(Journey j) =>
      j.refreshToken ??
      '${j.departure?.toIso8601String()}|${j.arrival?.toIso8601String()}';

  static String _hhmm(DateTime dt) => dt.hhmm;
}

final stopoverPlanProvider =
    NotifierProvider<StopoverPlanNotifier, StopoverPlanState>(
      StopoverPlanNotifier.new,
    );
