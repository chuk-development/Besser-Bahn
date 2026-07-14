import 'package:besser_bahn/utils/geo_query.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseGeoQuery — accepts (#11)', () {
    test('bare coordinates, the form from the request', () {
      final g = parseGeoQuery('53.439095, 14.538596')!;
      expect(g.latitude, closeTo(53.439095, 1e-9));
      expect(g.longitude, closeTo(14.538596, 1e-9));
    });

    test('bare coordinates without a space, and negative ones', () {
      expect(parseGeoQuery('53.439095,14.538596')!.latitude,
          closeTo(53.439095, 1e-9));
      final g = parseGeoQuery('-33.8688, 151.2093')!;
      expect(g.latitude, closeTo(-33.8688, 1e-9));
      expect(g.longitude, closeTo(151.2093, 1e-9));
    });

    test('geo: URI', () {
      final g = parseGeoQuery('geo:53.439095,14.538596')!;
      expect(g.latitude, closeTo(53.439095, 1e-9));
      expect(g.longitude, closeTo(14.538596, 1e-9));
    });

    test('geo: URI with a zoom parameter', () {
      expect(parseGeoQuery('geo:52.5251,13.3694?z=17')!.latitude,
          closeTo(52.5251, 1e-9));
    });

    test('geo:0,0?q=lat,lon(Label) — the Android share form', () {
      final g = parseGeoQuery('geo:0,0?q=52.5251,13.3694(Berlin Hbf)')!;
      expect(g.latitude, closeTo(52.5251, 1e-9));
      expect(g.longitude, closeTo(13.3694, 1e-9));
      expect(g.label, 'Berlin Hbf');
    });

    test('OpenStreetMap marker link', () {
      final g = parseGeoQuery(
          'https://www.openstreetmap.org/?mlat=53.4391&mlon=14.5386#map=17/53.4391/14.5386')!;
      expect(g.latitude, closeTo(53.4391, 1e-9));
      expect(g.longitude, closeTo(14.5386, 1e-9));
    });

    test('OpenStreetMap #map= fragment alone', () {
      final g = parseGeoQuery('https://www.openstreetmap.org/#map=17/53.4391/14.5386')!;
      expect(g.latitude, closeTo(53.4391, 1e-9));
      expect(g.longitude, closeTo(14.5386, 1e-9));
    });

    test('Google Maps /@lat,lon,zoom', () {
      final g = parseGeoQuery(
          'https://www.google.com/maps/@53.439095,14.538596,17z')!;
      expect(g.latitude, closeTo(53.439095, 1e-9));
    });

    test('Google Maps ?q=lat,lon', () {
      expect(parseGeoQuery('https://maps.google.com/?q=53.4391,14.5386')!.longitude,
          closeTo(14.5386, 1e-9));
    });

    test('Organic Maps / Murena ?ll= with a name', () {
      final g = parseGeoQuery('https://omaps.app/map?ll=53.4391,14.5386&n=Hafen')!;
      expect(g.latitude, closeTo(53.4391, 1e-9));
      expect(g.label, 'Hafen');
    });
  });

  group('parseGeoQuery — rejects (must not break station search)', () {
    test('ordinary station names', () {
      for (final s in [
        'Köln Hbf',
        'Berlin',
        'Frankfurt (Main) Hbf',
        'München-Pasing',
        'Halle (Saale) Hbf',
        'Bad Oeynhausen',
      ]) {
        expect(parseGeoQuery(s), isNull, reason: '"$s" is a station');
      }
    });

    test('station names containing digits', () {
      for (final s in ['S 1', 'Gleis 8 12', 'B 27', 'Bahnhof 2000']) {
        expect(parseGeoQuery(s), isNull, reason: '"$s" is not a coordinate');
      }
    });

    test('integers without decimals are not coordinates', () {
      expect(parseGeoQuery('8 12'), isNull);
      expect(parseGeoQuery('53, 14'), isNull);
    });

    test('out-of-range numbers are not coordinates', () {
      expect(parseGeoQuery('91.5, 14.5'), isNull, reason: 'lat > 90');
      expect(parseGeoQuery('53.5, 181.2'), isNull, reason: 'lon > 180');
    });

    test('empty and whitespace', () {
      expect(parseGeoQuery(''), isNull);
      expect(parseGeoQuery('   '), isNull);
    });

    test('a non-map URL', () {
      expect(parseGeoQuery('https://example.com/foo'), isNull);
    });

    test('a Google short link is left to the normal search (needs expanding)',
        () {
      expect(parseGeoQuery('https://maps.app.goo.gl/abc123'), isNull);
    });
  });
}
