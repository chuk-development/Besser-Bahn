import 'package:live_update/live_update.dart';

import '../core/app_log.dart';
import '../core/extensions.dart';
import '../models/journey.dart';
import '../utils/live_trip_summary.dart';

/// The running trip as an Android 16 Live Update.
///
/// One notification, kept current while the trip runs: the bar is the journey
/// (a segment per leg, a marker at every change), the chip in the status bar is
/// the delay, and the system counts down to arrival by itself. On Android 17 the
/// same call also carries three metrics (delay / next stop / arrival), which the
/// platform renders in its own template — even on the always-on display.
///
/// Everything is best-effort. Where the device will not promote it — anything
/// below Android 16 QPR1, promotion switched off, an OEM that declines — [show]
/// returns false and the caller keeps to the ordinary notifications it already
/// posts. Nothing here ever throws into app code.
class LiveUpdateService {
  LiveUpdateService._();

  /// Cached so every poll does not cross the platform channel to ask again.
  static bool? _supported;

  /// The rider swiped it away — a dismissed Live Update must not come back, or
  /// the app is arguing with them once a minute.
  static bool _dismissed = false;

  static bool _listening = false;

  /// Which template Android 17 gets: [LiveUpdateStyle.auto] means the three
  /// metrics (and the always-on display, which no other template reaches),
  /// [LiveUpdateStyle.progress] keeps the journey bar there as well. Below
  /// Android 17 there is only the bar and this changes nothing.
  static LiveUpdateStyle preferredStyle = LiveUpdateStyle.auto;

  /// Chip content: false = minutes to the exit, true = stops to the exit (#76).
  /// Set from settings by the live tracker before each [show].
  static bool chipShowsStops = false;

  static Future<bool> isSupported() async {
    if (_supported != null) return _supported!;
    final s = await LiveUpdate.isSupported();
    _supported = s;
    AppLog.log(
      'live update: isSupported=$s '
      '(Android 16 QPR1+/17 nötig UND „Livemeldungen" für die App an)',
      tag: 'notify',
    );
    return s;
  }

  /// Force the next [isSupported] to re-ask the platform — the rider may have
  /// just flipped the "Livemeldungen" toggle, and the cached answer is stale.
  static void invalidateSupport() => _supported = null;

  /// Called when a new trip starts being tracked: a fresh trip may be shown
  /// again even if the previous one was dismissed.
  static void reset() => _dismissed = false;

