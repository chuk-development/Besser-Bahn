# Building Besser-Bahn (reproducible builds)

The release APKs are byte-for-byte reproducible **only** when the exact toolchain
below is used. The Android dex output depends on the JDK that runs R8, so the JDK
version matters as much as the Flutter version.

## Exact toolchain (release 2.0.0+1, tag `2.0.0+1`)

| Tool    | Version                                  |
|---------|------------------------------------------|
| Flutter | **3.41.9** (stable) — ships Dart 3.11.5  |
| JDK     | **21** (OpenJDK 21, e.g. Android Studio JBR 21.0.7) |
| AGP     | 8.9.1   (`android/settings.gradle`)      |
| Gradle  | 8.12    (`android/gradle/wrapper/...`)   |
| Kotlin  | 2.2.0   (`android/settings.gradle`)      |

R8 runs in full mode (`android.enableR8.fullMode=true`, committed in
`flutter-app/android/gradle.properties`).

> **JDK version is load-bearing.** Building with JDK 17 instead of JDK 21 makes
> R8 take different enum-switch optimization decisions (it keeps the
> `$SwitchMap` synthetic class instead of folding it to `Enum.ordinal()`), which
> changes `classes.dex` and breaks reproducibility. Use **JDK 21**.

## Build

```sh
cd flutter-app
flutter pub get
./scripts/rb-strip-buildid.sh                 # REQUIRED for RB — see below
flutter build apk --release --split-per-abi   # or appbundle, as released
```

The `rb-strip-buildid.sh` step must run on **both** the release build and the RB
rebuild, otherwise `lib/*/libdartjni.so` differs.

## Known cosmetic diff: `lib/*/libdartjni.so`

The Dart JNI native lib (`jni` pub package, pulled in transitively via
`flutter_secure_storage`) embeds a unique build-id — an upstream Flutter issue —
so every build produces a different `.so`. `scripts/rb-strip-buildid.sh` patches
the package's `CMakeLists.txt` in the pub cache to add `-Wl,--build-id=none`,
which makes the lib deterministic. It is idempotent and safe to re-run.

The equivalent IzzyOnDroid recipe step is:

```yaml
- flutter pub get
- sed -i -e 's/-Wl,/-Wl,--build-id=none,/' ${PUB_CACHE}/hosted/*/jni-*/src/CMakeLists.txt
```

## Per-release checklist

- Bump the exact `flutter:` version in `flutter-app/pubspec.yaml` to the Flutter
  version you actually build with (IzzyOnDroid's RB script parses that line).
- Update the table above and the GitHub release notes with the Flutter **and**
  JDK version used.
