package ai.latticevpn.android.vpn

import android.util.Log

/**
 * JNI bridge to the in-place config-update entry point in the project's
 * customized `libwg-go.so` (see `clients/android/libwg-go/`).
 *
 * The custom library adds one function, `wgSetConfig`, that applies a
 * WireGuard UAPI "set" payload to the running tunnel via `device.IpcSet`
 * — letting the Rosenpass loop rotate the preshared key with no tunnel
 * teardown.
 *
 * Graceful degradation: if the app was built **without** running
 * `Scripts/build-libwg-go-android.sh`, the stock wireguard-android
 * `libwg-go.so` (which has no `wgSetConfig` symbol) is in the APK
 * instead. In that case [setConfig] returns `false` rather than
 * crashing, and callers fall back to a non-seamless apply path. The app
 * works either way.
 */
object WgUapi {

    private const val TAG = "WgUapi"

    /** Return code from the native wgSetConfig on success. */
    private const val RESULT_OK = 0

    @Volatile
    private var libLoaded = false

    private fun ensureLibLoaded(): Boolean {
        if (libLoaded) return true
        // libwg-go is normally already loaded by GoBackend; this is a
        // belt-and-suspenders call and is a no-op if so.
        libLoaded = runCatching { System.loadLibrary("wg-go") }
            .onFailure { Log.e(TAG, "libwg-go failed to load: ${it.message}") }
            .isSuccess
        return libLoaded
    }

    /**
     * Apply a WireGuard UAPI "set" payload to the running tunnel in
     * place. [uapiSettings] must be `key=value` lines (no leading
     * `set=1`).
     *
     * Returns `true` on success. Returns `false` — never throws — when
     * the seamless path is unavailable: either `libwg-go.so` would not
     * load, or it is the stock library with no `wgSetConfig` symbol
     * (an [UnsatisfiedLinkError], caught here). Callers should fall
     * back to a non-seamless apply path on `false`.
     */
    fun setConfig(uapiSettings: String): Boolean {
        if (!ensureLibLoaded()) return false
        return try {
            val rc = wgSetConfig(uapiSettings)
            if (rc != RESULT_OK) Log.w(TAG, "wgSetConfig returned $rc")
            rc == RESULT_OK
        } catch (e: UnsatisfiedLinkError) {
            // The APK shipped the stock libwg-go.so (no wgSetConfig) —
            // the custom build step was not run.
            Log.w(TAG, "wgSetConfig unavailable; stock libwg-go.so in use? ${e.message}")
            false
        }
    }

    /**
     * Native binding — implemented by `Java_ai_latticevpn_android_vpn_WgUapi_wgSetConfig`
     * in the customized libwg-go's `jni-uapi.c`. Static, to match the
     * `jclass` form of that JNI wrapper.
     */
    @JvmStatic
    private external fun wgSetConfig(settings: String): Int
}