  /// Post/refresh the Live Update for [journey] as of [now].
  ///
  /// Returns whether the system is really promoting it — false means "show the
  /// ordinary notification instead", not "something broke".
  static Future<bool> show(Journey journey, {DateTime? now}) async {
    if (_dismissed) {
      AppLog.log(
        'live update: übersprungen — vom Nutzer weggewischt (reset() '
        'setzt das bei neuer Reise zurück)',
        tag: 'notify',
      );
      return false;
    }
    if (!await isSupported()) {
      AppLog.log(
        'live update: NICHT gepostet — Gerät promotet es nicht '
        '(isSupported=false)',
        tag: 'notify',
      );
      return false;
    }
    _listenForDismissal();

    final at = now ?? DateTime.now();
    final trip = summariseTrip(journey, at);
    if (trip.isEmpty) {
      AppLog.log(
        'live update: NICHT gepostet — Reise ohne verwertbare '
        'Etappen/Zeiten (summariseTrip leer)',
        tag: 'notify',
      );
      return false;
    }
    // Over and done: the Live Update's whole promise is that it is current.
    if (trip.finishedAt(at)) {
      AppLog.log(
        'live update: NICHT gepostet — Reise laut Zeiten schon '
        'beendet, blende aus',
        tag: 'notify',
      );
      await hide();
      return false;
    }

    final line = trip.currentLeg?.line?.name ?? 'Reise';
    // Where this leg is headed — "ERX 83 → Lüneburg" reads like a train, not a
    // code, and tells the rider more than the line number alone.
    final dest = trip.currentLeg?.destination.name;
    final head = (dest != null && dest.isNotEmpty) ? '$line → $dest' : line;
    final delay = trip.delayMinutes;
    final title = trip.cancelled
        ? '$head · fällt aus'
        : delay > 0
        ? '$head · +$delay min'
        : head;
    final semantic = trip.cancelled
        ? LiveUpdateSemantic.danger
        : delay > 0
        ? LiveUpdateSemantic.caution
        : LiveUpdateSemantic.safe;

    try {
      final result = await LiveUpdate.post(
        title: title,
        // A train glyph, not the app logo — and a train-with-warning when the
        // trip is late or cancelled, so the status-bar icon itself carries the
        // state (#76).
        smallIcon: (trip.cancelled || trip.delayMinutes > 0)
            ? 'ic_stat_train_alert'
            : 'ic_stat_train',
        // Under the bar: the live pulse — the next stop with a countdown, which
        // is what tells the rider the train is moving and how far the next stop
        // is.
        text: _liveLine(trip, at),
        // The small header line: the rider's own milestones — where they get off
        // THIS train (with Gleis) and where the whole journey ends.
        subText: _journeyLine(trip, journey, at),
        // The tiny status-bar chip: delay when late, else minutes to next stop.
        chipText: _chip(trip, at),
        // Concise, purpose-built lines for Samsung's Now Bar so One UI doesn't
        // cram the dense shade content into the pill (cluttered/truncated, #76).
        nowbarPrimary: _nowbarPrimary(trip),
        nowbarSecondary: _nowbarSecondary(trip, at),
        chipExpandedText: _nowbarPrimary(trip),
        segments: [
          for (final s in trip.segments)
            LiveUpdateSegment(minutes: s.minutes, color: s.color),
        ],
        transferPoints: trip.transferPoints,
        progressMinutes: trip.progressMinutes,
        // The big countdown runs to the rider's OWN stop — where they get off
        // THIS train (their transfer, or the final exit) — not the far end of
        // the whole journey. "Wann ist mein Halt" is the question it answers.
        eta: _myStopArrival(trip) ?? trip.arrival,
        transferColor: LiveTripColors.transfer,
        titleSemantic: semantic,
        metrics: _metrics(trip, semantic, at),
        // The delay is what the rider is actually anxious about; when the system
        // has room for only one figure, that is the one.
        criticalMetric: 0,
        style: preferredStyle,
      );
      // post.promoted is the flag the system set at post time; isPromoted asks
      // the live notification back — they should agree, and a mismatch is worth
      // seeing in the log.
      final live = await LiveUpdate.isPromoted();
      AppLog.log(
        'live update [${result.style}]: "${AppLog.pii(title, 'Text')}" · ${trip.segments.length} '
        'Etappen, ${trip.transferPoints.length} Umstiege · '
        'post.promoted=${result.promoted}, system.promoted=$live',
        tag: 'notify',
      );
      return result.promoted;
    } catch (e) {
      AppLog.log('live update: POST fehlgeschlagen — $e', tag: 'notify');
      return false;
    }
  }

  /// The three figures the Android 17 template shows. Ignored below it, so the
  /// order matters only there: delay first, because it is the reason to look.
  static List<LiveUpdateMetric> _metrics(
    LiveTripSummary trip,
    int semantic,
    DateTime now,
  ) {
    final metrics = <LiveUpdateMetric>[
      LiveUpdateMetric.count(
        label: 'Verspätung',
        value: trip.delayMinutes,
        unit: 'min',
        semantic: semantic,
      ),
    ];
    // Three tiles, in the order they matter while riding: how late, what's the
    // next stop, and when do I get off this train (transfer or final arrival).
    final nextName = _nextStop(trip, now)?.stop.name;
    if (nextName != null && nextName.isNotEmpty) {
      metrics.add(
        LiveUpdateMetric.text(label: 'Nächster Halt', value: nextName),
      );
    }
    final legArr = _myStopArrival(trip);
    final finalArr = trip.arrival;
    final isTransfer =
        legArr != null && finalArr != null && legArr.isBefore(finalArr);
    if (legArr != null) {
      metrics.add(
        LiveUpdateMetric.clock(
          label: isTransfer ? 'Umstieg' : 'Ankunft',
          value: legArr,
        ),
      );
    }
    return metrics;
  }

