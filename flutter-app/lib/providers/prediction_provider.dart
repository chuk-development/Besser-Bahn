import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/journey.dart';
import '../models/journey_prediction.dart';
import 'service_providers.dart';

/// Stable, value-equal key for a [Journey] so identical connections share one
/// prediction request (and don't refetch on rebuild/scroll).
class PredictionRequest {
  final Journey journey;
  final String key;

  PredictionRequest(this.journey) : key = _keyFor(journey);

  static String _keyFor(Journey j) {
    final dep = j.plannedDeparture?.toIso8601String() ?? '';
    final trains = j.legs
        .where((l) => !l.isWalking)
        .map((l) => l.line?.fahrtNr ?? '')
        .join('-');
    return '$dep|$trains|${j.legs.length}';
  }

  @override
  bool operator ==(Object other) =>
      other is PredictionRequest && other.key == key;

  @override
  int get hashCode => key.hashCode;
}

/// Lazily fetches the connection-reliability prediction for a journey. Cached
/// per [PredictionRequest] while any widget watches it (autoDispose).
final journeyPredictionProvider = FutureProvider.autoDispose
    .family<JourneyPrediction?, PredictionRequest>((ref, req) {
  return ref.read(predictionServiceProvider).predict(req.journey);
});
