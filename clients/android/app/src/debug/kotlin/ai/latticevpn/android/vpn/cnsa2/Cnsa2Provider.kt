package ai.latticevpn.android.vpn.cnsa2

import ai.latticevpn.android.cnsa2.LatticeTlsVpnService
import android.content.Context
import android.content.Intent
import android.os.Build
import kotlinx.coroutines.flow.StateFlow

/** Debug builds: the Lattice TLS 1.3 tunnel client. */
object Cnsa2Provider {
    fun backend(): Cnsa2Backend? = LatticeTlsBackend
}

private object LatticeTlsBackend : Cnsa2Backend {
    override val state: StateFlow<Cnsa2State> get() = LatticeTlsVpnService.state
    override val detail: StateFlow<String?> get() = LatticeTlsVpnService.detail

    override fun connect(context: Context, config: Cnsa2Config) {
        val start = Intent(context, LatticeTlsVpnService::class.java)
            .setAction(LatticeTlsVpnService.ACTION_START)
            .putExtra(LatticeTlsVpnService.EXTRA_CONFIG, config.toJson())
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) context.startForegroundService(start) else context.startService(start)
    }

    override fun disconnect(context: Context) {
        context.startService(Intent(context, LatticeTlsVpnService::class.java).setAction(LatticeTlsVpnService.ACTION_STOP))
    }
}
