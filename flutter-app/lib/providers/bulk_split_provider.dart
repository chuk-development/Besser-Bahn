import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../models/journey.dart';
import '../models/split_ticket.dart';
import '../services/db_api_service.dart';
import '../utils/split_engine.dart';
import '../utils/split_stops.dart';
import 'service_providers.dart';
import 'settings_provider.dart';

enum BulkRowStatus { pending, running, done, failed }

/// One connection in the bulk comparison: its direct fare (from the search) and
/// — once computed — the cheapest split for the same route.
class BulkSplitRow {
  final Journey journey;
  final String label; // "09:18 – 11:33"
  final Duration duration;
  final int transfers;
  final String trains; // "ICE" / "RE+ICE"
  final double? directPrice;
  final double? splitPrice;
  final BulkRowStatus status;

  /// The full analysis behind [splitPrice] — which tickets, where they break,
  /// what the D-Ticket covers. Kept so tapping the row can show the same detail
  /// as a single analysis instead of just a number (#24).
  final TicketAnalysisResult? result;

  const BulkSplitRow({
    required this.journey,
    required this.label,
    required this.duration,
    required this.transfers,
    required this.trains,
    this.directPrice,
    this.splitPrice,
    this.status = BulkRowStatus.pending,
    this.result,
  });

  /// The split genuinely beats the direct fare (more than a rounding cent).
  bool get splitWins =>
      directPrice != null &&
      splitPrice != null &&
      splitPrice! < directPrice! - 0.01;

  /// Best obtainable total for this departure (the cheaper of direct / split).
  double? get bestPrice {
    if (directPrice == null) return splitPrice;
    if (splitPrice == null) return directPrice;
    return splitPrice! < directPrice! ? splitPrice : directPrice;
  }

  BulkSplitRow copyWith({
    double? directPrice,
    double? splitPrice,
    BulkRowStatus? status,
    TicketAnalysisResult? result,
  }) =>
      BulkSplitRow(
        journey: journey,
        label: label,
        duration: duration,
        transfers: transfers,
        trains: trains,
        directPrice: directPrice ?? this.directPrice,
        splitPrice: splitPrice ?? this.splitPrice,
        status: status ?? this.status,
        result: result ?? this.result,
      );
}

class BulkSplitState {
  final bool running;
  final bool cancelled;
  final int doneCount;
  final int total;
  final List<BulkSplitRow> rows;

  /// Whether this run priced with the Deutschlandticket. Recorded when the run
  /// starts, because the result can't be asked afterwards and the setting can
  /// change mid-run — reading it live would relabel finished totals as
  /// surcharges (or the reverse) without re-pricing anything (#28).
  final bool deutschlandTicket;

  const BulkSplitState({
    this.running = false,
    this.cancelled = false,
    this.doneCount = 0,
    this.total = 0,
    this.rows = const [],
    this.deutschlandTicket = false,
  });

  BulkSplitState copyWith({
    bool? running,
    bool? cancelled,
    int? doneCount,
    int? total,
    List<BulkSplitRow>? rows,
    bool? deutschlandTicket,
  }) =>
      BulkSplitState(
        running: running ?? this.running,
        cancelled: cancelled ?? this.cancelled,
        doneCount: doneCount ?? this.doneCount,
        total: total ?? this.total,
        rows: rows ?? this.rows,
        deutschlandTicket: deutschlandTicket ?? this.deutschlandTicket,
      );
}

/// Prices every shown connection — direct vs cheapest split — so the rider can
/// compare departure times by total price. Runs one connection at a time on the
/// app-scoped provider (so it survives leaving the screen) and fills each row in
/// as it finishes.
class BulkSplitNotifier extends Notifier<BulkSplitState> {
  @override
  BulkSplitState build() => const BulkSplitState();

  int _gen = 0;

  void cancel() {
    _gen++;
    state = state.copyWith(running: false, cancelled: true);
  }

  void clear() {
    _gen++;
    state = const BulkSplitState();
  }

  static final _hm = DateFormat('HH:mm');

  /// Start (or restart) the comparison for [journeys] — typically the results
  /// currently shown for one search.
  Future<void> compare(List<Journey> journeys) async {
    final myGen = ++_gen;
    final settings = ref.read(settingsProvider);
    final engine = SplitEngine(
        ref.read(vendoServiceProvider), ref.read(dbApiServiceProvider));
    final reisende = settings.searchParty.toReisendeJson();
    final travellers =
        DbApiService.createTravellerPayload(bahnCard: settings.bahnCard);

    final rows = <BulkSplitRow>[];
    for (final j in journeys) {
      final dep = j.plannedDeparture ?? j.departure;
      final arr = j.arrival;
      final label = (dep != null && arr != null)
          ? '${_hm.format(dep)} – ${_hm.format(arr)}'
          : '–';
      final trains = j.legs
          .where((l) => !l.isWalking)
          .map((l) => l.line?.name.trim() ?? l.line?.productName ?? '?')
          .where((s) => s.isNotEmpty)
          .join(' + ');
      rows.add(BulkSplitRow(
        journey: j,
        label: label,
        duration: (dep != null && arr != null)
            ? arr.difference(dep)
            : Duration.zero,
        transfers: j.transfers < 0 ? 0 : j.transfers,
        trains: trains.isEmpty ? '?' : trains,
        directPrice: j.price?.amount,
        status: BulkRowStatus.pending,
      ));
    }

    state = BulkSplitState(
      running: true,
      total: rows.length,
      doneCount: 0,
      rows: rows,
      deutschlandTicket: settings.hasDeutschlandTicket,
    );

    for (var k = 0; k < rows.length; k++) {
      if (myGen != _gen) return;
      _patch(k, status: BulkRowStatus.running);

      final journey = rows[k].journey;
      final stops = splitStopsFromJourney(journey);
      final dep = journey.plannedDeparture ?? journey.departure;
      final date = dep?.toIso8601String().split('T').first ?? '';
      final direct = rows[k].directPrice ?? 0;

      TicketAnalysisResult? res;
      try {
        res = await engine.analyze(
          stops: stops,
          date: date,
          directPrice: direct,
          reisende: reisende,
          travellers: travellers,
          deutschlandTicket: settings.hasDeutschlandTicket,
          firstClass: settings.bahnCard.isFirstClass,
          apiDelayMs: settings.apiDelayMs,
          isCancelled: () => myGen != _gen,
        );
      } catch (_) {
        res = null;
      }
      if (myGen != _gen) return;

      _patch(
        k,
        directPrice: res?.directPrice,
        splitPrice: res?.splitPrice,
        result: res,
        status: res != null ? BulkRowStatus.done : BulkRowStatus.failed,
      );
      state = state.copyWith(doneCount: k + 1);
    }

    if (myGen != _gen) return;
    state = state.copyWith(running: false);
  }

  void _patch(int index,
      {double? directPrice,
      double? splitPrice,
      BulkRowStatus? status,
      TicketAnalysisResult? result}) {
    final rows = [...state.rows];
    if (index < 0 || index >= rows.length) return;
    rows[index] = rows[index].copyWith(
      directPrice: directPrice,
      splitPrice: splitPrice,
      status: status,
      result: result,
    );
    state = state.copyWith(rows: rows);
  }
}

final bulkSplitProvider =
    NotifierProvider<BulkSplitNotifier, BulkSplitState>(BulkSplitNotifier.new);
