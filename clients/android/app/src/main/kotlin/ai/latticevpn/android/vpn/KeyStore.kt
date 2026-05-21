package ai.latticevpn.android.vpn

import android.content.Context
import java.io.File

/**
 * On-device persistence for the cryptographic identities the
 * provisioning + Rosenpass flows depend on. The Android counterpart of
 * the iOS `AppGroupKeyStore`.
 *
 * Two kinds of material are stored, in two different places, for size
 * reasons that mirror the iOS rationale:
 *
 *   - **Rosenpass key blobs** (the device's static keypair + the
 *     server's public key). A Classic McEliece-460896 public key is
 *     ~524 KB raw / ~700 KB base64. SharedPreferences loads its whole
 *     XML backing file into memory on every access, so multi-hundred-KB
 *     values there are a memory and latency footgun. These live as
 *     individual files under `filesDir/keystore/` instead.
 *   - **WireGuard keypair** (Curve25519 — 32 raw bytes, 44 base64
 *     chars each). Tiny; kept in the shared `"lattice"` SharedPreferences
 *     alongside the JWT/install-UUID that [ai.latticevpn.android.data.AuthClient]
 *     already manages.
 *
 * Privacy model (ported verbatim from iOS): both private keys are
 * generated on-device and never leave it. Provisioning sends only the
 * two *public* keys to cloak-api-server. The server's Rosenpass public
 * key arrives in the imported config block and is cached here so the
 * rotation loop can start a handshake without re-parsing config.
 *
 * At-rest protection: files live in the app-private `filesDir`, which is
 * inside the app sandbox (other apps cannot read it). This matches the
 * practical protection level of the iOS store's
 * `.completeUntilFirstUserAuthentication` class. Wrapping the secret-key
 * files with Android Keystore / Jetpack Security `EncryptedFile` is a
 * reasonable hardening follow-up and is intentionally left as a TODO so
 * this phase does not pull in a new dependency.
 */
class KeyStore(appCtx: Context) {

    /** A base64-encoded keypair (whatever curve / KEM the caller used). */
    data class Keypair(val secretB64: String, val publicB64: String)

    /** Thrown when a requested key is absent or unreadable. */
    class KeyStoreException(message: String, cause: Throwable? = null) : Exception(message, cause)

    private val context = appCtx.applicationContext

    /** Directory holding the large Rosenpass blobs. Created on demand. */
    private val dir: File by lazy {
        File(context.filesDir, KEYSTORE_DIR).apply { mkdirs() }
    }

    private val prefs by lazy {
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
    }

    // ---------------------------------------------------------------
    // Local device Rosenpass keypair (the privacy-fix: device-generated,
    // secret never leaves the device).
    // ---------------------------------------------------------------

    /** True once a local Rosenpass keypair has been generated + persisted. */
    fun hasLocalKeypair(): Boolean =
        file(FILE_RP_LOCAL_SECRET).exists() && file(FILE_RP_LOCAL_PUBLIC).exists()

    /**
     * Persist a freshly generated Rosenpass keypair as this device's
     * long-term post-quantum identity. Idempotent — overwrites atomically.
     */
    fun saveLocalKeypair(secretB64: String, publicB64: String) {
        writeAtomic(FILE_RP_LOCAL_SECRET, secretB64)
        writeAtomic(FILE_RP_LOCAL_PUBLIC, publicB64)
    }

    /** Load the device's local Rosenpass keypair. Throws if either half is missing. */
    fun loadLocalKeypair(): Keypair = Keypair(
        secretB64 = read(FILE_RP_LOCAL_SECRET),
        publicB64 = read(FILE_RP_LOCAL_PUBLIC),
    )

    /** Wipe the local Rosenpass keypair. Destroys the device's PQ identity. */
    fun clearLocalKeypair() {
        file(FILE_RP_LOCAL_SECRET).delete()
        file(FILE_RP_LOCAL_PUBLIC).delete()
    }

    // ---------------------------------------------------------------
    // Local device WireGuard keypair (Curve25519 — small, kept in prefs).
    // ---------------------------------------------------------------

