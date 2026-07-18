import 'dart:async';
import 'dart:convert';
import 'dart:ui' show DartPluginRegistrant;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:libre_location/libre_location.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/app_log.dart';
import '../core/exit_alarm_intelligence.dart';
import '../core/missed_connection.dart';
import '../models/journey.dart';
import '../models/library_models.dart';
import '../models/station.dart';
import '../models/trip.dart';
import 'notification_service.dart';

const _planKey = 'background_trip_plan_v1';
const _stateKey = 'background_trip_state_v1';
const _headlessChannel = MethodChannel('libre_location/headless');

/// Entry point started by libre_location after Android has removed the UI
/// process. The package persists this callback handle, while this dispatcher
/// installs the channel that receives each native location update.
@pragma('vm:entry-point')
void exitAlarmHeadlessDispatcher() {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  _headlessChannel.setMethodCallHandler((call) async {
    if (call.method == 'onLocationUpdate' && call.arguments is Map) {
      await BackgroundTripTracking.processPositionMap(
        Map<String, dynamic>.from(call.arguments as Map),
      );
    }
  });
  unawaited(_headlessChannel.invokeMethod<void>('initialized'));
}

/// libre_location requires a second top-level callback handle. Current Android
/// versions deliver through the dispatcher channel above; keeping this fully
/// functional also covers platforms/package versions that call it directly.
@pragma('vm:entry-point')
void exitAlarmHeadlessLocation(Map<String, dynamic> data) {
  unawaited(BackgroundTripTracking.processPositionMap(data));
}

class BackgroundJourneyPlan {
  final String journeyKey;
  final bool ringAlarm;
  final List<TrackedJourneyLeg> legs;
  final Map<String, MissedConnectionRescue> rescues;

  const BackgroundJourneyPlan({
    required this.journeyKey,
    required this.ringAlarm,
    required this.legs,
    this.rescues = const {},
  });

  Map<String, dynamic> toJson() => {
    'journeyKey': journeyKey,
    'ringAlarm': ringAlarm,
    'legs': legs.map((l) => l.toJson()).toList(),
    'rescues': rescues.map((key, value) => MapEntry(key, value.toJson())),
  };

