# map_bench

Frame and memory benchmark for the app's maps. It connects to a running
**profile** build over the Dart VM service, records for N seconds while the map
is driven (by hand or by `agent-device` gestures), and prints frame times
(UI `Animator::BeginFrame`, raster `GPURasterizer::Draw`), the Dart heap and
the process RSS. RSS is what Android kills an app for.

```sh
# 1. profile build on the emulator (x86_64)
flutter build apk --profile --target-platform android-x64
adb -s emulator-5554 install -r build/app/outputs/flutter-apk/app-profile.apk
# 2. start with an endless timeline buffer, else the ring buffer drops frames
adb -s emulator-5554 shell am start -n dev.chuk.betterbahn/.MainActivity \
    --ez endless-trace-buffer true
# 3. VM service URI from logcat ("Dart VM service is listening on …"), forward it
adb -s emulator-5554 forward tcp:PORT tcp:PORT
# 4. record while you open and move the map
dart run bin/map_bench.dart --ws ws://127.0.0.1:PORT/TOKEN=/ws --seconds 40 \
    --label mymap [--dart --top]
```

`--dart --top` adds the Dart timeline stream and prints the 30 most expensive
event names (that is how the indoor-tile flood showed up: ~1800
`DecompressTexture`).

## Pitfalls

- The emulator must render on the host GPU: start it with `-gpu host`.
  The default (`-gpu auto`) can fall back to SwiftShader (CPU); raster times are
  then 10× too high and meaningless.
- Raster p50/p90 of ~8/17 ms on the emulator is the vsync wait, not map cost
  (same with the basemap removed). Compare p99, frame counts and RSS.
- A request to `/mob` without `X-Correlation-ID` gets a bare 405 from the edge.

## Results 2026-11-13 (perf_x64, RTX 3060 via `-gpu host`)

ICE 775 live route map (open, 20 gestures, then Back):

| | before | after fix |
|---|---|---|
| RSS peak on the map | 1365 MB | 438 MB |
| Dart heap peak | 349 MB | 102 MB |
| GC in 40 s | 11.2 s | 2.5 s |
| UI build p90 | 102 ms | 1.9 ms |
| RSS 25 s after Back | 1661 MB, growing | 409 MB, flat |

Cause: the bahnhof.de indoor floor plan layer (`minNativeZoom: 14`) was on the
route map at all times. flutter_map serves a low zoom by loading the native
z14 tiles for the whole viewport; on the first frame (default zoom 17) the
layer mounted, then the camera fit to the whole run (zoom ~7) and it queued
~1800 z14 tiles. Fix: `_IndoorLayer` in `lib/widgets/app_map.dart`.

Basemap variants on the Kiel Hbf station map (all raster p50 ≈ 8 ms = vsync):

| variant | raster p99 | RSS peak |
|---|---|---|
| raster, concurrency 4 (kept) | 46–48 ms | 348–363 MB |
| vector mode | 42–92 ms, 2–3× more slow frames | 381 MB |
| raster, `TileOffset.mapbox` | 41–46 ms | 359–374 MB |
| raster, concurrency 2 | 33–44 ms | 340–346 MB |
| no basemap at all | 29–30 ms | 327 MB |