    /** True once a local WireGuard keypair has been generated + persisted. */
    fun hasLocalWgKeypair(): Boolean =
        prefs.contains(KEY_WG_SECRET) && prefs.contains(KEY_WG_PUBLIC)

    /** Persist a freshly generated WireGuard keypair. Idempotent. */
    fun saveLocalWgKeypair(secretB64: String, publicB64: String) {
        prefs.edit()
            .putString(KEY_WG_SECRET, secretB64)
            .putString(KEY_WG_PUBLIC, publicB64)
            .apply()
    }

    /** Load the device's local WireGuard keypair. Throws if missing. */
    fun loadLocalWgKeypair(): Keypair {
        val secret = prefs.getString(KEY_WG_SECRET, null)
            ?: throw KeyStoreException("local WireGuard secret key absent")
        val public = prefs.getString(KEY_WG_PUBLIC, null)
            ?: throw KeyStoreException("local WireGuard public key absent")
        return Keypair(secret, public)
    }

    /** Wipe the local WireGuard keypair. */
    fun clearLocalWgKeypair() {
        prefs.edit().remove(KEY_WG_SECRET).remove(KEY_WG_PUBLIC).apply()
    }

    // ---------------------------------------------------------------
    // Server Rosenpass public key (parsed out of an imported config).
    // ---------------------------------------------------------------

    /** True once a server Rosenpass public key has been imported. */
    fun hasServerPublicKey(): Boolean = file(FILE_RP_SERVER_PUBLIC).exists()

    /** Persist the server's Rosenpass public key. Replaces any prior value. */
    fun saveServerPublicKey(b64: String) = writeAtomic(FILE_RP_SERVER_PUBLIC, b64)

    /** Load the server's Rosenpass public key. Throws if not yet imported. */
    fun loadServerPublicKey(): String = read(FILE_RP_SERVER_PUBLIC)

    /**
     * Wipe the server pubkey only — used when re-importing a config for a
     * different region. The device's own keypair is left untouched: its
     * identity is stable across config re-imports.
     */
    fun clearServerPublicKey() {
        file(FILE_RP_SERVER_PUBLIC).delete()
    }

    // ---------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------

    private fun file(name: String) = File(dir, name)

    private fun read(name: String): String {
        val f = file(name)
        if (!f.exists()) throw KeyStoreException("key file '$name' not found")
        return try {
            f.readText(Charsets.UTF_8)
        } catch (e: Exception) {
            throw KeyStoreException("failed to read key file '$name'", e)
        }
    }

    /**
     * Write `content` to `name` atomically: write to a sibling `.tmp`
     * file, then rename over the target. The rename is atomic on the
     * local filesystem, so a reader never observes a half-written key.
     */
    private fun writeAtomic(name: String, content: String) {
        val target = file(name)
        val tmp = File(dir, "$name.tmp")
        try {
            tmp.writeText(content, Charsets.UTF_8)
            if (!tmp.renameTo(target)) {
                // renameTo can fail if the target exists on some
                // filesystems — fall back to delete + rename.
                target.delete()
                if (!tmp.renameTo(target)) {
                    throw KeyStoreException("atomic rename failed for '$name'")
                }
            }
        } catch (e: KeyStoreException) {
            throw e
        } catch (e: Exception) {
            throw KeyStoreException("failed to write key file '$name'", e)
        } finally {
            tmp.delete()
        }
    }

    companion object {
        /** Shared with AuthClient + TunnelRepository so all app prefs live in one store. */
        private const val PREFS_NAME = "lattice"

        private const val KEYSTORE_DIR = "keystore"

        private const val FILE_RP_LOCAL_SECRET = "rp_local_seckey.b64"
        private const val FILE_RP_LOCAL_PUBLIC = "rp_local_pubkey.b64"
        private const val FILE_RP_SERVER_PUBLIC = "rp_server_pubkey.b64"

        private const val KEY_WG_SECRET = "wg_local_seckey_b64"
        private const val KEY_WG_PUBLIC = "wg_local_pubkey_b64"
    }
}
