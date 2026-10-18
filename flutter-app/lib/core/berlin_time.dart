import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// German rail time, pinned for display.
///
/// DB sells and drives everything in Europe/Berlin wall-clock. Rendering DB
/// times in the device's zone shifted every departure when the app was used
/// abroad (#106): a phone one zone east showed the booked ICE an hour later
/// than the ticket. DB times are therefore formatted in Berlin — the same
/// fallback the notification scheduler already uses ("this is a German rail
/// app").
const String dbTimeZoneName = 'Europe/Berlin';

bool _tzInitialized = false;

tz.Location get _berlin {
  if (!_tzInitialized) {
    tzdata.initializeTimeZones();
    _tzInitialized = true;
  }
  return tz.getLocation(dbTimeZoneName);
}

/// The wall-clock [dt] would be printed with on a German departure board.
tz.TZDateTime toBerlin(DateTime dt) => tz.TZDateTime.from(dt, _berlin);

/// Parse a DB timestamp into a correct instant (device-local [DateTime], like
/// the rest of the app's parsed times — display converts via [toBerlin]).
///
/// Most vendo payloads carry an explicit offset ("2026-08-24T19:43:00+02:00")
/// and [DateTime.tryParse] handles them. Some fields (Gültigkeit,
/// Buchungsdatum, startDatum) arrive bare ("2026-08-24T19:43:00") and mean
/// German wall-clock — tryParse would read them in the device's zone, which is
/// exactly the #106 shift for a phone abroad. Bare values are therefore
/// interpreted as Europe/Berlin.
DateTime? parseDbTimestamp(String v) {
  final dt = DateTime.tryParse(v);
  if (dt == null) return null;
  final hasZone = RegExp(r'(?:Z|[+-]\d{2}:?\d{2})$').hasMatch(v);
  if (hasZone) return dt.toLocal();
  // Offset-less: the fields dt carries are the string's German wall-clock
  // (Dart kept them as local). Rebuild the instant in Berlin.
  final b = tz.TZDateTime(
    _berlin,
    dt.year,
    dt.month,
    dt.day,
    dt.hour,
    dt.minute,
    dt.second,
    dt.millisecond,
    dt.microsecond,
  );
  return DateTime.fromMillisecondsSinceEpoch(b.millisecondsSinceEpoch);
}
