import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:sensors_plus/sensors_plus.dart';

import '../../core/indoor_nav/indoor_route.dart';
import '../../core/indoor_nav/pdr.dart';
import '../../core/tile_cache.dart';
import '../../models/station_map.dart';

/// Walk a change like in a navigation app — without GPS.
///
/// The station's floors are drawn as tilted slabs stacked on top of each
/// other (2.5D), each with DB's own floor plan; the route runs across them
/// and drops through the stairs from one slab to the next. The dot moves
/// with the rider's steps and jumps a floor when the barometer says so
/// ([RouteTracker]). There is no 3D model of German stations — the stacked
/// floor plans are the closest thing, and they read the same way: "down
/// there, then over there".
class IndoorNavScreen extends StatefulWidget {
  final StationMap map;
  final IndoorRoute route;
  final String stationName;

  /// Walk the route by itself (preview / demo) instead of using sensors.
  final bool demo;

  /// DEV: write every frame of the demo as PNG into this directory, then
  /// quit — for a demo video (`tool/indoor_demo.sh`).
  final String? recordDir;

  /// Tiles for the floor plans. Null → the app's cached provider.
  final TileProvider Function()? tileProvider;

  const IndoorNavScreen({
    super.key,
    required this.map,
    required this.route,
    required this.stationName,
    this.demo = false,
    this.recordDir,
    this.tileProvider,
  });

  @override
  State<IndoorNavScreen> createState() => _IndoorNavScreenState();
}