  factory BackgroundJourneyPlan.fromJson(Map<String, dynamic> json) =>
      BackgroundJourneyPlan(
        journeyKey: json['journeyKey'] as String,
        ringAlarm: json['ringAlarm'] as bool? ?? false,
        legs: (json['legs'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(TrackedJourneyLeg.fromJson)
            .where((l) => l.route.length >= 2)
            .toList(growable: false),
        rescues:
            (json['rescues'] as Map?)?.map(
              (key, value) => MapEntry(
                key.toString(),
                MissedConnectionRescue.fromJson(
                  Map<String, dynamic>.from(value as Map),
                ),
              ),
            ) ??
            const {},
      );

  factory BackgroundJourneyPlan.fromJourney(
    SavedJourney saved, {
    required bool ringAlarm,
    Map<String, Trip> liveTrips = const {},
  }) {
    final legs = <TrackedJourneyLeg>[];
    final rescues = <String, MissedConnectionRescue>{};
    final finalDestination = saved.journey.destination;
    var index = 0;
    for (final leg in saved.journey.legs.where((l) => !l.isWalking)) {
      final legIndex = index++;
      final route = _timedRoute(leg, liveTrips[leg.tripId]);
      if (route.length < 2) continue;
      final id = '${leg.tripId ?? saved.key}:$legIndex';
      legs.add(
        TrackedJourneyLeg(
          id: id,
          lineName: leg.line?.displayName ?? 'Zug',
          destinationName: leg.destination.name,
          route: route,
        ),
      );
      if (finalDestination != null) {
        rescues[id] = MissedConnectionRescue(
          from: leg.origin,
          to: finalDestination,
          scheduledDeparture: route.first.scheduledAt,
          legIndex: legIndex,
          isConnection: legIndex > 0,
        );
      }
    }
    return BackgroundJourneyPlan(
      journeyKey: saved.key,
      ringAlarm: ringAlarm,
      legs: legs,
      rescues: rescues,
    );
  }

  static List<TimedRoutePoint> _timedRoute(JourneyLeg leg, Trip? liveTrip) {
    final points = <TimedRoutePoint>[];

    if (liveTrip != null) {
      final origin = liveTrip.stopovers.indexWhere(
        (s) => _sameStation(s.stop, leg.origin),
      );
      final destination = liveTrip.stopovers.lastIndexWhere(
        (s) => _sameStation(s.stop, leg.destination),
      );
      if (origin >= 0 && destination > origin) {
        for (final stop in liveTrip.stopovers.sublist(
          origin,
          destination + 1,
        )) {
          _addPoint(
            points,
            stop.stop,
            stop.plannedDeparture ??
                stop.plannedArrival ??
                _planned(
                  stop.departure ?? stop.arrival,
                  stop.departureDelay ?? stop.arrivalDelay,
                ),
            stop.departureDelay ?? stop.arrivalDelay ?? 0,
          );
        }
      }
    }

    if (points.length < 2) {
      points.clear();
      _addPoint(
        points,
        leg.origin,
        leg.plannedDeparture ??
            _planned(leg.departure, leg.departureDelay) ??
            leg.departure,
        leg.departureDelay ?? 0,
      );
      for (final stop in leg.stopovers) {
        _addPoint(
          points,
          stop.stop,
          _planned(
                stop.departure ?? stop.arrival,
                stop.departureDelay ?? stop.arrivalDelay,
              ) ??
              stop.departure ??
              stop.arrival,
          stop.departureDelay ?? stop.arrivalDelay ?? 0,
        );
      }
      _addPoint(
        points,
        leg.destination,
        leg.plannedArrival ??
            _planned(leg.arrival, leg.arrivalDelay) ??
            leg.arrival,
        leg.arrivalDelay ?? 0,
      );
    }

    // Remove duplicates and malformed/reversed times: the inference assumes a
    // monotonically increasing timetable.
    final clean = <TimedRoutePoint>[];
    for (final point in points) {
      if (clean.isNotEmpty &&
          !point.scheduledAt.isAfter(clean.last.scheduledAt)) {
        continue;
      }
      clean.add(point);
    }
    return clean;
  }

  static void _addPoint(
    List<TimedRoutePoint> out,
    Station station,
    DateTime? at,
    int delay,
  ) {
    if (!station.hasLocation || at == null) return;
    if (out.isNotEmpty &&
        out.last.latitude == station.latitude &&
        out.last.longitude == station.longitude) {
      return;
    }
    out.add(
      TimedRoutePoint(
        latitude: station.latitude!,
        longitude: station.longitude!,
        scheduledAt: at,
        reportedDelaySeconds: delay,
      ),
    );
  }

  static bool _sameStation(Station a, Station b) =>
      a.id.isNotEmpty && b.id.isNotEmpty ? a.id == b.id : a.name == b.name;

  static DateTime? _planned(DateTime? live, int? delaySeconds) =>
      live?.subtract(Duration(seconds: delaySeconds ?? 0));
}

/// Owns persistence and notification decisions for the background stream.
/// Network access is intentionally absent: the last live timetable snapshot is
/// enough to keep the exit alarm useful in a tunnel or after process death.
class BackgroundTripTracking {
  BackgroundTripTracking._();

  static const _intelligence = ExitAlarmIntelligence();

  static Future<void> registerHeadlessCallback() async {
    try {
      await LibreLocation.registerHeadlessDispatcher(
        exitAlarmHeadlessDispatcher,
        exitAlarmHeadlessLocation,
      );
    } catch (e) {
      AppLog.log('headless location registration failed ($e)', tag: 'live');
    }
  }

  static Future<void> writePlan(BackgroundJourneyPlan plan) async {
    final prefs = await SharedPreferences.getInstance();
    final oldJourney = _decode(prefs.getString(_planKey))?['journeyKey'];
    await prefs.setString(_planKey, jsonEncode(plan.toJson()));
    if (oldJourney != plan.journeyKey) await prefs.remove(_stateKey);
  }

  static Future<void> clearPlan() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_planKey);
    await prefs.remove(_stateKey);
  }

