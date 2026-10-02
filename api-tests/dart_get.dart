// GET one URL with dart:io — the same TLS stack the app uses.
//
// Akamai in front of www.bahn.de fingerprints the TLS handshake. Since
// 2026-10 it blocks every Python/curl fingerprint (plain requests AND
// curl_cffi's Chrome/okhttp impersonation) with 403 OPS_BLOCKED, but it still
// lets dart:io through. healthcheck.py shells out to this script so the probe
// sees exactly what the app sees.
//
// Usage: dart run dart_get.dart <url> [<headers-json>]
// Output: line 1 = HTTP status, rest = response body.
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
  try {
    final req = await client.getUrl(Uri.parse(args[0]));
    if (args.length > 1) {
      final headers = jsonDecode(args[1]) as Map<String, dynamic>;
      headers.forEach((k, v) => req.headers.set(k, v.toString()));
    }
    final res = await req.close().timeout(const Duration(seconds: 30));
    final body = await res.transform(utf8.decoder).join();
    stdout.writeln(res.statusCode);
    stdout.write(body);
  } finally {
    client.close();
  }
}
