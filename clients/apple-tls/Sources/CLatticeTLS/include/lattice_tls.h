#ifndef LATTICE_TLS_H
#define LATTICE_TLS_H
#include <stddef.h>
#include <stdint.h>

/* A TLS 1.3 client session restricted to the CNSA 2.0 suite:
 * TLS_AES_256_GCM_SHA384, ML-KEM-1024 key exchange, ML-DSA-87 signatures.
 * It talks through memory buffers; the caller moves the bytes. */
typedef struct ltls ltls;

/* All inputs are DER. server_name is checked against the gateway certificate.
 * Returns NULL on failure with a message in err. */
ltls *ltls_new(const uint8_t *ca, size_t ca_len,
               const uint8_t *cert, size_t cert_len,
               const uint8_t *key, size_t key_len,
               const char *server_name, char *err, size_t err_len);
void ltls_free(ltls *t);

/* Bytes received from the gateway. Returns 0, or -1 on error. */
int ltls_feed(ltls *t, const uint8_t *data, size_t len);
/* Advance the handshake. 1 = complete and verified, 0 = needs more data, -1 = failed. */
int ltls_handshake(ltls *t);
/* Bytes to send to the gateway. Returns the count written to out (0 if none). */
int ltls_drain(ltls *t, uint8_t *out, size_t cap);
/* Application data. write returns 0 or -1; read returns the count, 0 if none, -1 on error. */
int ltls_write(ltls *t, const uint8_t *data, size_t len);
int ltls_read(ltls *t, uint8_t *out, size_t cap);
/* RFC 8446 exporter. Returns 0 or -1. */
int ltls_export(ltls *t, const char *label, uint8_t *out, size_t len);
/* "TLSv1.3 TLS_AES_256_GCM_SHA384 MLKEM1024 mldsa87" once the handshake is complete. */
const char *ltls_describe(ltls *t);
const char *ltls_error(ltls *t);

/* AES-256-GCM, 12 byte nonce, 16 byte tag. Return 0 or -1. */
int ltls_gcm_seal(const uint8_t *key, const uint8_t *nonce,
                  const uint8_t *ad, size_t ad_len,
                  const uint8_t *in, size_t in_len, uint8_t *out, uint8_t *tag);
int ltls_gcm_open(const uint8_t *key, const uint8_t *nonce,
                  const uint8_t *ad, size_t ad_len,
                  const uint8_t *in, size_t in_len, const uint8_t *tag, uint8_t *out);
int ltls_random(uint8_t *out, size_t len);
#endif
