import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/split_ticket.dart';
import '../services/db_api_service.dart';
import 'service_providers.dart';
import 'settings_provider.dart';

class SplitTicketState {
  final bool isLoading;
  final bool isCancelled;
  final TicketAnalysisResult? result;
  final SplitTicketProgress? progress;
  final String? error;
  final List<String> logs;

  const SplitTicketState({
    this.isLoading = false,
    this.isCancelled = false,
    this.result,
    this.progress,
    this.error,
    this.logs = const [],
  });

  SplitTicketState copyWith({
    bool? isLoading,
    bool? isCancelled,
    TicketAnalysisResult? result,
    SplitTicketProgress? progress,
    String? error,
    List<String>? logs,
  }) {
    return SplitTicketState(
      isLoading: isLoading ?? this.isLoading,
      isCancelled: isCancelled ?? this.isCancelled,
      result: result ?? this.result,
      progress: progress ?? this.progress,
      error: error,
      logs: logs ?? this.logs,
    );
  }
}

class SplitTicketNotifier extends Notifier<SplitTicketState> {
  @override
  SplitTicketState build() => const SplitTicketState();

  void _log(String msg) {
    final logs = [...state.logs, msg];
    if (logs.length > 100) logs.removeRange(0, logs.length - 100);
    state = state.copyWith(logs: logs);
  }

  void cancel() {
    state = state.copyWith(isCancelled: true);
  }

  Future<void> analyze({
    required List<Map<String, dynamic>> stops,
    required String date,
    required double directPrice,
  }) async {
    final settings = ref.read(settingsProvider);
    final dbApi = ref.read(dbApiServiceProvider);
    final vendo = ref.read(vendoServiceProvider);
    final travellers = DbApiService.createTravellerPayload(
      bahnCard: settings.bahnCard,
    );

    state = const SplitTicketState(isLoading: true);
    _log('Starte Split-Ticket-Analyse...');

    final stopwatch = Stopwatch()..start();
    final n = stops.length;
    final totalCombinations = (n * (n - 1)) ~/ 2;
    var processed = 0;

    // Collect segment prices
    final prices = <String, SegmentPrice>{};

    try {
      for (int i = 0; i < n; i++) {
        for (int j = i + 1; j < n; j++) {
          if (state.isCancelled) {
            _log('Analyse abgebrochen.');
            state = state.copyWith(isLoading: false);
            return;
          }

          final fromName = stops[i]['name'] as String;
          final toName = stops[j]['name'] as String;
          final key = '$i-$j';

          _log('Prüfe: $fromName → $toName');

          final dtIso = stops[i]['departure_iso'] as String? ?? date;

          // Primary: DB Vendo (has prices, not Akamai-blocked). Rate-limit a
          // little, then fall back to the legacy website price endpoint.
          await Future.delayed(Duration(milliseconds: settings.apiDelayMs));
          var price = await vendo.getSegmentPrice(
            from: stops[i]['id'] as String,
            to: stops[j]['id'] as String,
            dateTime: DateTime.tryParse(dtIso),
            deutschlandTicket: settings.hasDeutschlandTicket,
            firstClass: settings.bahnCard.isFirstClass,
            ermaessigung: settings.bahnCard.vendoErmaessigung,
          );
          if (price.price == double.infinity && !price.isDTicketCovered) {
            price = await dbApi.getSegmentPrice(
              fromId: stops[i]['id'] as String,
              toId: stops[j]['id'] as String,
              dateTime: dtIso,
              travellers: travellers,
              deutschlandTicket: settings.hasDeutschlandTicket,
              delayMs: settings.apiDelayMs,
            );
          }
          prices[key] = price;

          processed++;
          state = state.copyWith(
            progress: SplitTicketProgress(
              totalCombinations: totalCombinations,
              processedCombinations: processed,
              currentSegment: '$fromName → $toName',
            ),
          );
        }
      }

      // Dynamic programming: find cheapest split
      _log('Berechne optimale Aufteilung...');
      final dp = List<double>.filled(n, double.infinity);
      final parent = List<int>.filled(n, -1);
      dp[0] = 0;

      for (int j = 1; j < n; j++) {
        for (int i = 0; i < j; i++) {
          final key = '$i-$j';
          final segPrice = prices[key]?.price ?? double.infinity;
          if (dp[i] + segPrice < dp[j]) {
            dp[j] = dp[i] + segPrice;
            parent[j] = i;
          }
        }
      }

      // Reconstruct path
      final tickets = <SplitTicket>[];
      int current = n - 1;
      while (current > 0) {
        final prev = parent[current];
        if (prev < 0) break;
        final key = '$prev-$current';
        final segPrice = prices[key];
        tickets.insert(
          0,
          SplitTicket(
            from: stops[prev]['name'] as String,
            to: stops[current]['name'] as String,
            price: segPrice?.price ?? 0,
            fromId: stops[prev]['id'] as String,
            toId: stops[current]['id'] as String,
            departureIso: stops[prev]['departure_iso'] as String? ?? date,
            coveredByDeutschlandTicket: segPrice?.isDTicketCovered ?? false,
          ),
        );
        current = prev;
      }

      stopwatch.stop();
      final splitPrice = dp[n - 1];
      _log(
          'Fertig! Direktpreis: ${directPrice.toStringAsFixed(2)}€, Split: ${splitPrice.toStringAsFixed(2)}€');

      state = state.copyWith(
        isLoading: false,
        result: TicketAnalysisResult(
          directPrice: directPrice,
          splitPrice: splitPrice,
          tickets: tickets,
          combinationsChecked: totalCombinations,
          elapsed: stopwatch.elapsed,
        ),
      );
    } catch (e) {
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