  static Future<void> processPosition(Position position) => processSample(
    JourneyPositionSample(
      latitude: position.latitude,
      longitude: position.longitude,
      accuracy: position.accuracy,
      speed: position.speed,
      timestamp: position.timestamp,
    ),
  );

  static Future<void> processPositionMap(Map<String, dynamic> data) async {
    try {
      await processPosition(Position.fromMap(data));
    } catch (e) {
      AppLog.log('headless location ignored ($e)', tag: 'live');
    }
  }

  /// Serialises processing WITHIN this isolate: rapid location callbacks must
  /// not interleave the load → mutate → persist of the tracking state, or two
  /// overlapping samples could clobber each other's evidence counters. (The UI
  /// and headless isolates can't overlap in practice — the headless one only
  /// runs after Android has torn the UI process down.)
  static Future<void> _queue = Future<void>.value();

  static Future<void> processSample(JourneyPositionSample sample) {
    final next = _queue.then((_) => _processSample(sample));
    _queue = next.catchError((_) {});
    return next;
  }

  /// Best-effort time gate: is [now] within the leg's scheduled window (plus its
  /// reported delay and generous slack)? Used to prefer the leg actually being
  /// ridden over a finished/overlapping one that's still geometrically near.
  static bool _timePlausible(TrackedJourneyLeg leg, DateTime now) {
    final delay = Duration(seconds: leg.route.first.reportedDelaySeconds);
    final from = leg.departure.subtract(const Duration(minutes: 15));
    final to = leg.arrival.add(delay).add(const Duration(minutes: 30));
    return !now.isBefore(from) && !now.isAfter(to);
  }

