package ai.latticevpn.android.vpn.cnsa2

import android.content.Context
import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyInfo
import android.security.keystore.KeyProperties
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.GCMParameterSpec

/**
 * Keeps the device's ML-DSA-87 identity on the phone.
 *
 * Android's hardware keystore cannot hold ML-DSA keys, so the 32 byte seed is
 * generated here and stored encrypted with AES-256-GCM under a key that the
 * hardware keystore does hold and never releases. The seed is created on the
 * device and never leaves it; only the certificate request does.
 */
class Cnsa2IdentityStore(context: Context) {
    private val dir = File(context.applicationContext.filesDir, "cnsa2").apply { mkdirs() }
    private val seedFile = File(dir, "identity.bin")
    private val certificateFile = File(dir, "client.der")

    fun hasIdentity(): Boolean = seedFile.exists()

    /** The seed, created on first use. Callers should wipe it after use. */
    @Synchronized fun seed(): ByteArray {
        if (seedFile.exists()) return open(seedFile.readBytes())
        val seed = Cnsa2Keys.newSeed()
        val tmp = File(dir, "identity.tmp")
        tmp.writeBytes(seal(seed))
        check(tmp.renameTo(seedFile)) { "could not store identity" }
        certificateFile.delete()
        return seed
    }

    fun certificateRequest(commonName: String): ByteArray {
        val seed = seed()
        try {
            return Cnsa2Keys.certificateRequest(seed, commonName)
        } finally {
            seed.fill(0)
        }
    }

    fun privateKeyPkcs8(): ByteArray {
        val seed = seed()
        try {
            return Cnsa2Keys.pkcs8(seed)
        } finally {
            seed.fill(0)
        }
    }

    /** Accepts a certificate only if it carries this device's public key. */
    fun storeCertificate(der: ByteArray) {
        val seed = seed()
        val publicKey = try {
            Cnsa2Keys.publicKeyInfo(seed)
        } finally {
            seed.fill(0)
        }
        require(indexOf(der, publicKey) >= 0) { "certificate is for a different key" }
        certificateFile.writeBytes(der)
    }

    fun certificate(): ByteArray? = if (certificateFile.exists()) certificateFile.readBytes() else null

    @Synchronized fun reset() {
        seedFile.delete()
        certificateFile.delete()
        KeyStore.getInstance(PROVIDER).apply { load(null) }.deleteEntry(ALIAS)
    }

    /** Where the wrapping key lives: "strongbox", "tee", "software" or "unknown". */
    fun wrappingKeyProtection(): String = try {
        val key = wrappingKey()
        val info = SecretKeyFactory.getInstance(key.algorithm, PROVIDER).getKeySpec(key, KeyInfo::class.java) as KeyInfo
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            when (info.securityLevel) {
                KeyProperties.SECURITY_LEVEL_STRONGBOX -> "strongbox"
                KeyProperties.SECURITY_LEVEL_TRUSTED_ENVIRONMENT -> "tee"
                KeyProperties.SECURITY_LEVEL_SOFTWARE -> "software"
                else -> "unknown"
            }
        } else {
            @Suppress("DEPRECATION") if (info.isInsideSecureHardware) "tee" else "software"
        }
    } catch (_: Exception) {
        "unknown"
    }

    private fun wrappingKey(): SecretKey {
        val store = KeyStore.getInstance(PROVIDER).apply { load(null) }
        (store.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, PROVIDER)
        generator.init(
            KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setKeySize(256)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .build()
        )
        return generator.generateKey()
    }

    private fun seal(plain: ByteArray): ByteArray {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, wrappingKey())
        cipher.updateAAD(AAD)
        val iv = cipher.iv
        check(iv.size == IV_BYTES)
        return iv + cipher.doFinal(plain)
    }

    private fun open(sealed: ByteArray): ByteArray {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.DECRYPT_MODE, wrappingKey(), GCMParameterSpec(128, sealed, 0, IV_BYTES))
        cipher.updateAAD(AAD)
        return cipher.doFinal(sealed, IV_BYTES, sealed.size - IV_BYTES)
    }

    private fun indexOf(haystack: ByteArray, needle: ByteArray): Int {
        outer@ for (i in 0..haystack.size - needle.size) {
            for (j in needle.indices) if (haystack[i + j] != needle[j]) continue@outer
            return i
        }
        return -1
    }

    private companion object {
        const val PROVIDER = "AndroidKeyStore"
        const val ALIAS = "lattice-cnsa2-identity-wrap"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
        const val IV_BYTES = 12
        val AAD = "lattice-vpn/cnsa2-identity/v1".toByteArray()
    }
}