class _IndoorNavScreenState extends State<IndoorNavScreen>
    with SingleTickerProviderStateMixin {
  late final RouteTracker _tracker = RouteTracker(widget.route);
  final _steps = StepDetector();
  final _floors = FloorChangeDetector();
  final _subs = <StreamSubscription<dynamic>>[];
  bool _hasBarometer = true;
  int _stepCount = 0;

  /// What is drawn: eases towards the tracker so a step is a glide.
  double _shown = 0;
  late final Ticker _ticker;
  Duration _last = Duration.zero;
  bool _demoRunning = false;

  final _captureKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
    if (widget.recordDir != null) {
      unawaited(_record(widget.recordDir!));
    } else if (widget.demo) {
      _demoRunning = true;
    } else {
      _startSensors();
    }
  }

  void _startSensors() {
    _subs.add(
      accelerometerEventStream(
        samplingPeriod: SensorInterval.gameInterval,
      ).listen((e) {
        final ms = DateTime.now().millisecondsSinceEpoch;
        if (_steps.add(ms, e.x, e.y, e.z)) {
          _stepCount++;
          _tracker.step(hasBarometer: _hasBarometer);
        }
      }, onError: (_) {}),
    );
    _subs.add(
      barometerEventStream().listen(
        (e) => _tracker.floorChanged(_floors.add(e.pressure)),
        onError: (_) => _hasBarometer = false,
        cancelOnError: true,
      ),
    );
  }

  /// Demo walking speed in route metres per second.
  double _demoSpeed() {
    final seg = widget
        .route
        .segments[widget.route.positionAt(_tracker.progress).segment];
    return seg.isFloorChange ? 2.2 : 1.4;
  }

  void _onTick(Duration now) {
    final dt = (now - _last).inMicroseconds / 1e6;
    _last = now;
    if (widget.recordDir != null) return; // the recorder drives time
    if (_demoRunning && dt > 0 && dt < 0.5) {
      _tracker.progress = math.min(
        _tracker.progress + _demoSpeed() * dt,
        widget.route.totalCost,
      );
      if (_tracker.arrived) _demoRunning = false;
    }
    final target = _tracker.progress;
    if ((target - _shown).abs() > 0.01) {
      setState(() => _shown += (target - _shown) * math.min(1, dt * 6));
    }
  }

  /// Fixed-step demo straight into PNG frames — no screen recorder needed,
  /// same pixels on every machine.
  Future<void> _record(String dir) async {
    const fps = 30;
    const speedUp = 6.0;
    await Directory(dir).create(recursive: true);
    // Let the floor-plan tiles arrive before the first frame.
    await Future<void>.delayed(const Duration(seconds: 8));
    var frame = 0;
    Future<void> grab() async {
      await SchedulerBinding.instance.endOfFrame;
      final b =
          _captureKey.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
      final img = await b.toImage(pixelRatio: 2);
      final png = await img.toByteData(format: ui.ImageByteFormat.png);
      await File(
        '$dir/f${(frame++).toString().padLeft(5, '0')}.png',
      ).writeAsBytes(png!.buffer.asUint8List());
    }

    for (var i = 0; i < fps; i++) {
      await grab(); // 1 s standing at the start
    }
    while (!_tracker.arrived) {
      _tracker.progress = math.min(
        _tracker.progress + _demoSpeed() * speedUp / fps,
        widget.route.totalCost,
      );
      setState(() => _shown = _tracker.progress);
      await grab();
    }
    setState(() => _shown = _tracker.progress = widget.route.totalCost);
    for (var i = 0; i < fps * 2; i++) {
      await grab();
    }
    debugPrint('RECORDED $frame frames to $dir');
    exit(0);
  }

  @override
  void dispose() {
    _ticker.dispose();
    for (final s in _subs) {
      s.cancel();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final route = widget.route;
    final pos = route.positionAt(_shown);
    final man = route.maneuverAt(_shown);
    final left = math.max(0, route.totalCost - _shown);
    final mins = (left / walkingSpeed / 60).ceil();
    final seg = route.segments[pos.segment];
    final atStairs =
        !widget.demo &&
        ((seg.isFloorChange) ||
            (pos.segment + 1 < route.segments.length &&
                route.segments[pos.segment + 1].isFloorChange &&
                route.costBefore(pos.segment + 1) - _tracker.progress < 1));
    final nextFloor = atStairs
        ? (seg.isFloorChange ? seg : route.segments[pos.segment + 1])
        : null;

    final body = Material(
      color: theme.colorScheme.surface,
      child: SafeArea(
        child: Column(
          children: [
            _ManeuverBanner(
              station: widget.stationName,
              text: _tracker.arrived && left < 1
                  ? 'Angekommen: ${route.nodes.last.label ?? 'Ziel'}'
                  : man.text,
              kind: _tracker.arrived && left < 1
                  ? IndoorManeuver.arrive
                  : man.kind,
              onClose: widget.recordDir != null
                  ? null
                  : () => Navigator.of(context).maybePop(),
            ),
            Expanded(
              child: LayoutBuilder(
                builder: (_, c) => _FloorStack(
                  map: widget.map,
                  route: route,
                  progress: _shown,
                  size: c.biggest,
                  tileProvider: widget.tileProvider,
                ),
              ),
            ),
            _BottomBar(
              leftMetres: left.toDouble(),
              minutes: mins,
              level: pos.level,
              status: widget.demo || widget.recordDir != null
                  ? 'Vorschau'
                  : 'Schritte $_stepCount · '
                        '${_hasBarometer ? 'Barometer an' : 'ohne Barometer'}',
              confirmLabel: nextFloor == null
                  ? null
                  : 'Bin auf ${levelLabel(nextFloor.to.level)}',
              onConfirm: nextFloor == null
                  ? null
                  : () => setState(
                      () => _tracker.progress = route.costBefore(
                        route.segments.indexOf(nextFloor) + 1,
                      ),
                    ),
              onBack: widget.recordDir != null
                  ? null
                  : () => setState(
                      () => _tracker.progress = math.max(
                        0,
                        _tracker.progress - 10,
                      ),
                    ),
              onForward: widget.recordDir != null
                  ? null
                  : () => setState(
                      () => _tracker.progress = math.min(
                        route.totalCost,
                        _tracker.progress + 10,
                      ),
                    ),
            ),
          ],
        ),
      ),
    );

    if (widget.recordDir != null) {
      // A phone-sized frame, whatever the desktop window is.
      return ColoredBox(
        color: Colors.black,
        child: FittedBox(
          child: RepaintBoundary(
            key: _captureKey,
            child: SizedBox(width: 400, height: 860, child: body),
          ),
        ),
      );
    }
    return Scaffold(body: body);
  }
}

class _ManeuverBanner extends StatelessWidget {
  final String station;
  final String text;
  final IndoorManeuver kind;
  final VoidCallback? onClose;