  static Future<void> _processSample(JourneyPositionSample sample) async {
    final prefs = await SharedPreferences.getInstance();
    // Headless and UI isolates have separate caches.
    await prefs.reload();
    final planJson = _decode(prefs.getString(_planKey));
    if (planJson == null) return;

    late final BackgroundJourneyPlan plan;
    try {
      plan = BackgroundJourneyPlan.fromJson(planJson);
    } catch (_) {
      return;
    }
    if (plan.legs.isEmpty) return;

    TrackedJourneyLeg? selected;
    JourneyPositionInference? inference;
    var selectedPlausible = false;
    final inferences = <String, JourneyPositionInference>{};
    for (final leg in plan.legs) {
      final candidate = _intelligence.evaluate(leg, sample);
      if (candidate == null) continue;
      inferences[leg.id] = candidate;
      // Distance alone lets a finished leg (still geometrically near its
      // corridor) or an overlapping/return leg outrank the one actually being
      // ridden — which would suppress the outgoing exit alert and confuse the
      // missed-connection logic after a transfer. Prefer a leg whose timetable
      // window contains now; only then break ties by distance.
      final plausible = _timePlausible(leg, sample.timestamp);
      final better = inference == null ||
          (plausible && !selectedPlausible) ||
          (plausible == selectedPlausible &&
              candidate.distanceToRouteMetres < inference.distanceToRouteMetres);
      if (better) {
        selected = leg;
        inference = candidate;
        selectedPlausible = plausible;
      }
    }
    if (selected == null || inference == null) return;

    final state = _TrackingState.fromJson(_decode(prefs.getString(_stateKey)));
    if (state.journeyKey != plan.journeyKey) {
      state.resetJourney(plan.journeyKey);
    }
    if (state.legId != selected.id) state.switchLeg(selected.id);

    // Only a genuinely newer fix advances the evidence counters. A duplicate or
    // replayed delivery (same/older timestamp) could otherwise satisfy the
    // 2-measurement thresholds on its own and fire a false delay/missed prompt.
    final isNewSample =
        state.lastSampleAt == null || sample.timestamp.isAfter(state.lastSampleAt!);

    MissedConnectionRescue? missedRescue;
    for (final leg in plan.legs) {
      final rescue = plan.rescues[leg.id];
      if (rescue == null || state.missedPromptedLegs.contains(leg.id)) continue;
      final effectiveDeparture = leg.departure.add(
        Duration(seconds: leg.route.first.reportedDelaySeconds),
      );
      final grace = rescue.isConnection
          ? const Duration(minutes: 3)
          : const Duration(minutes: 8);
      final inWindow =
          sample.timestamp.isAfter(effectiveDeparture.add(grace)) &&
          sample.timestamp.isBefore(
            effectiveDeparture.add(const Duration(minutes: 35)),
          );
      final outgoing = inferences[leg.id];
      final clearlyBoarded = outgoing != null && outgoing.progress >= .04;
      // For an Anschluss, still matching another leg after its departure is
      // the strong signal. For the first train, remaining at the route origin
      // is necessarily more ambiguous, hence the longer grace above. We ask
      // the rider; we never silently replace the journey.
      final plausible =
          inWindow &&
          !clearlyBoarded &&
          (rescue.isConnection ? selected.id != leg.id : selected.id == leg.id);
      if (isNewSample) {
        state.missedEvidence[leg.id] = plausible
            ? (state.missedEvidence[leg.id] ?? 0) + 1
            : 0;
      }
      if ((state.missedEvidence[leg.id] ?? 0) >= 2) {
        state.missedPromptedLegs.add(leg.id);
        missedRescue = rescue;
        break;
      }
    }

    final delayBucket = (inference.inferredDelayMinutes ~/ 5) * 5;
    final forward =
        state.lastProgress == null ||
        inference.progress >= state.lastProgress! - .015;
    if (isNewSample) {
      final qualifies = missedRescue == null &&
          !inference.shouldNotifyExit &&
          inference.progress >= .05 &&
          inference.progress <= .97 &&
          inference.suggestsUnreportedDelay &&
          forward;
      // Evidence must agree on the SAME delay bucket across measurements —
      // otherwise two unrelated blips at different magnitudes could combine.
      if (qualifies &&
          state.delayEvidence > 0 &&
          delayBucket == state.delayEvidenceBucket) {
        state.delayEvidence++;
      } else if (qualifies) {
        state.delayEvidence = 1;
        state.delayEvidenceBucket = delayBucket;
      } else {
        state.delayEvidence = 0;
        state.delayEvidenceBucket = 0;
      }
      state.lastProgress = inference.progress;
      state.lastSampleAt = sample.timestamp;
    }

    final notifyDelay =
        state.delayEvidence >= 2 &&
        delayBucket >= 5 &&
        delayBucket > (state.delayBuckets[selected.id] ?? 0);
    final notifyExit =
        inference.shouldNotifyExit &&
        !state.exitNotifiedLegs.contains(selected.id);
    if (notifyDelay) state.delayBuckets[selected.id] = delayBucket;
    if (notifyExit) state.exitNotifiedLegs.add(selected.id);

    // Persist before posting: if Android kills the headless isolate midway, a
    // restarted callback must not ring twice.
    await prefs.setString(_stateKey, jsonEncode(state.toJson()));

    if (missedRescue != null) {
      await NotificationService.showMissedConnectionPrompt(
        id: _stableId(
          'position-missed:${plan.journeyKey}:${missedRescue.legIndex}',
        ),
        rescue: missedRescue,
      );
      AppLog.log('position suggests ${missedRescue.label}', tag: 'live');
    }

    if (notifyDelay) {
      final known = inference.reportedDelayMinutes;
      final comparison = known <= 0
          ? 'DB meldet dafür bislang noch keine Verspätung.'
          : 'DB meldet bislang nur +$known Min.';
      await NotificationService.showTripAlert(
        id: _stableId('position-delay:${plan.journeyKey}:${selected.id}'),
        title: 'Mögliche Verspätung: etwa +$delayBucket Min',
        body: 'Deine Position passt nicht mehr zum Fahrplan. $comparison',
      );
      AppLog.log('position inferred +$delayBucket min', tag: 'live');
    }

    if (notifyExit) {
      final title = 'Gleich aussteigen: ${selected.destinationName}';
      final body = inference.inferredDelayMinutes >= 5
          ? 'Deine Position zeigt: Ziel in Kürze — trotz Verspätung.'
          : 'Deine Position zeigt: Du bist fast da. Sachen schnappen!';
      if (plan.ringAlarm) {
        await NotificationService.showExitAlarm(
          id: _stableId('position-exit:${plan.journeyKey}:${selected.id}'),
          title: title,
          body: body,
        );
      } else {
        await NotificationService.showTripAlert(
          id: _stableId('position-exit:${plan.journeyKey}:${selected.id}'),
          title: title,
          body: body,
        );
      }
      AppLog.log(
        'background exit alert near ${selected.destinationName}',
        tag: 'live',
      );
    }
  }

