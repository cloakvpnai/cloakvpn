/* Windows-only additions to the shared C layer in
 * clients/apple-tls/Sources/CLatticeTLS. The shared file is compiled as is.
 *
 * On Apple platforms the device key and certificate request are made with
 * CryptoKit, and on Android in Kotlin. Windows has no equivalent that works on
 * every supported release, so they are made here with the same OpenSSL that
 * runs the tunnel. That keeps the Windows app on a single cryptographic module. */
#include <stdint.h>
#include <string.h>
#include <time.h>
#include <openssl/asn1.h>
#include <openssl/crypto.h>
#include <openssl/decoder.h>
#include <openssl/encoder.h>
#include <openssl/err.h>
#include <openssl/evp.h>
#include <openssl/opensslv.h>
#include <openssl/ssl.h>
#include <openssl/x509.h>

#define DEVICE_KEY "ML-DSA-87"

/* Must be the first OpenSSL call in the process. Turns off the automatic
 * loading of openssl.cnf, so no file on disk can change how the library
 * behaves inside the LocalSystem service. Returns 0 on success. */
int ltls_win_init(void)
{
    return OPENSSL_init_ssl(OPENSSL_INIT_NO_LOAD_CONFIG, NULL) == 1 ? 0 : -1;
}

/* "OpenSSL 3.5.9 ..." for the license screen and diagnostics. */
const char *ltls_win_openssl_version(void)
{
    return OpenSSL_version(OPENSSL_VERSION);
}

/* PKCS#8 through the provider decoders, as in lattice_tls.c. NULL unless the
 * key is ML-DSA-87. */
static EVP_PKEY *load_device_key(const uint8_t *key, size_t key_len)
{
    EVP_PKEY *pkey = NULL;
    const unsigned char *p = key;
    size_t len = key_len;
    OSSL_DECODER_CTX *d = OSSL_DECODER_CTX_new_for_pkey(&pkey, "DER", "PrivateKeyInfo", NULL,
                                                        EVP_PKEY_KEYPAIR, NULL, NULL);
    if (d) {
        if (OSSL_DECODER_from_data(d, &p, &len) != 1) {
            EVP_PKEY_free(pkey);
            pkey = NULL;
        }
        OSSL_DECODER_CTX_free(d);
    }
    if (pkey && !EVP_PKEY_is_a(pkey, DEVICE_KEY)) {
        EVP_PKEY_free(pkey);
        pkey = NULL;
    }
    ERR_clear_error();
    return pkey;
}

/* Makes a new ML-DSA-87 key on this device and writes it to out as PKCS#8 DER.
 * Returns the length, or -1. The caller protects and stores it; it is never sent anywhere. */
int ltls_win_keygen(uint8_t *out, size_t cap)
{
    EVP_PKEY *pkey = EVP_PKEY_Q_keygen(NULL, NULL, DEVICE_KEY);
    OSSL_ENCODER_CTX *e = NULL;
    unsigned char *der = NULL;
    size_t len = 0;
    int ret = -1;

    if (!pkey) goto done;
    e = OSSL_ENCODER_CTX_new_for_pkey(pkey, EVP_PKEY_KEYPAIR, "DER", "PrivateKeyInfo", NULL);
    if (!e || OSSL_ENCODER_to_data(e, &der, &len) != 1 || len == 0 || len > cap) goto done;
    memcpy(out, der, len);
    ret = (int)len;
done:
    if (der) OPENSSL_clear_free(der, len);
    OSSL_ENCODER_CTX_free(e);
    EVP_PKEY_free(pkey);
    ERR_clear_error();
    return ret;
}

/* Builds a PKCS#10 certificate request (version 0, subject CN=common_name) for
 * the key and signs it with that key, which is the proof of possession the
 * signing service checks. Writes DER to out. Returns the length, or -1. */
int ltls_win_csr(const uint8_t *key, size_t key_len, const char *common_name, uint8_t *out, size_t cap)
{
    EVP_PKEY *pkey = load_device_key(key, key_len);
    X509_REQ *req = NULL;
    X509_NAME *name;
    unsigned char *der = NULL;
    int len, ret = -1;

    if (!pkey || !common_name) goto done;
    req = X509_REQ_new();
    if (!req || X509_REQ_set_version(req, X509_REQ_VERSION_1) != 1) goto done;
    name = X509_REQ_get_subject_name(req);
    if (!name || X509_NAME_add_entry_by_txt(name, "CN", MBSTRING_UTF8,
                                            (const unsigned char *)common_name, -1, -1, 0) != 1) goto done;
    if (X509_REQ_set_pubkey(req, pkey) != 1) goto done;
    /* ML-DSA signs the message directly: no separate digest. */
    if (X509_REQ_sign(req, pkey, NULL) <= 0) goto done;
    len = i2d_X509_REQ(req, &der);
    if (len <= 0 || (size_t)len > cap) goto done;
    memcpy(out, der, (size_t)len);
    ret = len;
done:
    OPENSSL_free(der);
    X509_REQ_free(req);
    EVP_PKEY_free(pkey);
    ERR_clear_error();
    return ret;
}

/* 1 if the certificate (DER, nothing after it) carries the public key that
 * belongs to this private key, 0 if it does not, -1 if either cannot be read. */
int ltls_win_cert_matches_key(const uint8_t *cert, size_t cert_len, const uint8_t *key, size_t key_len)
{
    const unsigned char *p = cert;
    X509 *x = d2i_X509(NULL, &p, (long)cert_len);
    EVP_PKEY *pkey = load_device_key(key, key_len);
    int ret = -1;

    if (x && pkey && p == cert + cert_len)
        ret = X509_check_private_key(x, pkey) == 1 ? 1 : 0;
    X509_free(x);
    EVP_PKEY_free(pkey);
    ERR_clear_error();
    return ret;
}

/* The certificate's expiry as seconds since 1970 (UTC), or -1. Read from the
 * certificate itself, not from what the server says about it. */
int64_t ltls_win_cert_not_after(const uint8_t *cert, size_t cert_len)
{
    const unsigned char *p = cert;
    X509 *x = d2i_X509(NULL, &p, (long)cert_len);
    struct tm tm;
    int64_t ret = -1;

    memset(&tm, 0, sizeof(tm));
    if (x && p == cert + cert_len && ASN1_TIME_to_tm(X509_get0_notAfter(x), &tm) == 1)
        ret = (int64_t)_mkgmtime64(&tm);
    X509_free(x);
    ERR_clear_error();
    return ret;
}

/* SHA-384 of data into out (48 bytes). Returns 0 or -1. */
int ltls_win_sha384(const uint8_t *data, size_t len, uint8_t *out)
{
    size_t n = 0;
    return EVP_Q_digest(NULL, "SHA384", NULL, data, len, out, &n) == 1 && n == 48 ? 0 : -1;
}
