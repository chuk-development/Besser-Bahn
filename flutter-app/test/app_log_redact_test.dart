import 'package:flutter_test/flutter_test.dart';
import 'package:besser_bahn/core/app_log.dart';

void main() {
  const ts = '12:34:56.789  ';

  test('plain drops the markers, keeps the value', () {
    final line = '${ts}search ${AppLog.pii('Berlin Hbf')} → x';
    expect(AppLog.plain(line), '${ts}search Berlin Hbf → x');
  });

  test('same value gets the same placeholder, per kind', () {
    final out = AppLog.redact([
      '${ts}search ${AppLog.pii('Köln Hbf')} → ${AppLog.pii('Bonn Hbf')}',
      '${ts}map ${AppLog.pii('Köln Hbf')} · ${AppLog.pii('123', 'Kunde')}',
    ]);
    expect(out[0], '${ts}search ‹Halt 1› → ‹Halt 2›');
    expect(out[1], '${ts}map ‹Halt 1› · ‹Kunde 1›');
  });

  test('safety net catches unmarked ids, coordinates, lids, mails', () {
    final out = AppLog.redact([
      '${ts}failed: A=1@O=Berlin Hbf@X=13369549@Y=52525589@L=8011160@ end',
      '${ts}iris 8000105 at 52.525589,13.369549',
      '${ts}GET https://x.de/api?eva=8000105&t=1 HTTP 500',
      '${ts}mail max.m@example.org',
    ]);
    expect(out[0], '${ts}failed: ‹Ort› end');
    expect(out[1], '${ts}iris ‹Nr› at ‹Koord›,‹Koord›');
    expect(out[2], '${ts}GET https://x.de/api?‹…› HTTP 500');
    expect(out[3], '${ts}mail ‹E-Mail›');
  });

  test('timings, versions and HTTP codes stay readable', () {
    const line = '${ts}fahrplan HTTP 200 (48213B) 312ms · 2.5.0';
    expect(AppLog.redact([line]).single, line);
  });
}
