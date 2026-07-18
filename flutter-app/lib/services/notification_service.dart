import 'dart:typed_data';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../core/app_log.dart';
import '../theme/app_colors.dart';

/// Thin wrapper around flutter_local_notifications for the OS notifications the
/// app fires: one-shot results (e.g. "Split-Ticket-Analyse fertig"), live trip
/// alerts, and tz-aware *scheduled* trip reminders ("In 30 Min fährt dein
/// Zug"). Android + iOS only; every call is best-effort and never throws into
/// app code.
class NotificationService {
  NotificationService._();

  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _ready = false;
  static bool _exactAlarms = false;

  /// Lowest notification id used for *scheduled* trip reminders. Reserved range
  /// so [cancelReminders] can reconcile them without touching the one-shot
  /// notifications (Split-Ticket id 1001, live-alert ids 2000-2999).
  static const int reminderIdBase = 100000;

  /// Android notification channel for finished background analyses.
  static const _channel = AndroidNotificationChannel(
    'split_ticket',
    'Split-Ticket',
    description: 'Ergebnis der Split-Ticket-Analyse',
    importance: Importance.high,
  );

  /// Channel for trip reminders & live delay alerts ("Zug fährt in 30 Min",
  /// "Gleiswechsel", "Anschluss gefährdet"). Also carries the gentle "in 10 Min
  /// bist du da" arrival ping (heads-up + vibration, default sound).
  static const _tripChannel = AndroidNotificationChannel(
    'trip_alerts',
    'Reise-Hinweise',
    description: 'Abfahrts-Erinnerungen, Verspätungen und Umstiege',
    importance: Importance.high,
  );

  /// Loud "Ankunfts-Wecker" channel: the insistent ring shortly before arrival,
  /// for the user who's dozing and must not miss the stop. Max importance,
  /// alarm-stream audio (rings even when media is muted), and vibration. The
  /// channel only governs *whether* sound/vibration play — the looping
  /// (FLAG_INSISTENT) and "Stoppen" action live on the notification itself.
  static const _alarmChannel = AndroidNotificationChannel(
    'arrival_alarm',
    'Ankunfts-Wecker',
    description: 'Lauter Wecker kurz bevor du ankommst',
    importance: Importance.max,
    playSound: true,
    enableVibration: true,
    audioAttributesUsage: AudioAttributesUsage.alarm,
  );

  /// Android FLAG_INSISTENT (Notification.FLAG_INSISTENT) — loops the alarm
  /// sound until the notification is dismissed or "Stoppen" is tapped.
  static const int _flagInsistent = 4;

  /// Initialise the plugin, tz database and the Android channels. Call once at
  /// startup. Permission is requested lazily on first post.
  static Future<void> init() async {
    if (_ready) return;
    try {
      await _initTimeZone();
      // Not the launcher icon: Android draws the small icon as a silhouette,
      // keeping only its alpha channel. A fully opaque launcher PNG therefore
      // shows up as a featureless white blob. ic_stat_besserbahn is the app
      // mark as a transparent-background silhouette, which is what the status
      // bar expects.
      const android = AndroidInitializationSettings(
        '@drawable/ic_stat_besserbahn',
      );
      // iOS perms are requested on demand (below), not at init.
      const darwin = DarwinInitializationSettings(
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
      );
      await _plugin.initialize(
        settings: const InitializationSettings(
          android: android,
          iOS: darwin,
          macOS: darwin,
        ),
        // Tapping the alarm's "Stoppen" action already dismisses the
        // notification (cancelNotification: true → kills the insistent loop at
        // the OS level). The handler just records it; kept tiny because it can
        // also run when the app cold-starts from a notification tap.
        onDidReceiveNotificationResponse: _onResponse,
      );
      final android_ = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      await android_?.createNotificationChannel(_channel);
      await android_?.createNotificationChannel(_tripChannel);
      await android_?.createNotificationChannel(_alarmChannel);
      _ready = true;
    } catch (e) {
      AppLog.log('notification init failed ($e)', tag: 'notify');
    }
  }

  /// Load the tz database and pin the local zone to the device's. Reminders are
  /// scheduled as wall-clock times in this zone, so a DST change or travel
  /// keeps "30 min before 14:05" firing at the right instant. Falls back to
  /// Europe/Berlin (this is a German rail app) if the device zone is unknown.
  static Future<void> _initTimeZone() async {
    tzdata.initializeTimeZones();
    try {
      tz.setLocalLocation(
        tz.getLocation((await FlutterTimezone.getLocalTimezone()).identifier),
      );
    } catch (_) {
      try {
        tz.setLocalLocation(tz.getLocation('Europe/Berlin'));
      } catch (_) {
        /* leave UTC */
      }
    }
  }

