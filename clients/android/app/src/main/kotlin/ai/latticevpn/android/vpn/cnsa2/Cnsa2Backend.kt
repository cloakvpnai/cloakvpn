package ai.latticevpn.android.vpn.cnsa2

import android.content.Context
import android.util.Base64
import kotlinx.coroutines.flow.StateFlow
import org.json.JSONObject
import java.io.File

enum class Cnsa2State { OFF, CONNECTING, CONNECTED, RECONNECTING, FAILED }

/** Where the CNSA 2.0 tunnel connects and whom it trusts. Holds no secrets. */
class Cnsa2Config(
    val host: String,
    val port: Int,
    val gatewayId: String,
    val clientId: String,
    val caDer: ByteArray,
    val rekeySeconds: Int,
) {
    fun toJson(): String = JSONObject()
        .put("host", host).put("port", port)
        .put("gatewayID", gatewayId).put("clientID", clientId)
        .put("caDER", Base64.encodeToString(caDer, Base64.NO_WRAP))
        .put("rekeySeconds", rekeySeconds)
        .toString()

    companion object {
        private const val FILE = "cnsa2/gateway.json"

        fun parse(json: String): Cnsa2Config {
            val o = JSONObject(json)
            return Cnsa2Config(
                host = o.getString("host"),
                port = o.optInt("port", 4500),
                gatewayId = o.getString("gatewayID"),
                clientId = o.getString("clientID"),
                caDer = Base64.decode(o.getString("caDER"), Base64.DEFAULT),
                rekeySeconds = o.optInt("rekeySeconds", 300),
            )
        }

        fun load(context: Context): Cnsa2Config? = try {
            File(context.filesDir, FILE).takeIf { it.exists() }?.let { parse(it.readText()) }
        } catch (_: Exception) {
            null
        }

        fun save(context: Context, json: String) {
            parse(json) // refuse anything that does not parse
            File(context.filesDir, FILE).apply { parentFile?.mkdirs() }.writeText(json)
        }
    }
}

/** The tunnel engine for CNSA 2.0 mode. Present only in builds that carry it. */
interface Cnsa2Backend {
    val state: StateFlow<Cnsa2State>
    /** Short reason for the last failure, if any. */
    val detail: StateFlow<String?>
    fun connect(context: Context, config: Cnsa2Config)
    fun disconnect(context: Context)
}

object Cnsa2Suite {
    /** The only suite CNSA 2.0 mode offers, so also the only one it can negotiate. */
    const val SUMMARY = "AES-256-GCM, SHA-384, ML-KEM-1024, ML-DSA-87"
}

/**
 * What the home screen shows about the current session. Counted in memory by the
 * tunnel service; nothing here is written to disk or sent anywhere.
 */
data class Cnsa2Stats(
    /** When this session first came up (wall clock), or 0 while there is none. */
    val connectedAtMs: Long = 0,
    val rxBytes: Long = 0,
    val txBytes: Long = 0,
    /** How many times the keys have been replaced since connecting. */
    val keyChanges: Int = 0,
    /** Round trip to the gateway through the tunnel, or -1 when not measured yet. */
    val latencyMs: Int = -1,
    val latencyBestMs: Int = -1,
    val latencyAverageMs: Int = -1,
)
