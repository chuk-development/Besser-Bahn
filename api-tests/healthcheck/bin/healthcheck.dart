// Besser-Bahn API health check.
//
// Probes every upstream endpoint the app depends on and asserts the response
// still has the shape we parse. Runs on dart:io — the app's own TLS stack — so
// an Akamai fingerprint block that would not hit the app does not hit this
// either (and one that does, does).
//
//   cd api-tests/healthcheck
//   dart run bin/healthcheck.dart                  # everything
//   dart run bin/healthcheck.dart --only journey   # name contains "journey"
//   dart run bin/healthcheck.dart --group mob_board
//   dart run bin/healthcheck.dart --list
//
// Exit code 1 when a hard check fails. Soft checks only warn.

import 'dart:io';

import 'package:besser_bahn_healthcheck/checks.dart';

Future<void> main(List<String> args) async {
  final only = <String>[];
  final groups = <String>[];
  var list = false;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--only' when i + 1 < args.length:
        only.add(args[++i].toLowerCase());
      case '--group' when i + 1 < args.length:
        groups.add(args[++i]);
      case '--list':
        list = true;
      case '-h' || '--help':
        stdout.writeln(
          'usage: healthcheck [--only <text>]... [--group <name>]... [--list]',
        );
        exit(0);
      default:
        stderr.writeln('unknown argument: ${args[i]}');
        exit(2);
    }
  }

  var checks = allChecks();
  if (only.isNotEmpty) {
    checks = checks
        .where((c) => only.any((o) => c.name.toLowerCase().contains(o)))
        .toList();
  }
  if (groups.isNotEmpty) {
    checks = checks.where((c) => groups.contains(c.group)).toList();
  }
  if (list) {
    for (final c in checks) {
      stdout.writeln(
        '${c.group.padRight(13)} ${c.soft ? 'soft' : 'hard'}  '
        '${c.name}',
      );
    }
    exit(0);
  }

  final now = DateTime.now().toUtc();
  stdout.writeln(
    'Besser-Bahn API health check — ${ymd(now)} ${hhmm(now)} UTC '
    '(dart:io ${Platform.version.split(' ').first})\n',
  );
  var failures = 0;
  var skips = 0;
  for (final c in checks) {
    final sw = Stopwatch()..start();
    String line;
    try {
      final detail = await c.run();
      line = '  ✅ ${c.name.padRight(36)} ${_ms(sw)}  $detail';
    } on SkipCheck catch (e) {
      skips++;
      line = '  ⏭️ SKIP ${c.name.padRight(36)} ${_ms(sw)}  $e';
    } catch (e) {
      final tag = c.soft ? '⚠️ WARN' : '❌ FAIL';
      line =
          '  $tag ${c.name.padRight(36)} ${_ms(sw)}  '
          '${e.runtimeType}: $e';
      if (!c.soft) failures++;
    }
    stdout.writeln(line);
  }
  stdout.writeln();
  if (checks.isEmpty) {
    stdout.writeln('No check matched.');
    exit(2);
  }
  if (failures > 0) {
    stdout.writeln('$failures hard check(s) FAILED — an API likely changed.');
    exit(1);
  }
  stdout.writeln(
    'All hard checks passed.${skips > 0 ? ' ($skips skipped)' : ''}',
  );
  exit(0);
}

String _ms(Stopwatch sw) => '${sw.elapsedMilliseconds}ms'.padLeft(7);