  static Map<String, dynamic>? _decode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  static int _stableId(String value) {
    var hash = 0x811c9dc5;
    for (final unit in value.codeUnits) {
      hash = ((hash ^ unit) * 0x01000193) & 0x7fffffff;
    }
    return hash;
  }
}

class _TrackingState {
  String? journeyKey;
  String? legId;
  double? lastProgress;
  DateTime? lastSampleAt;
  int delayEvidence;
  int delayEvidenceBucket;
  final Map<String, int> delayBuckets;
  final Set<String> exitNotifiedLegs;
  final Map<String, int> missedEvidence;
  final Set<String> missedPromptedLegs;

  _TrackingState({
    this.journeyKey,
    this.legId,
    this.lastProgress,
    this.lastSampleAt,
    this.delayEvidence = 0,
    this.delayEvidenceBucket = 0,
    Map<String, int>? delayBuckets,
    Set<String>? exitNotifiedLegs,
    Map<String, int>? missedEvidence,
    Set<String>? missedPromptedLegs,
  }) : delayBuckets = delayBuckets ?? <String, int>{},
       exitNotifiedLegs = exitNotifiedLegs ?? <String>{},
       missedEvidence = missedEvidence ?? <String, int>{},
       missedPromptedLegs = missedPromptedLegs ?? <String>{};

  factory _TrackingState.fromJson(Map<String, dynamic>? json) => _TrackingState(
    journeyKey: json?['journeyKey'] as String?,
    legId: json?['legId'] as String?,
    lastProgress: (json?['lastProgress'] as num?)?.toDouble(),
    lastSampleAt: json?['lastSampleAt'] is String
        ? DateTime.tryParse(json!['lastSampleAt'] as String)
        : null,
    delayEvidence: (json?['delayEvidence'] as num?)?.toInt() ?? 0,
    delayEvidenceBucket: (json?['delayEvidenceBucket'] as num?)?.toInt() ?? 0,
    delayBuckets:
        (json?['delayBuckets'] as Map?)?.map(
          (key, value) => MapEntry(key.toString(), (value as num).toInt()),
        ) ??
        <String, int>{},
    exitNotifiedLegs:
        (json?['exitNotifiedLegs'] as List<dynamic>? ?? const <dynamic>[])
            .whereType<String>()
            .toSet(),
    missedEvidence:
        (json?['missedEvidence'] as Map?)?.map(
          (key, value) => MapEntry(key.toString(), (value as num).toInt()),
        ) ??
        <String, int>{},
    missedPromptedLegs:
        (json?['missedPromptedLegs'] as List<dynamic>? ?? const <dynamic>[])
            .whereType<String>()
            .toSet(),
  );

  void resetJourney(String journey) {
    journeyKey = journey;
    legId = null;
    lastProgress = null;
    lastSampleAt = null;
    delayEvidence = 0;
    delayEvidenceBucket = 0;
    delayBuckets.clear();
    exitNotifiedLegs.clear();
    missedEvidence.clear();
    missedPromptedLegs.clear();
  }

  void switchLeg(String leg) {
    legId = leg;
    lastProgress = null;
    delayEvidence = 0;
    delayEvidenceBucket = 0;
  }

  Map<String, dynamic> toJson() => {
    'journeyKey': journeyKey,
    'legId': legId,
    'lastProgress': lastProgress,
    'lastSampleAt': lastSampleAt?.toIso8601String(),
    'delayEvidence': delayEvidence,
    'delayEvidenceBucket': delayEvidenceBucket,
    'delayBuckets': delayBuckets,
    'exitNotifiedLegs': exitNotifiedLegs.toList(),
    'missedEvidence': missedEvidence,
    'missedPromptedLegs': missedPromptedLegs.toList(),
  };
}
