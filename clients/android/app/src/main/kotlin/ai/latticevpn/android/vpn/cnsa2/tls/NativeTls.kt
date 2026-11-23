package ai.latticevpn.android.vpn.cnsa2.tls

/**
 * liblatticetls.so: OpenSSL 3.5 restricted to the CNSA 2.0 suite. The C code
 * behind it is shared unchanged with the Apple client.
 */
internal object NativeTls {
    init {
        System.loadLibrary("latticetls")
    }

    @JvmStatic external fun create(ca: ByteArray, certificate: ByteArray, key: ByteArray, gatewayName: String): Long
    @JvmStatic external fun destroy(handle: Long)
    @JvmStatic external fun feed(handle: Long, data: ByteArray)
    @JvmStatic external fun handshake(handle: Long): Boolean
    @JvmStatic external fun drain(handle: Long): ByteArray?
    @JvmStatic external fun write(handle: Long, data: ByteArray)
    @JvmStatic external fun readRecord(handle: Long): ByteArray?
    @JvmStatic external fun exportKeys(handle: Long, label: String, length: Int): ByteArray
    @JvmStatic external fun describe(handle: Long): String
    @JvmStatic external fun gcmSeal(key: ByteArray, nonce: ByteArray, ad: ByteArray, plain: ByteArray): ByteArray?
    @JvmStatic external fun gcmOpen(key: ByteArray, nonce: ByteArray, ad: ByteArray, sealed: ByteArray): ByteArray?
    @JvmStatic external fun random(length: Int): ByteArray
}

class TunnelException(message: String) : Exception(message)

/** The device's CNSA 2.0 identity and the gateway it trusts. All DER. */
class TunnelIdentity(
    val caDer: ByteArray,
    val certificateDer: ByteArray,
    val privateKeyPkcs8: ByteArray,
    val gatewayName: String,
)

/** AES-256-GCM and randomness. Output of seal and input of open is tag (16 bytes) then ciphertext. */
interface TunnelCrypto {
    fun seal(key: ByteArray, nonce: ByteArray, ad: ByteArray, plain: ByteArray): ByteArray
    fun open(key: ByteArray, nonce: ByteArray, ad: ByteArray, sealed: ByteArray): ByteArray?
    fun random(length: Int): ByteArray
}

internal object NativeCrypto : TunnelCrypto {
    override fun seal(key: ByteArray, nonce: ByteArray, ad: ByteArray, plain: ByteArray): ByteArray =
        NativeTls.gcmSeal(key, nonce, ad, plain) ?: throw TunnelException("encryption failed")

    override fun open(key: ByteArray, nonce: ByteArray, ad: ByteArray, sealed: ByteArray): ByteArray? =
        NativeTls.gcmOpen(key, nonce, ad, sealed)

    override fun random(length: Int): ByteArray = NativeTls.random(length)
}

/** One TLS 1.3 handshake and session. */
internal class TlsSession(identity: TunnelIdentity) {
    private var handle: Long = try {
        NativeTls.create(identity.caDer, identity.certificateDer, identity.privateKeyPkcs8, identity.gatewayName)
    } catch (e: IllegalStateException) {
        throw TunnelException(e.message ?: "TLS setup failed")
    }

    val summary: String get() = if (handle != 0L) NativeTls.describe(handle) else ""

    private inline fun <T> call(block: (Long) -> T): T {
        check(handle != 0L) { "session closed" }
        try {
            return block(handle)
        } catch (e: IllegalStateException) {
            throw TunnelException(e.message ?: "TLS failure")
        }
    }

    fun feed(data: ByteArray) = call { NativeTls.feed(it, data) }
    fun handshake(): Boolean = call { NativeTls.handshake(it) }
    fun drain(): ByteArray = call { NativeTls.drain(it) } ?: ByteArray(0)
    fun write(data: ByteArray) = call { NativeTls.write(it, data) }
    fun export(label: String, length: Int): ByteArray = call { NativeTls.exportKeys(it, label, length) }

    /** Application data, one element per TLS record. */
    fun readRecords(): List<ByteArray> {
        val out = ArrayList<ByteArray>()
        while (true) out.add(call { NativeTls.readRecord(it) } ?: break)
        return out
    }

    fun close() {
        if (handle != 0L) {
            NativeTls.destroy(handle)
            handle = 0
        }
    }
}
