import '../core/app_log.dart';
import '../core/extensions.dart';
import '../models/journey.dart';
import '../models/library_models.dart';
import 'notification_service.dart';

/// Turns the user's saved upcoming trips into OS-scheduled local reminders —
/// the offline, infinitely-scaling half of the notification feature. Nothing
/// here touches the network: every time is read straight from the saved
/// timetable, so 100k users scheduling their own trips put zero load on DB and
/// no server in the loop. Live delay-aware alerts are a separate, foreground
/// concern (see the live-tracking controller).
///
/// For each trip we plan up to five kinds of pings:
///  - **Bereit machen** — [leadMinutes] before departure ("In 30 Min fährt …").
///  - **Boarding** — 5 min before departure, with the platform.
///  - **Umstieg** — 5 min before each connecting train leaves, with platform
///    and the real transfer gap.
///  - **Ankunfts-Wecker** — ~10 min before reaching the final destination
///    ("In 10 Minuten bist du da", vibration) and ~5 min before it. The 5-min
///    one becomes a loud, looping, stoppable alarm when [arrivalAlarmSound] is
///    on — so a dozing rider doesn't sleep past the stop.
///
/// [sync] is idempotent: it reconciles the OS's pending list, so calling it on
/// every library/settings change (or app start) converges without piling up.
class TripReminderScheduler {
  TripReminderScheduler._();

  /// iOS caps an app at 64 pending notifications; stay well under across all
  /// trips so the soonest ones never get dropped.
  static const int _maxReminders = 56;

  /// Lead times for the arrival wake-up, in minutes before the final arrival.
  static const int _arrivalNoticeMinutes = 10;
  static const int _arrivalAlarmMinutes = 5;

  static Future<void> sync(
    List<SavedJourney> upcoming, {
    required bool enabled,
    required int leadMinutes,
    required bool transferAlerts,
    required bool arrivalAlert,
    required bool arrivalAlarmSound,
  }) async {
    // Nothing to schedule from either half → clear everything and stop.
    if (!enabled && !arrivalAlert) {
      await NotificationService.cancelReminders();
      return;
    }

    final planned = plan(
      upcoming,
      leadMinutes: leadMinutes,
      departureReminders: enabled,
      transferAlerts: transferAlerts,
      arrivalAlert: arrivalAlert,
      arrivalAlarmSound: arrivalAlarmSound,
    );

    await NotificationService.cancelReminders();
    var id = NotificationService.reminderIdBase;
    for (final r in planned) {
      if (r.alarm) {
        await NotificationService.scheduleAlarm(
          id: id++,
          when: r.when,
          title: r.title,
          body: r.body,
        );
      } else {
        await NotificationService.scheduleReminder(
          id: id++,
          when: r.when,
          title: r.title,
          body: r.body,
        );
      }
    }
    AppLog.log('reminders synced (${planned.length} scheduled)', tag: 'notify');
  }

  /// The pings [sync] would schedule, in the order it schedules them: future
  /// only, soonest first, capped at [_maxReminders]. Split out from [sync] so
  /// the planning is testable without an OS notification plugin.
  ///
  /// Trips with `watched: false` contribute nothing. That flag is the per-trip
  /// "notify me about this one" switch (the bell in the Reiseplan); it used to
  /// gate only the live companion, so a trip the rider had switched off — or
  /// abandoned after missing it — kept firing its scheduled pings next to the
  /// replacement connection (#58). One flag, all channels.
  static List<TripReminder> plan(
    List<SavedJourney> upcoming, {
    required int leadMinutes,
    required bool departureReminders,
    required bool transferAlerts,
    required bool arrivalAlert,
    required bool arrivalAlarmSound,
    DateTime? now,
  }) {
    final current = now ?? DateTime.now();
    final reminders = <TripReminder>[];
    for (final saved in upcoming.where((j) => j.watched)) {
      reminders.addAll(_remindersFor(
        saved.journey,
        leadMinutes,
        departureReminders: departureReminders,
        transferAlerts: departureReminders && transferAlerts,
        arrivalAlert: arrivalAlert,
        arrivalAlarmSound: arrivalAlarmSound,
      ));
    }
    reminders
      ..removeWhere((r) => !r.when.isAfter(current))
      ..sort((a, b) => a.when.compareTo(b.when));
    return reminders.take(_maxReminders).toList();
  }