  /// Ask the OS for permission to post notifications (Android 13+ / iOS). Safe
  /// to call repeatedly — the OS only prompts the first time.
  static Future<void> _ensurePermission() async {
    try {
      final android = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      if (android != null) {
        await android.requestNotificationsPermission();
        // Exact alarms (Android 13+): needed so "30 min vorher" lands on the
        // minute, not whenever Doze feels like it (inexact alarms get batched
        // and can be delivered HOURS late — e.g. only when the user unlocks).
        //
        // We declare USE_EXACT_ALARM in the manifest, which grants exact alarms
        // without the user toggling SCHEDULE_EXACT_ALARM. The capability check
        // is what matters — NOT requestExactAlarmsPermission(), which can return
        // false/null even when exact alarms are already allowed and would wrongly
        // pin us to inexact. So read the real capability; only fall back to the
        // settings prompt if it's genuinely unavailable.
        _exactAlarms = await android.canScheduleExactNotifications() ?? true;
        if (!_exactAlarms) {
          await android.requestExactAlarmsPermission();
          _exactAlarms =
              await android.canScheduleExactNotifications() ?? _exactAlarms;
        }
        return;
      }
      final ios = _plugin
          .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin
          >();
      await ios?.requestPermissions(alert: true, badge: true, sound: true);
    } catch (e) {
      AppLog.log('notification permission request failed ($e)', tag: 'notify');
    }
  }

  /// Fire the "analysis finished" notification. [title] is the route
  /// ("Kiel Hbf → Berlin Hbf"), [body] the result line.
  static Future<void> showSplitResult({
    required String title,
    required String body,
  }) async {
    if (!_ready) await init();
    await _ensurePermission();
    try {
      const details = NotificationDetails(
        android: AndroidNotificationDetails(
          'split_ticket',
          'Split-Ticket',
          channelDescription: 'Ergebnis der Split-Ticket-Analyse',
          color: AppColors.dbRed,
          importance: Importance.high,
          priority: Priority.high,
        ),
        iOS: DarwinNotificationDetails(),
        macOS: DarwinNotificationDetails(),
      );
      // Stable id → a fresh result replaces the previous notification rather
      // than stacking.
      await _plugin.show(
        id: 1001,
        title: title,
        body: body,
        notificationDetails: details,
      );
    } catch (e) {
      AppLog.log('notification show failed ($e)', tag: 'notify');
    }
  }

  // ---- Live trip alerts (fired immediately by the live-tracking controller) ----

  /// Post a live trip alert right now (delay jump, platform change, connection
  /// at risk). [id] in 2000-2999 so repeated alerts about the same thing
  /// replace rather than stack.
  static Future<void> showTripAlert({
    required int id,
    required String title,
    required String body,
  }) async {
    if (!_ready) await init();
    await _ensurePermission();
    try {
      await _plugin.show(
        id: 2000 + (id % 1000),
        title: title,
        body: body,
        notificationDetails: _tripDetails(),
      );
    } catch (e) {
      AppLog.log('trip alert show failed ($e)', tag: 'notify');
    }
  }

  /// Fire the loud "Ankunfts-Wecker" *right now* — the GPS exit-alarm path
  /// (live tracker noticed we're inside the destination's radius). Same
  /// insistent, stoppable alarm as the scheduled one. [id] in 3000-3999 so it
  /// replaces rather than stacks.
  static Future<void> showExitAlarm({
    required int id,
    required String title,
    required String body,
  }) async {
    if (!_ready) await init();
    await _ensurePermission();
    try {
      await _plugin.show(
        id: 3000 + (id % 1000),
        title: title,
        body: body,
        notificationDetails: _alarmDetails(),
      );
    } catch (e) {
      AppLog.log('exit alarm show failed ($e)', tag: 'notify');
    }
  }

  // ---- Scheduled trip reminders (planned offline from the timetable) ----

  /// Schedule a reminder to fire at [when] (a wall-clock instant in the local
  /// zone). [id] must be >= [reminderIdBase]. No-op if [when] is in the past.
  static Future<void> scheduleReminder({
    required int id,
    required DateTime when,
    required String title,
    required String body,
  }) async {
    if (!_ready) await init();
    final at = tz.TZDateTime.from(when, tz.local);
    if (!at.isAfter(tz.TZDateTime.now(tz.local))) return;
    try {
      await _plugin.zonedSchedule(
        id: id,
        title: title,
        body: body,
        scheduledDate: at,
        notificationDetails: _tripDetails(),
        androidScheduleMode: _exactAlarms
            ? AndroidScheduleMode.exactAllowWhileIdle
            : AndroidScheduleMode.inexactAllowWhileIdle,
      );
    } catch (e) {
      AppLog.log('schedule reminder failed ($e)', tag: 'notify');
    }
  }

