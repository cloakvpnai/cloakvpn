# Lattice VPN — R8 / ProGuard rules for the minified release build.
#
# The release build sets isMinifyEnabled = true. R8 shrinks and obfuscates
# code, which breaks anything resolved by name at runtime — JNI symbol
# lookups and JNA's reflection-driven native binding. These rules keep
# exactly those surfaces. App (Kotlin/Compose) code is otherwise free to
# be shrunk and obfuscated normally.

# ---- JNA (net.java.dev.jna) -------------------------------------------
# JNA maps Java/Kotlin classes onto native memory by reflection. Its own
# classes, and every Structure / Callback / Library subclass, must keep
# their members or the native calls read garbage / crash.
-dontwarn java.awt.*
-keep class com.sun.jna.** { *; }
-keepclassmembers class * extends com.sun.jna.** { *; }
-keep class * implements com.sun.jna.** { *; }

# ---- uniffi / Rosenpass FFI bindings ----------------------------------
# uniffi/rosenpassffi/rosenpassffi.kt drives the native librosenpassffi.so
# through JNA — generated Structure classes are read by reflection and
# native callbacks are invoked by name. Keep the whole generated package.
-keep class uniffi.** { *; }
-keepclassmembers class uniffi.** { *; }

# ---- WireGuard JNI ----------------------------------------------------
# WgUapi declares `external fun wgSetConfig`, resolved by the custom
# libwg-go.so via the fully-qualified JNI symbol
# Java_ai_latticevpn_android_vpn_WgUapi_wgSetConfig. If R8 renamed the
# class or the method that symbol would no longer match and seamless PSK
# rotation would silently fall back / fail. Keep the class verbatim.
-keep class ai.latticevpn.android.vpn.WgUapi { *; }

# Keep every native-method declaration (and the classes that hold them)
# unrenamed — the general rule behind the WgUapi case above.
-keepclasseswithmembernames,includedescriptorclasses class * {
    native <methods>;
}

# wireguard-android ships its own consumer ProGuard rules; this only
# silences warnings about its optional / desktop-only dependencies.
-dontwarn com.wireguard.**