  /// When the rider gets off the train they're on now — their transfer, or the
  /// final exit on the last leg. This, not the whole trip's end, is "mein Halt".
  static DateTime? _myStopArrival(LiveTripSummary trip) =>
      trip.currentLeg?.arrival ?? trip.currentLeg?.plannedArrival;

  /// The line under the bar — the one thing the rider actually reads. It changes
  /// with the situation: a countdown to departure on the platform, the real next
  /// stop with "in X Min" while running, "Gleich: …" on approach, and "Ankunft
  /// …" on the last stretch — each with the Gleis where DB gives us one.
  /// The line under the bar — the live pulse. On the platform it counts down to
  /// departure; running, it names the very next stop the train reaches (an
  /// intermediate one included — "how far is the next stop" is exactly what the
  /// rider watches) with a countdown; on the final approach it's the exit.
  static String _liveLine(LiveTripSummary trip, DateTime now) {
    final leg = trip.currentLeg;
    if (leg == null) return '';

    // Standing on the platform: the departure and its Gleis are what matter.
    final departure = leg.departure ?? leg.plannedDeparture;
    if (departure != null && now.isBefore(departure)) {
      final mins = departure.difference(now).inMinutes;
      final gleis = _platformSuffix(leg.departurePlatform);
      return mins <= 0
          ? 'Jetzt abfahrbereit · ${leg.origin.name}$gleis'
          : 'Abfahrt ${departure.hhmm} · in ${_mins(mins)}$gleis';
    }

    // Running: the next stop (intermediate or the exit — whichever comes first)
    // with a countdown, so the bar feels alive between stations.
    final next = _nextStop(trip, now);
    final where = next?.stop.name ?? leg.destination.name;
    final at = next?.arrival ?? next?.departure ?? _myStopArrival(trip);
    if (at == null) return 'Nächster Halt: $where';
    final mins = at.difference(now).inMinutes;
    if (mins <= 1) return 'Gleich: $where';
    return 'Nächster Halt: $where · in ${_mins(mins)} (${at.hhmm})';
  }

  /// The small header line: the rider's own milestones — where they leave THIS
  /// train (transfer or final, with Gleis) and, on a multi-leg trip, where the
  /// whole journey ends. The passing stations never appear here.
  static String _journeyLine(
    LiveTripSummary trip,
    Journey journey,
    DateTime now,
  ) {
    final leg = trip.currentLeg;
    final myArr = _myStopArrival(trip);
    final finalArr = trip.arrival;
    final isTransfer =
        myArr != null && finalArr != null && myArr.isBefore(finalArr);
    final parts = <String>[];
    if (leg != null && myArr != null) {
      final g = leg.arrivalPlatform;
      final gStr = (g != null && g.isNotEmpty) ? ' Gl $g' : '';
      parts.add(
        '${isTransfer ? 'Umstieg' : 'Ziel'} ${leg.destination.name} '
        '${myArr.hhmm}$gStr',
      );
    }
    if (isTransfer) {
      final rides = journey.legs.where((l) => !l.isWalking).toList();
      final last = rides.isNotEmpty ? rides.last : null;
      if (last != null) {
        parts.add('Ziel ${last.destination.name} ${finalArr.hhmm}');
      }
    }
    return parts.join(' · ');
  }

  static String _mins(int m) => '$m Min';

  static String _platformSuffix(String? gleis) =>
      (gleis != null && gleis.isNotEmpty) ? ' · Gleis $gleis' : '';

