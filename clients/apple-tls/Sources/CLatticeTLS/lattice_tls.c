#include "lattice_tls.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <openssl/err.h>
#include <openssl/evp.h>
#include <openssl/rand.h>
#include <openssl/ssl.h>
#include <openssl/x509.h>
#include <openssl/x509v3.h>

#define SUITE "TLS_AES_256_GCM_SHA384"
#define GROUP "MLKEM1024"
#define SIGALG "mldsa87"

struct ltls {
    SSL_CTX *ctx;
    SSL *ssl;
    BIO *in;   /* gateway -> us */
    BIO *out;  /* us -> gateway */
    int done;
    char info[160];
    char err[256];
};

static void set_err(char *dst, size_t cap, const char *what)
{
    unsigned long e = ERR_peek_last_error();
    char detail[160] = "";
    if (e) ERR_error_string_n(e, detail, sizeof(detail));
    snprintf(dst, cap, "%s%s%s", what, e ? ": " : "", detail);
    ERR_clear_error();
}

ltls *ltls_new(const uint8_t *ca, size_t ca_len, const uint8_t *cert, size_t cert_len,
               const uint8_t *key, size_t key_len, const char *server_name,
               char *err, size_t err_len)
{
    ltls *t = calloc(1, sizeof(*t));
    X509 *ca_cert = NULL, *own = NULL;
    EVP_PKEY *pkey = NULL;
    const uint8_t *p;
    const char *what = "out of memory";

    if (!t) goto fail;
    what = "TLS context";
    t->ctx = SSL_CTX_new(TLS_client_method());
    if (!t->ctx) goto fail;

    /* The whole policy: TLS 1.3 only, one cipher suite, one group, one signature algorithm. */
    what = "suite policy";
    if (!SSL_CTX_set_min_proto_version(t->ctx, TLS1_3_VERSION) ||
        !SSL_CTX_set_max_proto_version(t->ctx, TLS1_3_VERSION) ||
        !SSL_CTX_set_ciphersuites(t->ctx, SUITE) ||
        !SSL_CTX_set1_groups_list(t->ctx, GROUP) ||
        !SSL_CTX_set1_sigalgs_list(t->ctx, SIGALG) ||
        !SSL_CTX_set1_client_sigalgs_list(t->ctx, SIGALG)) goto fail;
    SSL_CTX_set_options(t->ctx, SSL_OP_NO_TICKET | SSL_OP_NO_RENEGOTIATION);
    SSL_CTX_set_session_cache_mode(t->ctx, SSL_SESS_CACHE_OFF);
    SSL_CTX_set_num_tickets(t->ctx, 0);

    /* Trust only the CA handed in, never the system store. */
    what = "CA certificate";
    p = ca;
    ca_cert = d2i_X509(NULL, &p, (long)ca_len);
    if (!ca_cert || !X509_STORE_add_cert(SSL_CTX_get_cert_store(t->ctx), ca_cert)) goto fail;
    SSL_CTX_set_verify(t->ctx, SSL_VERIFY_PEER, NULL);

    what = "device certificate";
    p = cert;
    own = d2i_X509(NULL, &p, (long)cert_len);
    if (!own || SSL_CTX_use_certificate(t->ctx, own) != 1) goto fail;
    what = "device key";
    p = key;
    pkey = d2i_AutoPrivateKey(NULL, &p, (long)key_len);
    if (!pkey || !EVP_PKEY_is_a(pkey, "ML-DSA-87") ||
        SSL_CTX_use_PrivateKey(t->ctx, pkey) != 1 ||
        SSL_CTX_check_private_key(t->ctx) != 1) goto fail;

    what = "TLS session";
    t->ssl = SSL_new(t->ctx);
    t->in = BIO_new(BIO_s_mem());
    t->out = BIO_new(BIO_s_mem());
    if (!t->ssl || !t->in || !t->out) goto fail;
    SSL_set_bio(t->ssl, t->in, t->out); /* the session owns both from here */
    SSL_set_connect_state(t->ssl);
    SSL_set_hostflags(t->ssl, X509_CHECK_FLAG_NO_PARTIAL_WILDCARDS);
    if (!SSL_set1_host(t->ssl, server_name) ||
        !SSL_set_tlsext_host_name(t->ssl, server_name)) goto fail;

    X509_free(ca_cert); X509_free(own); EVP_PKEY_free(pkey);
    return t;

fail:
    if (err && err_len) set_err(err, err_len, what);
    X509_free(ca_cert); X509_free(own); EVP_PKEY_free(pkey);
    if (t) {
        if (t->ssl) SSL_free(t->ssl);
        else { BIO_free(t->in); BIO_free(t->out); }
        SSL_CTX_free(t->ctx);
        free(t);
    }
    return NULL;
}

void ltls_free(ltls *t)
{
    if (!t) return;
    SSL_free(t->ssl);
    SSL_CTX_free(t->ctx);
    OPENSSL_cleanse(t, sizeof(*t));
    free(t);
}

int ltls_feed(ltls *t, const uint8_t *data, size_t len)
{
    if (len == 0) return 0;
    return BIO_write(t->in, data, (int)len) == (int)len ? 0 : -1;
}