  static List<TripReminder> _remindersFor(
    Journey journey,
    int leadMinutes, {
    required bool departureReminders,
    required bool transferAlerts,
    required bool arrivalAlert,
    required bool arrivalAlarmSound,
  }) {
    final out = <TripReminder>[];
    final transit = journey.legs.where((l) => !l.isWalking).toList();
    if (transit.isEmpty) return out;

    if (departureReminders) {
      _addDepartureReminders(out, transit, leadMinutes, transferAlerts);
    }
    if (arrivalAlert) {
      _addArrivalReminders(out, transit, arrivalAlarmSound);
    }
    return out;
  }

  static void _addDepartureReminders(List<TripReminder> out,
      List<JourneyLeg> transit, int leadMinutes, bool transferAlerts) {
    final first = transit.first;
    final dep = first.plannedDeparture ?? first.departure;
    if (dep == null) return;
    final line = first.line?.displayName ?? 'Zug';
    final origin = first.origin.name;
    final plat = first.departurePlatform ?? first.plannedDeparturePlatform;

    // Bereit machen — lead minutes before departure.
    out.add(TripReminder(
      when: dep.subtract(Duration(minutes: leadMinutes)),
      title: 'In $leadMinutes Min: $line',
      body: 'ab $origin um ${dep.hhmm}'
          '${plat != null ? ' · Gleis $plat' : ''} — mach dich bereit.',
    ));

    // Boarding — 5 min before. Skipped if the lead is already ≤5 (would dupe).
    if (leadMinutes > 5) {
      out.add(TripReminder(
        when: dep.subtract(const Duration(minutes: 5)),
        title: 'Gleich Abfahrt: $line',
        body: '${dep.hhmm} ab $origin'
            '${plat != null ? ' · Gleis $plat' : ' — zum Gleis'}.',
      ));
    }

    // Umstiege — one ping shortly before each connecting train departs.
    if (transferAlerts) {
      for (var i = 1; i < transit.length; i++) {
        final next = transit[i];
        final nextDep = next.plannedDeparture ?? next.departure;
        if (nextDep == null) continue;
        final station = next.origin.name;
        final nextLine = next.line?.displayName ?? 'Anschluss';
        final nextPlat =
            next.departurePlatform ?? next.plannedDeparturePlatform;
        final prevArr = transit[i - 1].plannedArrival ?? transit[i - 1].arrival;
        final gap = prevArr != null
            ? nextDep.difference(prevArr).inMinutes
            : null;
        out.add(TripReminder(
          when: nextDep.subtract(const Duration(minutes: 5)),
          title: 'Umstieg in $station',
          body: '$nextLine um ${nextDep.hhmm}'
              '${nextPlat != null ? ' · Gleis $nextPlat' : ''}'
              '${gap != null ? ' · Übergang $gap Min' : ''}.',
        ));
      }
    }
  }

  /// Ankunfts-Wecker for the final destination: a gentle "in 10 Min bist du da"
  /// and a "gleich aussteigen" ping 5 min before — the latter as a loud,
  /// looping alarm when [alarmSound] is on. Times come from the saved arrival
  /// (live if we have it, else planned), so it's planned offline like every
  /// other reminder; the [sync] filter drops any leg that's already < 10 / < 5
  /// min out.
  static void _addArrivalReminders(
      List<TripReminder> out, List<JourneyLeg> transit, bool alarmSound) {
    final last = transit.last;
    final arr = last.arrival ?? last.plannedArrival;
    if (arr == null) return;
    final dest = last.destination.name;
    final plat = last.arrivalPlatform ?? last.plannedArrivalPlatform;

    out.add(TripReminder(
      when: arr.subtract(const Duration(minutes: _arrivalNoticeMinutes)),
      title: 'In $_arrivalNoticeMinutes Minuten bist du da',
      body: 'Ankunft $dest um ${arr.hhmm}'
          '${plat != null ? ' · Gleis $plat' : ''}.',
    ));

    out.add(TripReminder(
      when: arr.subtract(const Duration(minutes: _arrivalAlarmMinutes)),
      title: alarmSound
          ? 'Aufwachen — $dest in $_arrivalAlarmMinutes Min'
          : 'Gleich aussteigen: $dest',
      body: 'Ankunft um ${arr.hhmm}'
          '${plat != null ? ' · Gleis $plat' : ''} — mach dich fertig.',
      alarm: alarmSound,
    ));
  }
}

class TripReminder {
  final DateTime when;
  final String title;
  final String body;

  /// Schedule via the loud insistent "Ankunfts-Wecker" instead of a normal
  /// notification.
  final bool alarm;
  const TripReminder({
    required this.when,
    required this.title,
    required this.body,
    this.alarm = false,
  });
}
