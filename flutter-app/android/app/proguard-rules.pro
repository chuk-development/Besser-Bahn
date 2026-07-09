# R8 full-mode keeps. The Flutter Gradle plugin already supplies the core
# Flutter/embedding keeps; these cover reflection-based bits in our plugins
# that full mode would otherwise strip.

# Flutter embedding (defensive — usually covered, but full mode is aggressive).
-keep class io.flutter.embedding.** { *; }
-keep class io.flutter.plugin.** { *; }

# Play Core (deferred components / split install) — referenced by Flutter but
# not always present; don't fail on missing symbols.
-dontwarn com.google.android.play.core.**

# geolocator / url_launcher / shared_preferences etc. use standard Android
# APIs and AndroidX — no extra keeps needed beyond AndroidX's consumer rules.

# Keep annotations (used by several AndroidX libs at runtime via reflection).
-keepattributes *Annotation*, Signature, InnerClasses, EnclosingMethod

# flutter_secure_storage (DB account + Träwelling token persistence) and its
# Tink crypto backend. Without these, R8 full-mode strips internal cipher /
# JNI bridge helpers and reads silently return null on the next cold start —
# which presents as "every launch I'm logged out again". Plugin package is
# com.it_nomads.fluttersecurestorage in 10.x.
-keep class com.it_nomads.fluttersecurestorage.** { *; }
-keep class com.google.crypto.tink.** { *; }
# Enums hold method-reference lambdas + a synthetic values() array R8 will
# happily mangle in full mode; valueOf() then throws on the next cold-start
# read of the previously-written cipher-algorithm marker.
-keepclassmembers enum com.it_nomads.fluttersecurestorage.** { *; }
-keepclassmembernames class com.it_nomads.fluttersecurestorage.ciphers.** { *; }
# Tink's keyset (de)serialisation uses Class.forName-style reflection into
# its proto + shaded-protobuf packages — already inside tink.**, but call out
# explicitly so a future minor that changes the package layout doesn't break.
-keep class com.google.crypto.tink.proto.** { *; }
-keep class com.google.crypto.tink.shaded.protobuf.** { *; }
# androidx.security.crypto (EncryptedSharedPreferences) is what the plugin's
# fallback path uses; missing keeps here would also crash a read silently.
-keep class androidx.security.crypto.** { *; }
-dontwarn androidx.security.crypto.**
-dontwarn com.it_nomads.fluttersecurestorage.**
-dontwarn com.google.crypto.tink.**
-dontwarn javax.annotation.**
