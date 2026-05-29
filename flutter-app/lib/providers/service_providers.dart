import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/hafas_service.dart';
import '../services/coach_sequence_service.dart';
import '../services/db_api_service.dart';
import '../services/location_service.dart';
import '../services/station_map_service.dart';
import '../services/vendo_service.dart';
import '../services/traewelling_service.dart';
import '../services/prediction_service.dart';

final hafasServiceProvider = Provider<HafasService>((ref) => HafasService());

final coachSequenceServiceProvider =
    Provider<CoachSequenceService>((ref) => CoachSequenceService());

final dbApiServiceProvider =
    Provider<DbApiService>((ref) => DbApiService());

final stationMapServiceProvider =
    Provider<StationMapService>((ref) => StationMapService());

final locationServiceProvider =
    Provider<LocationService>((ref) => LocationService());

final vendoServiceProvider = Provider<VendoService>((ref) => VendoService());

final traewellingServiceProvider =
    Provider<TraewellingService>((ref) => TraewellingService());

final predictionServiceProvider =
    Provider<PredictionService>((ref) => PredictionService());
