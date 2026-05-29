import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import '../core/app_log.dart';
import '../models/journey.dart';
import '../models/journey_prediction.dart';

/// Client for our self-hosted bahnvorhersage model at `bahn.chuk.dev`.
///
/// The app fetches journeys itself (DB Vendo); this service only turns a
/// [Journey] into the model's columnar `TransferData` feature rows and POSTs
/// them to `/v1/journey-scores`. The backend never touches Deutsche Bahn — it
/// just runs the XGBoost model on the features we send.
class PredictionService {
  final http.Client _client = http.Client();
  static const _base = 'https://bahn.chuk.dev';

  /// Assumed minimal transfer time (minutes) when we have no station-specific
  /// figure. DB's defaults are typically 5–8 min at mid-size stations.
  static const _minTransferMinutes = 5;

  Future<JourneyPrediction?> predict(Journey journey) async {
    final payload = buildTransferData(journey);
    if (payload == null) {
      AppLog.log('skip: journey lacks coords/times for features', tag: 'predict');
      return null;
    }

    final url = '$_base/v1/journey-scores';
    try {
      final res = await _client
          .post(Uri.parse(url),
              headers: {'Content-Type': 'application/json'},
              body: utf8.encode(json.encode(payload)))
          .timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) {
        AppLog.log('HTTP ${res.statusCode}: ${_snippet(res.bodyBytes)}',
            tag: 'predict');
        return null;
      }
      final data =
          json.decode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      final p = JourneyPrediction.fromJson(data);
      AppLog.log('verb=${p.verbindungsscore} pünktl=${p.puenktlichkeit}',
          tag: 'predict');
      return p;
    } catch (e) {
      AppLog.log('failed ($e)', tag: 'predict');
      return null;
    }
  }

  // -- feature building -------------------------------------------------------

  /// Maps a [Journey] to the model's `TransferData` payload, or null if any
  /// transit leg is missing the coordinates/times the features need.
  ///
  /// Emits two rows per transit leg — its departure event then its arrival
  /// event — so rows alternate departure, arrival, … starting with a
  /// departure (the model's contract). A transfer between leg i and leg i+1
  /// carries the transfer times on BOTH the arrival row of leg i and the
  /// departure row of leg i+1.
  Map<String, dynamic>? buildTransferData(Journey journey) {
    final legs = journey.legs.where((l) => !l.isWalking).toList();
    if (legs.isEmpty) return null;

    final now = DateTime.now();
    final number = <int>[];
    final lat = <double>[];
    final lon = <double>[];
    final stopSeq = <int>[];
    final distance = <int>[];
    final dwellSched = <int?>[];
    final dwellProg = <int?>[];
    final bearing = <int>[];
    final delayProg = <int>[];
    final minuteOfDay = <int>[];
    final minutesTo = <int>[];
    final weekday = <int>[];
    final isRegional = <bool>[];
    final isArrival = <bool>[];
    final operator = <String>[];
    final category = <String>[];
    final line = <String>[];
    final pTransfer = <int?>[];
    final mTransfer = <int?>[];

    void addRow({
      required int num,
      required double la,
      required double lo,
      required int seq,
      required int dist,
      required int brg,
      required int delay,
      required DateTime time,
      required bool regional,
      required bool arr,
      required String op,
      required String cat,
      required String ln,
      int? ptt,
      int? mtt,
    }) {
      number.add(num);
      lat.add(la);
      lon.add(lo);
      stopSeq.add(seq);
      distance.add(dist);
      dwellSched.add(null);
      dwellProg.add(null);
      bearing.add(brg);
      delayProg.add(delay);
      minuteOfDay.add(time.hour * 60 + time.minute);
      minutesTo.add(time.difference(now).inMinutes);
      weekday.add(time.weekday - 1); // Mon=0 … Sun=6
      isRegional.add(regional);
      isArrival.add(arr);
      operator.add(op);
      category.add(cat);
      line.add(ln);
      pTransfer.add(ptt);
      mTransfer.add(mtt);
    }

    for (var i = 0; i < legs.length; i++) {
      final leg = legs[i];
      final o = leg.origin;
      final d = leg.destination;
      final dep = leg.departure ?? leg.plannedDeparture;
      final arr = leg.arrival ?? leg.plannedArrival;
      if (o.latitude == null ||
          o.longitude == null ||
          d.latitude == null ||
          d.longitude == null ||
          dep == null ||
          arr == null) {
        return null; // insufficient data — better no badge than a wrong one
      }

      // Transfer ONTO this leg (from the previous transit leg).
      int? depPtt, depMtt;
      if (i > 0) {
        final prevArr = legs[i - 1].arrival ?? legs[i - 1].plannedArrival;
        if (prevArr != null) {
          depPtt = dep.difference(prevArr).inMinutes;
          depMtt = _minTransferMinutes;
        }
      }
      // Transfer OFF this leg (to the next transit leg).
      int? arrPtt, arrMtt;
      if (i < legs.length - 1) {
        final nextDep = legs[i + 1].departure ?? legs[i + 1].plannedDeparture;
        if (nextDep != null) {
          arrPtt = nextDep.difference(arr).inMinutes;
          arrMtt = _minTransferMinutes;
        }
      }

      final brg = _bearing(o.latitude!, o.longitude!, d.latitude!, d.longitude!);
      final dist = _legDistanceMeters(leg);
      final regional = _isRegional(leg.line?.product);
      final cat = _category(leg);
      final ln = (leg.line?.name.isNotEmpty ?? false)
          ? leg.line!.name
          : (leg.line?.displayName ?? '');
      final op = leg.line?.operatorName ?? _operatorFor(leg.line?.product);
      final num =
          int.tryParse((leg.line?.fahrtNr ?? '').replaceAll(RegExp(r'[^0-9]'), ''))
              ?? 0;

      addRow(
        num: num, la: o.latitude!, lo: o.longitude!, seq: 0, dist: 0,
        brg: brg, delay: leg.departureDelayMinutes, time: dep,
        regional: regional, arr: false, op: op, cat: cat, ln: ln,
        ptt: depPtt, mtt: depMtt,
      );
      addRow(
        num: num, la: d.latitude!, lo: d.longitude!,
        seq: leg.stopovers.isNotEmpty ? leg.stopovers.length - 1 : 1,
        dist: dist, brg: brg, delay: leg.arrivalDelayMinutes, time: arr,
        regional: regional, arr: true, op: op, cat: cat, ln: ln,
        ptt: arrPtt, mtt: arrMtt,
      );
    }

    return {
      'number': number,
      'lat': lat,
      'lon': lon,
      'stop_sequence': stopSeq,
      'distance_traveled': distance,
      'dwell_time_schedule': dwellSched,
      'dwell_time_prognosed': dwellProg,
      'bearing': bearing,
      'delay_prognosed': delayProg,
      'minute_of_day': minuteOfDay,
      'minutes_to_prognosed_time': minutesTo,
      'weekday': weekday,
      'is_regional': isRegional,
      'is_arrival': isArrival,
      'operator': operator,
      'category': category,
      'line': line,
      'prognosed_transfer_time': pTransfer,
      'minimal_transfer_time': mTransfer,
    };
  }

  /// Cumulative great-circle distance over the leg's stops (meters).
  int _legDistanceMeters(JourneyLeg leg) {
    final pts = <List<double>>[];
    if (leg.stopovers.isNotEmpty) {
      for (final s in leg.stopovers) {
        if (s.stop.latitude != null && s.stop.longitude != null) {
          pts.add([s.stop.latitude!, s.stop.longitude!]);
        }
      }
    }
    if (pts.length < 2) {
      pts
        ..clear()
        ..add([leg.origin.latitude!, leg.origin.longitude!])
        ..add([leg.destination.latitude!, leg.destination.longitude!]);
    }
    var total = 0.0;
    for (var i = 1; i < pts.length; i++) {
      total += _haversine(pts[i - 1][0], pts[i - 1][1], pts[i][0], pts[i][1]);
    }
    return total.round();
  }

  static const _earthR = 6371000.0;

  double _haversine(double la1, double lo1, double la2, double lo2) {
    final dLa = _rad(la2 - la1);
    final dLo = _rad(lo2 - lo1);
    final a = sin(dLa / 2) * sin(dLa / 2) +
        cos(_rad(la1)) * cos(_rad(la2)) * sin(dLo / 2) * sin(dLo / 2);
    return _earthR * 2 * atan2(sqrt(a), sqrt(1 - a));
  }

  int _bearing(double la1, double lo1, double la2, double lo2) {
    final dLo = _rad(lo2 - lo1);
    final y = sin(dLo) * cos(_rad(la2));
    final x = cos(_rad(la1)) * sin(_rad(la2)) -
        sin(_rad(la1)) * cos(_rad(la2)) * cos(dLo);
    final brg = atan2(y, x) * 180 / pi;
    return ((brg + 360) % 360).round();
  }

  double _rad(double deg) => deg * pi / 180;

  bool _isRegional(String? product) => product == null
      ? true
      : const {'regional', 'suburban', 'subway', 'tram', 'bus', 'ferry'}
          .contains(product);

  String _operatorFor(String? product) {
    switch (product) {
      case 'nationalExpress':
      case 'national':
        return 'DB Fernverkehr AG';
      case 'regional':
      case 'suburban':
        return 'DB Regio AG';
      default:
        return '';
    }
  }

  String _category(JourneyLeg leg) {
    final pn = leg.line?.productName ?? '';
    if (pn.isNotEmpty) return pn;
    switch (leg.line?.product) {
      case 'nationalExpress':
        return 'ICE';
      case 'national':
        return 'IC';
      case 'regional':
        return 'RE';
      case 'suburban':
        return 'S';
      case 'subway':
        return 'U';
      case 'tram':
        return 'STR';
      case 'bus':
        return 'Bus';
      case 'ferry':
        return 'Schiff';
      default:
        return '';
    }
  }

  String _snippet(List<int> bytes) {
    try {
      final s = utf8.decode(bytes).replaceAll(RegExp(r'\s+'), ' ').trim();
      return s.length > 200 ? '${s.substring(0, 200)}…' : s;
    } catch (_) {
      return '<${bytes.length}B>';
    }
  }

  void dispose() => _client.close();
}
