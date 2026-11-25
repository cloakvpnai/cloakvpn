# Lattice VPN: R8 / ProGuard rules for the minified release build.
#
# The release build sets isMinifyEnabled = true. R8 shrinks and renames code, which breaks
# anything found by name at runtime. The tunnel engine (liblatticetls.so) finds its Kotlin
# side by the full JNI symbol name, so every class that declares native methods keeps its
# name and the names of those methods. Everything else is free to be shrunk and renamed.
-keepclasseswithmembernames,includedescriptorclasses class * {
    native <methods>;
}
