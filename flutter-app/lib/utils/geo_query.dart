/// A coordinate typed or pasted into a station field.
class GeoQuery {
  final double latitude;
  final double longitude;

  /// A name carried by the link (OSM/Google put the place name in the URL), so
  /// the picked stop can be shown as "near <place>" instead of bare numbers.
  final String? label;

  const GeoQuery(this.latitude, this.longitude, {this.label});

  @override
  String toString() =>
      'GeoQuery($latitude, $longitude${label != null ? ', $label' : ''})';

  @override
  bool operator ==(Object other) =>
      other is GeoQuery &&
      other.latitude == latitude &&
      other.longitude == longitude &&
      other.label == label;

  @override
  int get hashCode => Object.hash(latitude, longitude, label);
}

/// `-90..90` / `-180..180`. Anything outside isn't a coordinate — and this is
/// what stops a plain station name that happens to contain numbers, or a date
/// like "14.07, 2026", from being read as one.
bool _inRange(double lat, double lon) =>
    lat >= -90 && lat <= 90 && lon >= -180 && lon <= 180;

GeoQuery? _make(String? lat, String? lon, {String? label}) {
  final a = double.tryParse(lat ?? '');
  final b = double.tryParse(lon ?? '');
  if (a == null || b == null || !_inRange(a, b)) return null;
  return GeoQuery(a, b, label: label?.trim().isNotEmpty == true ? label : null);
}

/// Bare "53.439095, 14.538596" (comma, semicolon or whitespace separated).
/// Both parts must have a decimal point: "8 12" is a platform, not a place.
final _bare = RegExp(r'^\s*(-?\d{1,3}\.\d+)\s*[,;\s]\s*(-?\d{1,3}\.\d+)\s*$');

/// `geo:53.43,14.53` / `geo:53.43,14.53?z=17` (RFC 5870, what Android's share
/// sheet and Organic Maps emit).
final _geoUri = RegExp(r'^\s*geo:\s*(-?\d+\.?\d*)\s*,\s*(-?\d+\.?\d*)',
    caseSensitive: false);

/// Recognise a coordinate the user typed or pasted into a station field, or
/// null if it's an ordinary station name.
///
/// Accepts bare coordinates, `geo:` URIs, and shared links from OpenStreetMap,
/// Organic Maps, Murena/Magic Earth and Google Maps — the formats named in the
/// request (#11). Deliberately strict: this runs on every keystroke of a
/// station search, so a false positive would break ordinary searching. When in
/// doubt it returns null and the text goes to the normal station lookup.
GeoQuery? parseGeoQuery(String input) {
  final text = input.trim();
  if (text.isEmpty) return null;

  final bare = _bare.firstMatch(text);
  if (bare != null) return _make(bare.group(1), bare.group(2));

  final geo = _geoUri.firstMatch(text);
  if (geo != null) {
    // geo:0,0?q=lat,lon(label) — the share form that carries a real target in
    // `q` while the path is a placeholder.
    final q = Uri.tryParse(text)?.queryParameters['q'];
    if (q != null) {
      final m = RegExp(r'^(-?\d+\.?\d*),(-?\d+\.?\d*)(?:\s*\((.*)\))?$')
          .firstMatch(q.trim());
      final fromQ = _make(m?.group(1), m?.group(2), label: m?.group(3));
      if (fromQ != null) return fromQ;
    }
    return _make(geo.group(1), geo.group(2));
  }

  if (!text.contains('/')) return null;
  final uri = Uri.tryParse(text.startsWith('http') ? text : 'https://$text');
  if (uri == null || uri.host.isEmpty) return null;
  final qp = uri.queryParameters;

  // OpenStreetMap: ?mlat=&mlon= (the "share this marker" link), and the
  // #map=zoom/lat/lon fragment that the plain site URL carries.
  if (uri.host.contains('openstreetmap')) {
    final marker = _make(qp['mlat'], qp['mlon']);
    if (marker != null) return marker;
    final m = RegExp(r'map=\d+\.?\d*/(-?\d+\.?\d*)/(-?\d+\.?\d*)')
        .firstMatch(uri.fragment);
    if (m != null) return _make(m.group(1), m.group(2));
  }

  // Google Maps: /@lat,lon,17z (the map centre) and ?q=/?query= (a target).
  // Short links (maps.app.goo.gl) would need a network round-trip to expand,
  // so they're left to the normal search rather than silently doing one.
  if (uri.host.contains('google')) {
    final at = RegExp(r'/@(-?\d+\.?\d*),(-?\d+\.?\d*)').firstMatch(uri.path);
    if (at != null) return _make(at.group(1), at.group(2));
    for (final key in ['q', 'query', 'daddr']) {
      final v = qp[key];
      if (v == null) continue;
      final m = RegExp(r'^(-?\d+\.?\d*),\s*(-?\d+\.?\d*)$').firstMatch(v.trim());
      final hit = _make(m?.group(1), m?.group(2));
      if (hit != null) return hit;
    }
  }

  // Organic Maps / Murena / Magic Earth web links: omaps.app/…, ge0.me/…, and
  // the ?ll=lat,lon form they share.
  final ll = qp['ll'] ?? qp['ccp'];
  if (ll != null) {
    final m = RegExp(r'^(-?\d+\.?\d*),\s*(-?\d+\.?\d*)$').firstMatch(ll.trim());
    final hit = _make(m?.group(1), m?.group(2), label: qp['n']);
    if (hit != null) return hit;
  }

  return null;
}
