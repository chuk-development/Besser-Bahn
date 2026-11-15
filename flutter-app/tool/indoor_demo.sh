#!/usr/bin/env bash
# Record the 2.5D change navigation as an MP4.
#   tool/indoor_demo.sh [STATION] [FROM] [TO] [OUT.mp4]
set -euo pipefail
cd "$(dirname "$0")/.."
station=${1:-Hamburg-Harburg}; from=${2:-5}; to=${3:-11}
out=${4:-$PWD/../_scratch/indoor-demo/${station}-${from}-${to}.mp4}
frames=$(dirname "$out")/frames-$from-$to
rm -rf "$frames"; mkdir -p "$frames"
flutter run -d linux -t lib/dev/indoor_nav_demo.dart \
  --dart-define=STATION="$station" --dart-define=FROM="$from" \
  --dart-define=TO="$to" --dart-define=RECORD_DIR="$frames" </dev/null || true
ffmpeg -y -loglevel error -framerate 30 -i "$frames/f%05d.png" \
  -vf "scale=trunc(iw/2)*2:trunc(ih/2)*2" -c:v libx264 -pix_fmt yuv420p \
  -crf 20 -movflags +faststart "$out"
echo "$out"