  /// The tiny status-bar chip (also the Samsung Now Bar's collapsed pill): the
  /// delay when late, otherwise the minutes to the rider's OWN exit — "Zeit bis
  /// zum Ausstieg", the number they actually care about (#76). Always something
  /// useful in ~4 characters.
  static String? _chip(LiveTripSummary trip, DateTime now) {
    if (trip.cancelled) return 'X';
    if (trip.delayMinutes > 0) return '+${trip.delayMinutes}';
    if (chipShowsStops) {
      final n = _stopsToExit(trip, now);
      return (n != null && n > 0) ? '$n Hlt' : null;
    }
    final at = _myStopArrival(trip);
    if (at == null) return null;
    final mins = at.difference(now).inMinutes;
    return (mins >= 0 && mins < 1000) ? "$mins'" : null;
  }

  /// Stops still ahead on the current leg, up to and including the exit — the
  /// "wie viele Stationen noch" a rider can also choose for the chip (#76).
  static int? _stopsToExit(LiveTripSummary trip, DateTime now) {
    final leg = trip.currentLeg;
    if (leg == null) return null;
    var n = 0;
    for (final s in leg.stopovers) {
      final at = s.arrival ?? s.departure;
      if (at != null && at.isAfter(now)) n++;
    }
    // Some legs carry no stopover list; fall back to "1 to go" while the leg is
    // still ahead of its arrival.
    final arr = _myStopArrival(trip);
    if (n == 0 && arr != null && arr.isAfter(now)) n = 1;
    return n;
  }

  /// Now Bar primary line — the one glance that matters: where the rider gets
  /// off this train and when. Short on purpose (the pill is tiny).
  static String _nowbarPrimary(LiveTripSummary trip) {
    final leg = trip.currentLeg;
    final dest = leg?.destination.name;
    if (dest == null || dest.isEmpty) return leg?.line?.name ?? 'Reise';
    final myArr = _myStopArrival(trip);
    final time = myArr != null ? ' ${myArr.hhmm}' : '';
    final flag = trip.cancelled
        ? ' · fällt aus'
        : (trip.delayMinutes > 0 ? ' +${trip.delayMinutes}' : '');
    return '→ $dest$time$flag';
  }

  /// Now Bar secondary line — the live pulse, kept to a handful of words: the
  /// next stop with a countdown, or the departure countdown on the platform.
  static String _nowbarSecondary(LiveTripSummary trip, DateTime now) {
    final leg = trip.currentLeg;
    final dep = leg?.departure ?? leg?.plannedDeparture;
    if (dep != null && now.isBefore(dep)) {
      final m = dep.difference(now).inMinutes;
      return m <= 0 ? 'Jetzt abfahrbereit' : 'Abfahrt in ${_mins(m)}';
    }
    final next = _nextStop(trip, now);
    if (next != null) {
      final at = next.arrival ?? next.departure;
      if (at == null) return next.stop.name;
      final m = at.difference(now).inMinutes;
      return m <= 1
          ? 'Gleich ${next.stop.name}'
          : '${next.stop.name} in ${_mins(m)}';
    }
    return '';
  }

  /// The first intermediate stop still ahead on the current leg (or null once
  /// they're all behind us) — used for the "next stop" countdown.
  static LegStopover? _nextStop(LiveTripSummary trip, DateTime now) {
    final leg = trip.currentLeg;
    if (leg == null) return null;
    for (final s in leg.stopovers) {
      if (s.cancelled) continue;
      final at = s.arrival ?? s.departure;
      if (at != null && at.isAfter(now)) return s;
    }
    return null;
  }

  static Future<void> hide() async {
    await LiveUpdate.cancel();
  }

  /// Stop showing it for this trip because the rider swiped it away.
  static void markDismissed() => _dismissed = true;

  /// The swipe arrives as a broadcast on the native side; without picking it up
  /// here the next poll posts the Live Update straight back.
  static void _listenForDismissal() {
    if (_listening) return;
    _listening = true;
    LiveUpdate.onDismissed = markDismissed;
  }
}
