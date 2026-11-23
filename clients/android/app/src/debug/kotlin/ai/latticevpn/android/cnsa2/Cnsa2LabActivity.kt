package ai.latticevpn.android.cnsa2

import ai.latticevpn.android.vpn.cnsa2.Cnsa2IdentityStore
import android.app.Activity
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.Bundle
import android.util.Base64
import java.io.File
import org.strongswan.android.logic.CharonVpnService

/**
 * Debug builds only. Starts or stops the CNSA 2.0 lab tunnel from adb:
 *   am start -n <package>/ai.latticevpn.android.cnsa2.Cnsa2LabActivity --es config <base64 JSON>
 *   am start -n <package>/ai.latticevpn.android.cnsa2.Cnsa2LabActivity --ez stop true
 *   ... --es enroll <device name>          create the identity, write files/cnsa2/request.der
 *   ... --es certificate <base64 DER>      store the certificate issued for that request
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
        // enroll: create the identity on this device if needed and leave a
        // certificate request in files/cnsa2/request.der for the lab CA
        intent.getStringExtra("enroll")?.let { name ->
            val store = Cnsa2IdentityStore(this)
            File(filesDir, "cnsa2/request.der").writeBytes(store.certificateRequest(name))
            finish()
            return
        }
        intent.getStringExtra("certificate")?.let { b64 ->
            Cnsa2IdentityStore(this).storeCertificate(Base64.decode(b64, Base64.DEFAULT))
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
        val start = Intent(this, CharonVpnService::class.java)
            .setAction(CharonVpnService.ACTION_START)
            .putExtra(CharonVpnService.EXTRA_CONFIG, config)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(start) else startService(start)
        finish()
    }
}