  /// Schedule the loud "Ankunfts-Wecker" — same scheduling contract as
  /// [scheduleReminder] (wall-clock [when] in the local zone, [id] >=
  /// [reminderIdBase], no-op if in the past), but it rings insistently on the
  /// alarm audio stream and carries a "Stoppen" action so the user can silence
  /// it the moment it wakes them. Falls back to a heads-up notification if the
  /// OS denies the full-screen intent.
  static Future<void> scheduleAlarm({
    required int id,
    required DateTime when,
    required String title,
    required String body,
  }) async {
    if (!_ready) await init();
    final at = tz.TZDateTime.from(when, tz.local);
    if (!at.isAfter(tz.TZDateTime.now(tz.local))) return;
    try {
      await _plugin.zonedSchedule(
        id: id,
        title: title,
        body: body,
        scheduledDate: at,
        notificationDetails: _alarmDetails(),
        androidScheduleMode: _exactAlarms
            ? AndroidScheduleMode.exactAllowWhileIdle
            : AndroidScheduleMode.inexactAllowWhileIdle,
      );
    } catch (e) {
      AppLog.log('schedule alarm failed ($e)', tag: 'notify');
    }
  }

  /// Cancel every pending reminder in the reserved id range. The scheduler
  /// calls this before re-scheduling so removed/changed trips don't linger,
  /// even across process restarts (it reconciles the OS's pending list, not an
  /// in-memory set).
  static Future<void> cancelReminders() async {
    if (!_ready) await init();
    try {
      final pending = await _plugin.pendingNotificationRequests();
      for (final p in pending) {
        if (p.id >= reminderIdBase) await _plugin.cancel(id: p.id);
      }
    } catch (e) {
      AppLog.log('cancel reminders failed ($e)', tag: 'notify');
    }
  }

  /// Ask for notification + exact-alarm permission up front (e.g. when the user
  /// flips the reminders toggle on). Returns nothing; grant state is tracked
  /// internally for scheduling.
  static Future<void> requestPermissions() => _ensurePermission();

  static NotificationDetails _tripDetails() => const NotificationDetails(
    android: AndroidNotificationDetails(
      'trip_alerts',
      'Reise-Hinweise',
      channelDescription: 'Abfahrts-Erinnerungen, Verspätungen und Umstiege',
      color: AppColors.dbRed,
      importance: Importance.high,
      priority: Priority.high,
    ),
    iOS: DarwinNotificationDetails(),
    macOS: DarwinNotificationDetails(),
  );

  static NotificationDetails _alarmDetails() => NotificationDetails(
    android: AndroidNotificationDetails(
      'arrival_alarm',
      'Ankunfts-Wecker',
      channelDescription: 'Lauter Wecker kurz bevor du ankommst',
      color: AppColors.dbRed,
      importance: Importance.max,
      priority: Priority.max,
      category: AndroidNotificationCategory.alarm,
      // Show full-screen on the lock screen like an alarm clock. Degrades
      // to a heads-up banner if USE_FULL_SCREEN_INTENT isn't granted.
      fullScreenIntent: true,
      audioAttributesUsage: AudioAttributesUsage.alarm,
      // Loop the sound until the user dismisses it / taps Stoppen.
      additionalFlags: Int32List.fromList(<int>[_flagInsistent]),
      actions: const <AndroidNotificationAction>[
        AndroidNotificationAction(
          'stop_alarm',
          'Stoppen',
          cancelNotification: true,
        ),
      ],
    ),
    // iOS can't loop a notification sound; the critical alarm tone is the
    // closest equivalent for "wake me before my stop".
    iOS: const DarwinNotificationDetails(
      interruptionLevel: InterruptionLevel.critical,
    ),
    macOS: const DarwinNotificationDetails(
      interruptionLevel: InterruptionLevel.critical,
    ),
  );

  /// Notification (action) tap handler. Insistent alarms are stopped at the OS
  /// level by the action's `cancelNotification: true`; this only logs.
  static void _onResponse(NotificationResponse r) {
    if (r.actionId == 'stop_alarm') {
      AppLog.log('arrival alarm stopped by user', tag: 'notify');
    }
  }
}
