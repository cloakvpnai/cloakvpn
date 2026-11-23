package ai.latticevpn.android.cnsa2

import android.app.Activity
import android.content.Intent
import android.net.VpnService
import android.os.Bundle
import android.util.Base64
import org.strongswan.android.logic.CharonVpnService

/**
 * Debug builds only. Starts or stops the CNSA 2.0 lab tunnel from adb:
 *   am start -n <package>/ai.latticevpn.android.cnsa2.Cnsa2LabActivity --es config <base64 JSON>
 *   am start -n <package>/ai.latticevpn.android.cnsa2.Cnsa2LabActivity --ez stop true
 */
class Cnsa2LabActivity : Activity() {
    private var config: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (intent.getBooleanExtra("stop", false)) {
            startService(Intent(this, CharonVpnService::class.java).setAction(CharonVpnService.ACTION_STOP))
            finish()
            return
        }
        config = intent.getStringExtra("config")?.let { String(Base64.decode(it, Base64.DEFAULT)) }
        if (config == null) {
            finish()
            return
        }
        val consent = VpnService.prepare(this)
        if (consent != null) startActivityForResult(consent, 1) else start()
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == 1 && resultCode == RESULT_OK) start() else finish()
    }

    private fun start() {
        startService(Intent(this, CharonVpnService::class.java)
            .setAction(CharonVpnService.ACTION_START)
            .putExtra(CharonVpnService.EXTRA_CONFIG, config))
        finish()
    }
}
