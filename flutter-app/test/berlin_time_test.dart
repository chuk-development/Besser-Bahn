import 'package:besser_bahn/core/berlin_time.dart';
import 'package:besser_bahn/core/extensions.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// DB times must survive a phone abroad (#106): a device one zone east showed
/// every booked train an hour later than the ticket. Parsing keeps the
/// instant, display pins Europe/Berlin.
void main() {
  setUpAll(tzdata.initializeTimeZones);

  test(
    'parseDbTimestamp — offset strings keep their instant on any device',
    () {
      final t = parseDbTimestamp('2026-08-24T19:43:00+02:00');
      expect(t, isNotNull);
      // The instant, zone-independent: 17:43 UTC.
      expect(t!.toUtc().hour, 17);
      expect(t.toUtc().minute, 43);
    },
  );

  test(
    'parseDbTimestamp — bare wall-clock means German time, not the device zone',
    () {
      final t = parseDbTimestamp('2026-08-24T19:43:00');
      expect(t, isNotNull);
      expect(t!.toUtc().hour, 17); // CEST in August → UTC+2
      expect(t.toUtc().minute, 43);
    },
  );

  test('parseDbTimestamp — winter dates land in CET (UTC+1)', () {
    final t = parseDbTimestamp('2026-01-15T19:43:00');
    expect(t!.toUtc().hour, 18);
  });

  test('parseDbTimestamp — unparseable input stays null', () {
    expect(parseDbTimestamp('nix'), isNull);
  });

  test('hhmm renders the German wall-clock, not the runner zone', () {
    final withOffset = parseDbTimestamp('2026-08-24T19:43:00+02:00')!;
    final bare = parseDbTimestamp('2026-08-24T19:43:00')!;
    final utc = DateTime.utc(2026, 8, 24, 17, 43);
    expect(withOffset.hhmm, '19:43');
    expect(bare.hhmm, '19:43');
    expect(utc.hhmm, '19:43');
  });

  test('fullDateTime and dayMonthYear follow Berlin too', () {
    final t = DateTime.utc(2026, 8, 24, 22, 30); // 00:30 next day in Berlin
    expect(t.hhmm, '00:30');
    expect(t.dayMonthYear, '25.08.2026');
    expect(t.fullDateTime, '25.08.2026 00:30');
  });

  test('toBerlin bridges a UTC-flagged DateTime without shifting twice', () {
    final t = DateTime.utc(2026, 1, 15, 18, 5);
    expect(t.berlin.hour, 19);
    expect(t.berlin.timeZoneName, 'CET');
  });

  test('berlin getter survives an uninitialized tz database', () {
    // Extensions must work before the notification service ever ran.
    expect(DateTime.utc(2026, 8, 24, 17, 43).berlin.hhmm, '19:43');
    expect(tz.getLocation('Europe/Berlin').name, 'Europe/Berlin');
  });
}
