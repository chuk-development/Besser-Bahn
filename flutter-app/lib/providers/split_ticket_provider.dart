import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/split_ticket.dart';
import '../services/db_api_service.dart';
import '../services/notification_service.dart';
import '../utils/split_engine.dart';
import 'service_providers.dart';
import 'settings_provider.dart';

class SplitTicketState {
  final bool isLoading;
  final bool isCancelled;
  final TicketAnalysisResult? result;
  final SplitTicketProgress? progress;
  final String? error;
  final List<String> logs;
  /// Origin → destination of the whole trip being analysed. Set at analyze()
  /// start so the screen can show "Reisdorf → Kaltenkirchen" the moment it
  /// opens, before any price query has returned.
  final String? routeLabel;

  const SplitTicketState({
    this.isLoading = false,
    this.isCancelled = false,
    this.result,
    this.progress,
    this.error,
    this.logs = const [],
    this.routeLabel,
  });

  SplitTicketState copyWith({
    bool? isLoading,
    bool? isCancelled,
    TicketAnalysisResult? result,
    SplitTicketProgress? progress,
    String? error,
    List<String>? logs,
    String? routeLabel,
  }) {
    return SplitTicketState(
      isLoading: isLoading ?? this.isLoading,
      isCancelled: isCancelled ?? this.isCancelled,
      result: result ?? this.result,
      progress: progress ?? this.progress,
      error: error,
      logs: logs ?? this.logs,
      routeLabel: routeLabel ?? this.routeLabel,
    );
  }
}

class SplitTicketNotifier extends Notifier<SplitTicketState> {
  @override
  SplitTicketState build() => const SplitTicketState();

  // Each analyze() run takes a generation number. A newer run bumps it, so any
  // older loop still in flight sees `_gen != myGen` and bails — repeated taps
  // (or a re-launch from another connection) can't interleave two analyses on
  // the same state. Fixes the double-search race.
  int _gen = 0;

  // Signature (stop ids + date) of the analysis currently in flight. Re-calling
  // analyze() with the SAME signature while it runs is a no-op, so returning to
  // the screen (which re-triggers analyze) keeps the background run going
  // instead of resetting it to 0.
  String? _runningSig;

  void _log(String msg) {
    final logs = [...state.logs, msg];
    if (logs.length > 100) logs.removeRange(0, logs.length - 100);
    state = state.copyWith(logs: logs);
  }

  void cancel() {
    _gen++; // stop the in-flight loop as well
    _runningSig = null;
    state = state.copyWith(isCancelled: true, isLoading: false);
  }

  /// Show an analysis that already ran elsewhere, without re-pricing anything.
  ///
  /// The bulk comparison analyses every departure and used to keep only the two
  /// prices, so its rows could show "Split −35,01 €" with no way to see which
  /// tickets that meant (#24). It hands the whole result over here instead.
  /// Supersedes any analysis in flight — the user asked for THIS one.
  void showResult(TicketAnalysisResult result, {String? routeLabel}) {
    _gen++;
    _runningSig = null;
    state = SplitTicketState(
      isLoading: false,
      result: result,
      routeLabel: routeLabel,
    );
  }

  Future<void> analyze({
    required List<Map<String, dynamic>> stops,
    required String date,
    required double directPrice,
    String? routeLabel,
    String? jobKey,
  }) async {
    // Prefer a STABLE key tied to the connection (origin/dest/departure). The
    // stop list is sampled from a cache that fills over time, so keying on it
    // would make re-tapping the same connection look like a new job → restart.
    final sig = jobKey ?? '${stops.map((s) => s['id']).join('|')}@$date';
    // Already running this exact analysis? Leave it running — re-entering the
    // screen must not restart it from zero. (A different route DOES supersede,
    // via the generation bump below.)
    if (state.isLoading && _runningSig == sig) return;

    final myGen = ++_gen;
    _runningSig = sig;
    final settings = ref.read(settingsProvider);
    final dbApi = ref.read(dbApiServiceProvider);
    final vendo = ref.read(vendoServiceProvider);
    final travellers = DbApiService.createTravellerPayload(
      bahnCard: settings.bahnCard,
    );
    // Price segments for the SAME party the search uses (age/type/BahnCard), so
    // youth/child fares match the DB app instead of always pricing an adult —
    // the root cause of split prices coming out higher than the real fare.
    final partyReisende = settings.searchParty.toReisendeJson();

    final n = stops.length;
    final totalCombinations = (n * (n - 1)) ~/ 2;

    final initialRouteLabel = routeLabel ??
        (stops.isNotEmpty
            ? '${stops.first['name']} → ${stops.last['name']}'
            : null);
    state = SplitTicketState(
      isLoading: true,
      routeLabel: initialRouteLabel,
      progress: SplitTicketProgress(
        totalCombinations: totalCombinations,
        processedCombinations: 0,
        currentSegment: 'Analyse wird vorbereitet…',
      ),
    );
    _log('Starte Split-Ticket-Analyse...');

    try {
      // Delegates to the shared engine rather than keeping a second copy of
      // the pricing loop + DP: the two had already drifted, and #13's fix has
      // to hold for the bulk comparison as much as for one connection.
      final result = await SplitEngine(vendo, dbApi).analyze(
        stops: stops,
        date: date,
        directPrice: directPrice,
        reisende: partyReisende,
        travellers: travellers,
        deutschlandTicket: settings.hasDeutschlandTicket,
        firstClass: settings.bahnCard.isFirstClass,
        apiDelayMs: settings.apiDelayMs,
        // A newer analyze() (or cancel()) supersedes this run.
        isCancelled: () => myGen != _gen || state.isCancelled,
        onProgress: (processed, total, segment) {
          if (myGen != _gen) return;
          _log('Prüfe: $segment');
          state = state.copyWith(
            progress: SplitTicketProgress(
              totalCombinations: total,
              processedCombinations: processed,
              currentSegment: segment,
            ),
          );
        },
      );

      if (myGen != _gen) return; // superseded while computing
      if (result == null) {
        // Cancelled mid-run, or fewer than two stops to split on.
        _log('Analyse abgebrochen.');
        _runningSig = null;
        state = state.copyWith(isLoading: false);
        return;
      }
      _runningSig = null;
      _log('Fertig! Direktpreis: ${directPrice.toStringAsFixed(2)}€, '
          'Split: ${result.splitPrice.toStringAsFixed(2)}€');
      state = state.copyWith(isLoading: false, result: result);

      // Notify the user the background analysis is done — they may have left
      // the screen while it ran.
      final route = routeLabel ??
          '${stops.first['name']} → ${stops.last['name']}';
      final body = result.hasSavings
          ? 'Split-Ticket ${result.savings.toStringAsFixed(2)} € günstiger '
              '(${result.savingsPercent.toStringAsFixed(0)}%)'
          : 'Kein günstigeres Split-Ticket – Direktpreis bleibt am besten.';
      NotificationService.showSplitResult(title: route, body: body);
    } catch (e) {
      if (myGen != _gen) return;
      _runningSig = null;
      state = state.copyWith(isLoading: false, error: 'Fehler: $e');
    }
  }

  void clear() {
    state = const SplitTicketState();
  }
}

final splitTicketProvider =
    NotifierProvider<SplitTicketNotifier, SplitTicketState>(
        SplitTicketNotifier.new);