  const _ManeuverBanner({
    required this.station,
    required this.text,
    required this.kind,
    this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final icon = switch (kind) {
      IndoorManeuver.stairs => Icons.stairs_rounded,
      IndoorManeuver.escalator => Icons.escalator_rounded,
      IndoorManeuver.elevator => Icons.elevator_rounded,
      IndoorManeuver.arrive => Icons.flag_rounded,
      IndoorManeuver.walk => Icons.straight_rounded,
    };
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
      decoration: BoxDecoration(
        color: const Color(0xFF0B6E4F),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 44,
            height: 44,
            child: Icon(icon, size: 40, color: Colors.white),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  text,
                  style: theme.textTheme.titleLarge?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    height: 1.15,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Umstieg in $station',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: Colors.white70,
                  ),
                ),
              ],
            ),
          ),
          if (onClose != null)
            IconButton(
              onPressed: onClose,
              icon: const Icon(Icons.close_rounded, color: Colors.white),
            ),
        ],
      ),
    );
  }
}

class _BottomBar extends StatelessWidget {
  final double leftMetres;
  final int minutes;
  final String level;
  final String status;
  final String? confirmLabel;
  final VoidCallback? onConfirm;
  final VoidCallback? onBack;
  final VoidCallback? onForward;

  const _BottomBar({
    required this.leftMetres,
    required this.minutes,
    required this.level,
    required this.status,
    this.confirmLabel,
    this.onConfirm,
    this.onBack,
    this.onForward,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 10),
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${leftMetres.round()} m · $minutes min',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(status, style: theme.textTheme.bodySmall),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                height: 32,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Text(
                  levelLabel(level),
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: theme.colorScheme.onPrimaryContainer,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (onBack != null)
                IconButton(
                  tooltip: '10 m zurück',
                  onPressed: onBack,
                  icon: const Icon(Icons.remove_rounded),
                ),
              if (onForward != null)
                IconButton(
                  tooltip: '10 m weiter',
                  onPressed: onForward,
                  icon: const Icon(Icons.add_rounded),
                ),
            ],
          ),
          if (confirmLabel != null) ...[
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: onConfirm,
                child: Text(confirmLabel!),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The floors as tilted slabs, top floor on top, with the route across them.
class _FloorStack extends StatelessWidget {
  final StationMap map;
  final IndoorRoute route;
  final double progress;
  final Size size;
  final TileProvider Function()? tileProvider;

  const _FloorStack({
    required this.map,
    required this.route,
    required this.progress,
    required this.size,
    this.tileProvider,
  });

  static const _tilt = 0.95; // radians away from the viewer
  static const _persp = 0.0011;

  @override
  Widget build(BuildContext context) {
    final levels = route.usedLevels;
    final n = levels.length;
    final planeW = size.width - 40;
    final planeH = planeW * 0.82;
    final projH = planeH * math.cos(_tilt);
    final spacing = n <= 1
        ? 0.0
        : math.min((size.height - projH - 30) / (n - 1), projH + 70);
    final top = (size.height - (projH + spacing * (n - 1))) / 2;

    // One camera for every floor, rotated so the walk goes "into" the screen.
    final pts = route.nodes.map((e) => e.latLng).toList();
    final bearing = const Distance().bearing(pts.first, pts.last);
    final fitted =
        CameraFit.bounds(
          bounds: LatLngBounds.fromPoints(pts),
          padding: const EdgeInsets.all(40),
          maxZoom: 19,
        ).fit(
          MapCamera(
            crs: const Epsg3857(),
            center: pts.first,
            zoom: 17,
            rotation: -bearing,
            nonRotatedSize: Size(planeW, planeH),
          ),
        );

    Matrix4 raw(int i, double shift) {
      final cy = top + projH / 2 + i * spacing + shift;
      return Matrix4.translationValues(size.width / 2, cy, 0)
        ..multiply(Matrix4.identity()..setEntry(3, 2, _persp))
        ..multiply(Matrix4.rotationX(_tilt))
        ..multiply(Matrix4.translationValues(-planeW / 2, -planeH / 2, 0));
    }

    // Perspective makes the far edge stick out more than cos(tilt) says:
    // measure the real top and bottom and centre the whole stack on that.
    final realTop = MatrixUtils.transformPoint(raw(0, 0), Offset.zero).dy;
    final realBottom = MatrixUtils.transformPoint(
      raw(n - 1, 0),
      Offset(0, planeH),
    ).dy;
    final shift = (size.height - (realBottom - realTop)) / 2 - realTop;
    Matrix4 matrixFor(int i) => raw(i, shift);

    final pos = route.positionAt(progress);
    final current = pos.level;

    return Stack(
      clipBehavior: Clip.none,
      children: [
        for (var i = 0; i < n; i++)
          Positioned(
            left: 0,
            top: 0,
            child: Transform(
              transform: matrixFor(i),
              child: Opacity(
                opacity: levels[i] == current ? 1 : 0.45,
                child: SizedBox(
                  width: planeW,
                  height: planeH,
                  child: _FloorPlane(
                    level: levels[i],
                    route: route,
                    progress: progress,
                    camera: fitted,
                    tileProvider: tileProvider,
                    current: levels[i] == current,
                  ),
                ),
              ),
            ),
          ),
        Positioned.fill(
          child: IgnorePointer(
            child: CustomPaint(
              painter: _StackOverlay(
                route: route,
                levels: levels,
                progress: progress,
                camera: fitted,
                matrixFor: matrixFor,
                planeH: planeH,
                textStyle: Theme.of(context).textTheme.labelMedium!,
                scheme: Theme.of(context).colorScheme,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

const _routeColor = Color(0xFF1E88E5);
const _doneColor = Color(0xFF90A4AE);

class _FloorPlane extends StatelessWidget {
  final String level;
  final IndoorRoute route;
  final double progress;
  final MapCamera camera;
  final TileProvider Function()? tileProvider;
  final bool current;

  const _FloorPlane({
    required this.level,
    required this.route,
    required this.progress,
    required this.camera,
    required this.current,
    this.tileProvider,
  });

  @override
  Widget build(BuildContext context) {
    final done = <LatLng>[];
    final todo = <List<LatLng>>[];
    for (var i = 0; i < route.segments.length; i++) {
      final s = route.segments[i];
      if (s.isFloorChange || s.from.level != level) continue;
      final a = route.costBefore(i);
      final b = a + s.cost;
      if (progress >= b) {
        todo.add(const []);
        done
          ..add(s.from.latLng)
          ..add(s.to.latLng);
      } else if (progress <= a) {
        todo.add([s.from.latLng, s.to.latLng]);
      } else {
        final mid = route.positionAt(progress).latLng;
        done
          ..add(s.from.latLng)
          ..add(mid);
        todo.add([mid, s.to.latLng]);
      }
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFFF1F3F5),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: current ? _routeColor : const Color(0xFFB0BEC5),
          width: current ? 4 : 2,
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: FlutterMap(
          options: MapOptions(
            initialCenter: camera.center,
            initialZoom: camera.zoom,
            initialRotation: camera.rotation,
            backgroundColor: const Color(0xFFF1F3F5),
            interactionOptions: const InteractionOptions(
              flags: InteractiveFlag.none,
            ),
          ),
          children: [
            TileLayer(
              urlTemplate: StationMap.indoorTileUrl(level),
              tileDimension: 256,
              minNativeZoom: 14,
              maxNativeZoom: 18,
              maxZoom: 20,
              tileProvider:
                  tileProvider?.call() ??
                  TileCache.provider(
                    headers: {'Referer': 'https://www.bahnhof.de/'},
                  ),
              userAgentPackageName: 'de.chuk.besserebahn',
              errorTileCallback: (_, _, _) {},
            ),
            PolylineLayer(
              polylines: [
                for (var k = 0; k + 1 < done.length; k += 2)
                  Polyline(
                    points: [done[k], done[k + 1]],
                    strokeWidth: 7,
                    color: _doneColor,
                  ),
                for (final t in todo)
                  if (t.length == 2)
                    Polyline(
                      points: t,
                      strokeWidth: 9,
                      color: _routeColor,
                      borderStrokeWidth: 2,
                      borderColor: Colors.white,
                    ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Upright things on top of the slabs: the floor changes as vertical lines,
/// floor labels, start/target pins and the rider's dot.
class _StackOverlay extends CustomPainter {
  final IndoorRoute route;
  final List<String> levels;
  final double progress;
  final MapCamera camera;
  final Matrix4 Function(int) matrixFor;
  final double planeH;
  final TextStyle textStyle;
  final ColorScheme scheme;

  _StackOverlay({
    required this.route,
    required this.levels,
    required this.progress,
    required this.camera,
    required this.matrixFor,
    required this.planeH,
    required this.textStyle,
    required this.scheme,
  });

  Offset _at(LatLng p, String level) {
    final i = levels.indexOf(level);
    return MatrixUtils.transformPoint(
      matrixFor(i),
      camera.latLngToScreenOffset(p),
    );
  }

  void _label(Canvas c, Offset at, String text, Color bg, Color fg) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: textStyle.copyWith(color: fg, fontWeight: FontWeight.w700),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final r = RRect.fromRectAndRadius(
      Rect.fromCenter(center: at, width: tp.width + 16, height: tp.height + 8),
      const Radius.circular(10),
    );
    c.drawRRect(r, Paint()..color = bg);
    tp.paint(c, at - Offset(tp.width / 2, tp.height / 2));
  }

  void _pin(Canvas c, Offset base, String text, Color color) {
    final top = base - const Offset(0, 34);
    c.drawLine(
      base,
      top,
      Paint()
        ..color = color
        ..strokeWidth = 3,
    );
    c.drawCircle(base, 5, Paint()..color = color);
    _label(c, top - const Offset(0, 10), text, color, Colors.white);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final pos = route.positionAt(progress);

    // Floor labels at the left edge of each slab.
    for (var i = 0; i < levels.length; i++) {
      final at = MatrixUtils.transformPoint(
        matrixFor(i),
        Offset(0, planeH * 0.5),
      );
      final cur = levels[i] == pos.level;
      _label(
        canvas,
        at + const Offset(26, 0),
        levelShort(levels[i]),
        cur ? _routeColor : scheme.surfaceContainerHighest,
        cur ? Colors.white : scheme.onSurface,
      );
    }

    // Floor changes: the route drops straight down through the stairs.
    for (var i = 0; i < route.segments.length; i++) {
      final s = route.segments[i];
      if (!s.isFloorChange) continue;
      final a = _at(s.from.latLng, s.from.level);
      final b = _at(s.to.latLng, s.to.level);
      final start = route.costBefore(i);
      final passed = progress >= start + s.cost;
      final paint = Paint()
        ..color = passed ? _doneColor : _routeColor
        ..strokeWidth = 6
        ..strokeCap = StrokeCap.round;
      // Dashed: it is a way down, not a corridor.
      const dash = 9.0, gap = 6.0;
      final len = (b - a).distance;
      final dir = (b - a) / (len == 0 ? 1 : len);
      for (var d = 0.0; d < len; d += dash + gap) {
        canvas.drawLine(a + dir * d, a + dir * math.min(d + dash, len), paint);
      }
      canvas.drawCircle(a, 7, Paint()..color = paint.color);
      canvas.drawCircle(b, 7, Paint()..color = paint.color);
    }

    // Start and target.
    final first = route.nodes.first;
    final last = route.nodes.last;
    _pin(
      canvas,
      _at(first.latLng, first.level),
      first.label ?? 'Start',
      const Color(0xFFD32F2F),
    );
    _pin(
      canvas,
      _at(last.latLng, last.level),
      last.label ?? 'Ziel',
      const Color(0xFF2E7D32),
    );

    // The rider. During a floor change the dot rides down the dashed line.
    final seg = route.segments[pos.segment];
    final Offset me;
    if (seg.isFloorChange) {
      me = Offset.lerp(
        _at(seg.from.latLng, seg.from.level),
        _at(seg.to.latLng, seg.to.level),
        pos.t,
      )!;
    } else {
      me = _at(pos.latLng, pos.level);
    }
    canvas.drawCircle(
      me,
      20,
      Paint()..color = _routeColor.withValues(alpha: 0.22),
    );
    canvas.drawCircle(me, 11, Paint()..color = Colors.white);
    canvas.drawCircle(me, 8, Paint()..color = _routeColor);
  }

  @override
  bool shouldRepaint(_StackOverlay old) =>
      old.progress != progress || old.route != route;
}
