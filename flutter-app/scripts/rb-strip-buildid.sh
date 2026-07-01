#!/usr/bin/env bash
# Reproducible-build helper: strip the embedded build-id from the Dart JNI
# native lib (lib/*/libdartjni.so). Without this, each build embeds a unique
# build-id and the APK never reproduces (upstream Flutter issue).
#
# Run AFTER `flutter pub get` and BEFORE `flutter build`. IzzyOnDroid applies
# the equivalent step in their RB recipe; both sides must patch identically.
set -euo pipefail

PC="${PUB_CACHE:-$HOME/.pub-cache}"
patched=0
while IFS= read -r f; do
  if grep -q -- '--build-id=none' "$f"; then
    echo "already patched: $f"
  else
    sed -i -e 's/-Wl,/-Wl,--build-id=none,/' "$f"
    echo "patched: $f"
  fi
  patched=1
done < <(find "$PC/hosted" -path '*jni-*/src/CMakeLists.txt' 2>/dev/null)

if [ "$patched" = 0 ]; then
  echo "ERROR: no jni-*/src/CMakeLists.txt found under $PC/hosted" >&2
  echo "Did you run 'flutter pub get' first?" >&2
  exit 1
fi
