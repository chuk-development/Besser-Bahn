// Records frame timings and memory of a running PROFILE build for N seconds,
// while something else (a person, or agent-device) drives the map.
//
//   dart run bin/map_bench.dart --ws ws://127.0.0.1:PORT/TOKEN=/ws \
//       --serial emulator-5554 --seconds 25 --label raster20
//
// Prints one human line and one JSON line. Frame data comes from the engine's
// timeline (UI thread "Frame", raster thread "GPURasterizer::Draw"), memory
// from the Dart isolate heap plus the process RSS (`ps`) — RSS is what the OS
// kills an app for, the Dart heap alone hides decoded images and GPU buffers.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:vm_service/vm_service_io.dart';

Future<void> main(List<String> args) async {
  String? arg(String name) {
    final i = args.indexOf('--$name');
    return i >= 0 && i + 1 < args.length ? args[i + 1] : null;
  }

  final ws = arg('ws')!;
  final serial = arg('serial') ?? 'emulator-5554';
  final seconds = int.parse(arg('seconds') ?? '20');
  final label = arg('label') ?? 'run';
  const pkg = 'dev.chuk.betterbahn';

  final vm = await vmServiceConnectUri(ws);
  final isolates = (await vm.getVM()).isolates ?? const [];
  final main = isolates.firstWhere(
    (i) => (i.name ?? '').contains('main'),
    orElse: () => isolates.first,
  );
  await vm.setVMTimelineFlags(
    args.contains('--dart') ? ['Embedder', 'GC', 'Dart'] : ['Embedder', 'GC'],
  );
  await vm.clearVMTimeline();

  var peakRss = 0;
  var peakHeap = 0;
  final rssSamples = <int>[];
  Future<int> rss() async {
    final r = await Process.run('adb', [
      '-s', serial, 'shell', 'ps', '-A', '-o', 'RSS,NAME',
    ]);
    for (final line in '${r.stdout}'.split('\n')) {
      final parts = line.trim().split(RegExp(r'\s+'));
      if (parts.length == 2 && parts[1] == pkg) return int.parse(parts[0]);
    }
    return 0;
  }

  final sw = Stopwatch()..start();
  while (sw.elapsed.inSeconds < seconds) {
    final r = await rss();
    rssSamples.add(r);
    peakRss = max(peakRss, r);
    try {
      final m = await vm.getMemoryUsage(main.id!);
      peakHeap = max(peakHeap, (m.heapUsage ?? 0) + (m.externalUsage ?? 0));
    } catch (_) {}
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }

  final tl = await vm.getVMTimeline();
  final events = (tl.traceEvents ?? const [])
      .map((e) => e.json ?? const <String, dynamic>{})
      .toList();
  List<double> durations(bool Function(String) match) {
    final out = <double>[];
    final open = <String, int>{};
    for (final e in events) {
      final name = '${e['name']}';
      if (!match(name)) continue;
      final ph = e['ph'];
      final key = '${e['tid']}|$name';
      if (ph == 'X') {
        out.add(((e['dur'] ?? 0) as num) / 1000);
      } else if (ph == 'B') {
        open[key] = (e['ts'] as num).toInt();
      } else if (ph == 'E' && open.containsKey(key)) {
        out.add(((e['ts'] as num).toInt() - open.remove(key)!) / 1000);
      }
    }
    return out..sort();
  }

  final build = durations((n) => n == 'Animator::BeginFrame');
  final raster = durations(
    (n) => n == 'GPURasterizer::Draw' || n == 'Rasterizer::DoDraw',
  );
  final gc = durations((n) => n.startsWith('Collect') || n == 'Scavenge');

  double pct(List<double> v, double p) =>
      v.isEmpty ? 0 : v[min(v.length - 1, (v.length * p).floor())];
  int over(List<double> v, double ms) => v.where((d) => d > ms).length;
  Map<String, num> stats(List<double> v) => {
    'n': v.length,
    'p50': double.parse(pct(v, .5).toStringAsFixed(1)),
    'p90': double.parse(pct(v, .9).toStringAsFixed(1)),
    'p99': double.parse(pct(v, .99).toStringAsFixed(1)),
    'max': double.parse((v.isEmpty ? 0 : v.last).toStringAsFixed(1)),
    'over16': over(v, 16.7),
  };

  final result = {
    'label': label,
    'seconds': seconds,
    'build': stats(build),
    'raster': stats(raster),
    'gcMs': double.parse(gc.fold<double>(0, (a, b) => a + b).toStringAsFixed(0)),
    'peakRssMB': (peakRss / 1024).round(),
    'endRssMB': ((rssSamples.isEmpty ? 0 : rssSamples.last) / 1024).round(),
    'peakDartHeapMB': (peakHeap / 1024 / 1024).round(),
  };
  final b = result['build'] as Map;
  final r = result['raster'] as Map;
  stdout.writeln(
    '$label: frames ${b['n']} | build p50 ${b['p50']} p90 ${b['p90']} '
    'p99 ${b['p99']} ms (>16ms: ${b['over16']}) | raster p50 ${r['p50']} '
    'p90 ${r['p90']} p99 ${r['p99']} ms (>16ms: ${r['over16']}) | '
    'RSS peak ${result['peakRssMB']} MB, end ${result['endRssMB']} MB | '
    'Dart heap peak ${result['peakDartHeapMB']} MB | GC ${result['gcMs']} ms',
  );
  stdout.writeln(jsonEncode(result));
  stdout.writeln('rss MB every 0.5s: ${rssSamples.map((r) => (r / 1024).round()).join(' ')}');
  if (args.contains('--top')) {
    final total = <String, double>{};
    final count = <String, int>{};
    final open = <String, int>{};
    for (final e in events) {
      final name = '${e['name']}';
      final key = '${e['tid']}|$name';
      double? d;
      if (e['ph'] == 'X') {
        d = ((e['dur'] ?? 0) as num) / 1000;
      } else if (e['ph'] == 'B') {
        open[key] = (e['ts'] as num).toInt();
      } else if (e['ph'] == 'E' && open.containsKey(key)) {
        d = ((e['ts'] as num).toInt() - open.remove(key)!) / 1000;
      }
      if (d == null) continue;
      total[name] = (total[name] ?? 0) + d;
      count[name] = (count[name] ?? 0) + 1;
    }
    final rows = total.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    for (final r in rows.take(30)) {
      stdout.writeln(
        '${r.value.toStringAsFixed(0).padLeft(8)} ms  n=${count[r.key]}  ${r.key}',
      );
    }
  }
  await vm.dispose();
}
