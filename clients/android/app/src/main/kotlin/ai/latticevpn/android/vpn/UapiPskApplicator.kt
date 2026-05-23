package ai.latticevpn.android.vpn

import android.util.Log
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.util.Base64

/**
 * Seamless [PskApplicator]: updates the peer's preshared key on the
 * running WireGuard tunnel **in place**, via the customized libwg-go's
 * `wgSetConfig` (the WireGuard UAPI "set" path) — no tunnel teardown,
 * no reconnect.
 *
 * This is the recommended applicator. It degrades safely: if the custom
 * `libwg-go.so` was never built (see `clients/android/libwg-go/`),
 * [WgUapi.setConfig] reports unavailable and this delegates to
 * [fallback] — normally [ReconfiguringPskApplicator] — so PSK rotation
 * still happens every cycle, just with the brief reconnect.
 *
 * The UAPI "set" payload identifies the peer by `public_key=` and sets
 * `update_only=true` so a missing peer is never silently created;
 * `preshared_key=` is the only field changed. The new key takes effect
 * on the next routine WireGuard rekey.
 */
class UapiPskApplicator(
    private val peerPublicKeyB64: String,
    private val repository: TunnelRepository,
    private val fallback: PskApplicator,
) : PskApplicator {

    override suspend fun apply(psk: ByteArray) {
        require(psk.size == 32) { "Rosenpass PSK must be 32 bytes, got ${psk.size}" }

        // The peer's WireGuard public key, stored base64, must be hex
        // for the UAPI. A malformed value can't be repaired here — fall
        // back rather than send a broken payload.
        val peerKeyHex = decodePeerKeyHex()
        if (peerKeyHex == null) {
            Log.e(TAG, "peer public key invalid; using fallback applicator")
            fallback.apply(psk)
            return
        }

        // WireGuard UAPI "set" payload — key=value lines, no "set=1".
        val payload = buildString {
            append("public_key=").append(peerKeyHex).append('\n')
            append("update_only=true\n")
            append("preshared_key=").append(toHex(psk)).append('\n')
        }

        val applied = withContext(Dispatchers.IO) { WgUapi.setConfig(payload) }
        if (applied) {
            // The key is live on wireguard-go now, but the seamless path
            // bypasses TunnelRepository entirely — record it so a later
            // reconnect re-presents the same key instead of desyncing
            // against the server (which keeps the rotated key).
            repository.recordRotatedPsk(psk)
            Log.i(TAG, "PSK rotated in place via UAPI — no tunnel bounce")
        } else {
            // The fallback (ReconfiguringPskApplicator) records + persists
            // the PSK itself via TunnelRepository.applyPresharedKey.
            Log.w(TAG, "seamless UAPI path unavailable; falling back to tunnel reconfigure")
            fallback.apply(psk)
        }
    }

    /** Decode the base64 peer key to lowercase hex, or null if malformed. */
    private fun decodePeerKeyHex(): String? {
        val raw = try {
            Base64.getDecoder().decode(peerPublicKeyB64.trim())
        } catch (e: IllegalArgumentException) {
            return null
        }
        if (raw.size != 32) return null
        return toHex(raw)
    }

    private fun toHex(bytes: ByteArray): String {
        val sb = StringBuilder(bytes.size * 2)
        for (b in bytes) {
            val v = b.toInt() and 0xFF
            sb.append(HEX[v ushr 4])
            sb.append(HEX[v and 0x0F])
        }
        return sb.toString()
    }

    companion object {
        private const val TAG = "UapiPskApplicator"
        private val HEX = "0123456789abcdef".toCharArray()
    }
}