/* Belt and braces: after the handshake, confirm what was actually negotiated. */
static int check_negotiated(ltls *t)
{
    const char *group = SSL_get0_group_name(t->ssl);
    const char *suite = SSL_get_cipher_name(t->ssl);
    const char *sig = NULL;

    if (SSL_version(t->ssl) != TLS1_3_VERSION) return 0;
    if (!suite || strcmp(suite, SUITE)) return 0;
    if (!group || strcasecmp(group, GROUP)) return 0;
    if (!SSL_get0_peer_signature_name(t->ssl, &sig) || !sig || strcasecmp(sig, SIGALG)) return 0;
    if (SSL_get_verify_result(t->ssl) != X509_V_OK) return 0;
    snprintf(t->info, sizeof(t->info), "%s %s %s %s", SSL_get_version(t->ssl), suite, group, sig);
    return 1;
}

int ltls_handshake(ltls *t)
{
    int r, e;
    if (t->done) return 1;
    r = SSL_do_handshake(t->ssl);
    if (r == 1) {
        if (!check_negotiated(t)) {
            snprintf(t->err, sizeof(t->err), "negotiated parameters are outside the CNSA 2.0 suite");
            return -1;
        }
        t->done = 1;
        return 1;
    }
    e = SSL_get_error(t->ssl, r);
    if (e == SSL_ERROR_WANT_READ || e == SSL_ERROR_WANT_WRITE) return 0;
    {
        long v = SSL_get_verify_result(t->ssl);
        if (v != X509_V_OK)
            snprintf(t->err, sizeof(t->err), "gateway certificate rejected: %s", X509_verify_cert_error_string(v));
        else
            set_err(t->err, sizeof(t->err), "TLS handshake failed");
    }
    return -1;
}

int ltls_drain(ltls *t, uint8_t *out, size_t cap)
{
    int n = BIO_read(t->out, out, (int)cap);
    return n > 0 ? n : 0;
}

int ltls_write(ltls *t, const uint8_t *data, size_t len)
{
    if (!t->done) return -1;
    return SSL_write(t->ssl, data, (int)len) == (int)len ? 0 : -1;
}

int ltls_read(ltls *t, uint8_t *out, size_t cap)
{
    int n, e;
    if (!t->done) return 0;
    n = SSL_read(t->ssl, out, (int)cap);
    if (n > 0) return n;
    e = SSL_get_error(t->ssl, n);
    if (e == SSL_ERROR_WANT_READ || e == SSL_ERROR_WANT_WRITE) return 0;
    set_err(t->err, sizeof(t->err), e == SSL_ERROR_ZERO_RETURN ? "gateway closed the session" : "TLS read failed");
    return -1;
}

int ltls_export(ltls *t, const char *label, uint8_t *out, size_t len)
{
    if (!t->done) return -1;
    return SSL_export_keying_material(t->ssl, out, len, label, strlen(label), NULL, 0, 0) == 1 ? 0 : -1;
}

const char *ltls_describe(ltls *t) { return t->info; }
const char *ltls_error(ltls *t) { return t->err; }

int ltls_gcm_seal(const uint8_t *key, const uint8_t *nonce, const uint8_t *ad, size_t ad_len,
                  const uint8_t *in, size_t in_len, uint8_t *out, uint8_t *tag)
{
    EVP_CIPHER_CTX *c = EVP_CIPHER_CTX_new();
    int n = 0, ok = 0;
    if (c && EVP_EncryptInit_ex(c, EVP_aes_256_gcm(), NULL, key, nonce) == 1 &&
        EVP_EncryptUpdate(c, NULL, &n, ad, (int)ad_len) == 1 &&
        EVP_EncryptUpdate(c, out, &n, in, (int)in_len) == 1 &&
        EVP_EncryptFinal_ex(c, out + n, &n) == 1 &&
        EVP_CIPHER_CTX_ctrl(c, EVP_CTRL_AEAD_GET_TAG, 16, tag) == 1) ok = 1;
    EVP_CIPHER_CTX_free(c);
    return ok ? 0 : -1;
}

int ltls_gcm_open(const uint8_t *key, const uint8_t *nonce, const uint8_t *ad, size_t ad_len,
                  const uint8_t *in, size_t in_len, const uint8_t *tag, uint8_t *out)
{
    EVP_CIPHER_CTX *c = EVP_CIPHER_CTX_new();
    int n = 0, ok = 0;
    if (c && EVP_DecryptInit_ex(c, EVP_aes_256_gcm(), NULL, key, nonce) == 1 &&
        EVP_DecryptUpdate(c, NULL, &n, ad, (int)ad_len) == 1 &&
        EVP_DecryptUpdate(c, out, &n, in, (int)in_len) == 1 &&
        EVP_CIPHER_CTX_ctrl(c, EVP_CTRL_AEAD_SET_TAG, 16, (void *)tag) == 1 &&
        EVP_DecryptFinal_ex(c, out + n, &n) == 1) ok = 1;
    EVP_CIPHER_CTX_free(c);
    return ok ? 0 : -1;
}

int ltls_random(uint8_t *out, size_t len) { return RAND_bytes(out, (int)len) == 1 ? 0 : -1; }
