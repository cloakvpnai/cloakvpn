package ai.latticevpn.android.vpn.cnsa2

import android.content.Context
import android.content.Intent
import android.os.Build
import kotlinx.coroutines.flow.StateFlow
import org.strongswan.android.logic.CharonVpnService

/** Debug builds: the strongSwan engine. */
object Cnsa2Provider {
    fun backend(): Cnsa2Backend? = StrongSwanBackend
}

private object StrongSwanBackend : Cnsa2Backend {
    override val state: StateFlow<Cnsa2State> get() = CharonVpnService.state
    override val detail: StateFlow<String?> get() = CharonVpnService.detail

    override fun connect(context: Context, config: Cnsa2Config) {
        val start = Intent(context, CharonVpnService::class.java)
            .setAction(CharonVpnService.ACTION_START)
            .putExtra(CharonVpnService.EXTRA_CONFIG, config.toJson())
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) context.startForegroundService(start) else context.startService(start)
    }

    override fun disconnect(context: Context) {
        context.startService(Intent(context, CharonVpnService::class.java).setAction(CharonVpnService.ACTION_STOP))
    }
}
