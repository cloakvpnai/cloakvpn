package ai.latticevpn.android.data

import android.content.Context
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.io.File

/**
 * The region the customer picked. A region only chooses which CNSA 2.0 gateway the
 * tunnel uses; nothing is provisioned on the server when it changes.
 */
class RegionStore private constructor(context: Context) {

    private val appContext = context.applicationContext
    private val prefs = appContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    private val _selectedRegion = MutableStateFlow(
        prefs.getString(KEY_SELECTED_REGION, null)?.let { LatticeRegion.byId(it) },
    )
    val selectedRegion: StateFlow<LatticeRegion?> = _selectedRegion.asStateFlow()

    fun select(region: LatticeRegion) {
        _selectedRegion.value = region
        prefs.edit().putString(KEY_SELECTED_REGION, region.id).apply()
    }

    /** Forget the region, at sign-out. */
    fun clear() {
        _selectedRegion.value = null
        prefs.edit().remove(KEY_SELECTED_REGION).apply()
    }

    /**
     * Earlier versions of the app connected with WireGuard and kept its keys and
     * configurations on the device. This version cannot use them, so they are erased.
     */
    fun eraseLegacyTunnelData() {
        val editor = prefs.edit()
        for (key in prefs.all.keys) {
            if (key.startsWith(LEGACY_CONFIG_PREFIX) || key in LEGACY_KEYS) editor.remove(key)
        }
        editor.apply()
        runCatching { File(appContext.filesDir, LEGACY_KEY_DIR).deleteRecursively() }
    }

    companion object {
        private const val PREFS_NAME = "lattice"
        private const val KEY_SELECTED_REGION = "selected_region_id"
        private const val LEGACY_CONFIG_PREFIX = "provisioned_config_"
        private val LEGACY_KEYS = setOf("wg_local_seckey_b64", "wg_local_pubkey_b64")
        private const val LEGACY_KEY_DIR = "keystore"

        @Volatile private var instance: RegionStore? = null

        fun get(context: Context): RegionStore =
            instance ?: synchronized(this) {
                instance ?: RegionStore(context).also { instance = it }
            }
    }
}
