package ai.latticevpn.android.vpn

import ai.latticevpn.android.data.ProvisionedConfig
import org.json.JSONObject

data class LatticeConfig(
    val wgPrivateKey: String,
    val addressV4: String,
    val addressV6: String,
    val dns: List<String>,
    val peerPublicKey: String,
    val endpoint: String,
    val allowedIPs: List<String>,
    val persistentKeepalive: Int,
    val pqEnabled: Boolean,
    val serverRPPublicKeyB64: String,
    val rpEndpoint: String,
    val clientRPSecretKeyB64: String,
    val clientRPPublicKeyB64: String,
    val pskRotationSeconds: Int
) {
    fun serialize(): String = JSONObject().apply {
        put("wgPrivateKey", wgPrivateKey)
        put("addressV4", addressV4)
        put("addressV6", addressV6)
        put("dns", dns.joinToString(","))
        put("peerPublicKey", peerPublicKey)
        put("endpoint", endpoint)
        put("allowedIPs", allowedIPs.joinToString(","))
        put("persistentKeepalive", persistentKeepalive)
        put("pqEnabled", pqEnabled)
        put("serverRPPublicKeyB64", serverRPPublicKeyB64)
        put("rpEndpoint", rpEndpoint)
        put("clientRPSecretKeyB64", clientRPSecretKeyB64)
        put("clientRPPublicKeyB64", clientRPPublicKeyB64)
        put("pskRotationSeconds", pskRotationSeconds)
    }.toString()

    companion object {
        fun deserialize(raw: String): LatticeConfig {
            val j = JSONObject(raw)
            return LatticeConfig(
                wgPrivateKey = j.getString("wgPrivateKey"),
                addressV4 = j.getString("addressV4"),
                addressV6 = j.getString("addressV6"),
                dns = j.getString("dns").split(",").map { it.trim() },
                peerPublicKey = j.getString("peerPublicKey"),
                endpoint = j.getString("endpoint"),
                allowedIPs = j.getString("allowedIPs").split(",").map { it.trim() },
                persistentKeepalive = j.getInt("persistentKeepalive"),
                pqEnabled = j.getBoolean("pqEnabled"),
                serverRPPublicKeyB64 = j.getString("serverRPPublicKeyB64"),
                rpEndpoint = j.getString("rpEndpoint"),
                clientRPSecretKeyB64 = j.getString("clientRPSecretKeyB64"),
                clientRPPublicKeyB64 = j.getString("clientRPPublicKeyB64"),
                pskRotationSeconds = j.getInt("pskRotationSeconds")
            )
        }
    }
}

/**
 * Parser for the INI-style config block emitted by server/scripts/setup.sh.
 * Mirrors the iOS ConfigParser.swift exactly so one server script emits
 * a config both platforms understand.
 */
object ConfigParser {
    fun parse(text: String): LatticeConfig {
        val sections = mutableMapOf<String, MutableMap<String, String>>()
        var current: String? = null
        for (raw in text.split("\n")) {
            val line = raw.trim()
            if (line.isEmpty() || line.startsWith("#")) continue
            if (line.startsWith("[") && line.endsWith("]")) {
                current = line.drop(1).dropLast(1)
                sections[current] = mutableMapOf()
                continue
            }
            val sec = current ?: continue
            val eq = line.indexOf('=')
            if (eq < 0) continue
            val k = line.substring(0, eq).trim()
            val v = line.substring(eq + 1).trim()
            sections.getOrPut(sec) { mutableMapOf() }[k] = v
        }

        fun get(section: String, key: String, default: String? = null): String {
            val s = sections[section] ?: if (default != null) return default else error("[$section] missing")
            return s[key] ?: default ?: error("[$section] $key missing")
        }
        fun list(section: String, key: String): List<String> =
            get(section, key).split(",").map { it.trim() }

        return LatticeConfig(
            // private_key is OPTIONAL: configs returned by
            // cloak-api-server omit it (the device holds its own locally
            // generated WireGuard keypair). TunnelManager fills this in
            // from KeyStore before the config reaches the tunnel. Legacy
            // pasted configs that DO carry private_key still work.
            wgPrivateKey = get("wireguard", "private_key", ""),
            addressV4 = get("wireguard", "address_v4"),
            // address_v6 is OPTIONAL: the account-number API assigns an
            // IPv4 tunnel address only. Legacy pasted configs may carry one.
            addressV6 = get("wireguard", "address_v6", ""),
            dns = list("wireguard", "dns"),
            peerPublicKey = get("wireguard.peer", "public_key"),
            endpoint = get("wireguard.peer", "endpoint"),
            allowedIPs = list("wireguard.peer", "allowed_ips"),
            persistentKeepalive = get("wireguard.peer", "persistent_keepalive", "25").toInt(),
            pqEnabled = sections.containsKey("rosenpass"),
            serverRPPublicKeyB64 = sections["rosenpass"]?.get("server_public_key_b64") ?: "",
            rpEndpoint = sections["rosenpass"]?.get("server_endpoint") ?: "",
            clientRPSecretKeyB64 = sections["rosenpass"]?.get("client_secret_key_b64") ?: "",
            clientRPPublicKeyB64 = sections["rosenpass"]?.get("client_public_key_b64") ?: "",
            pskRotationSeconds = (sections["rosenpass"]?.get("psk_rotation_seconds") ?: "120").toInt()
        )
    }
}

// Defaults for fields the JSON provisioning response does not carry —
// the server's wg.ClientConfig omits the keepalive and the rotation
// cadence, so the client supplies the same values the INI configs used.
private const val DEFAULT_KEEPALIVE_SECONDS = 25
private const val DEFAULT_PSK_ROTATION_SECONDS = 120

/**
 * Build a [LatticeConfig] from the [ProvisionedConfig] returned by
 * POST /v1/device.
 *
 * The account-number API sends an IPv4-only interface address and omits
 * both private keys (the device holds its own WireGuard + Rosenpass
 * secrets) — [TunnelManager.importConfig] fills `wgPrivateKey` from the
 * KeyStore, and the rotator reads the Rosenpass secret from the KeyStore
 * directly, so an empty `clientRPSecretKeyB64` here is expected.
 */
fun latticeConfigFrom(p: ProvisionedConfig): LatticeConfig = LatticeConfig(
    wgPrivateKey = "",                       // device holds it; filled on import
    addressV4 = p.interfaceAddress,
    addressV6 = "",                          // account-number API assigns v4 only
    dns = p.interfaceDNS.splitCsv(),
    peerPublicKey = p.peerPublicKey,
    endpoint = p.peerEndpoint,
    allowedIPs = p.peerAllowedIPs.splitCsv(),
    persistentKeepalive = DEFAULT_KEEPALIVE_SECONDS,
    pqEnabled = p.rosenpassPeerPub.isNotEmpty(),
    serverRPPublicKeyB64 = p.rosenpassPeerPub,
    rpEndpoint = p.rosenpassListen,
    clientRPSecretKeyB64 = "",               // device holds it (see KeyStore)
    clientRPPublicKeyB64 = p.rosenpassClientPK,
    pskRotationSeconds = DEFAULT_PSK_ROTATION_SECONDS,
)

/** Split a comma-separated field into trimmed, non-empty entries. */
private fun String.splitCsv(): List<String> =
    split(",").map { it.trim() }.filter { it.isNotEmpty() }
