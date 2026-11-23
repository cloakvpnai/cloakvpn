/* JNI surface of the Lattice TLS layer for ai.latticevpn.android.vpn.cnsa2.tls.NativeTls.
 * All policy lives in lattice_tls.c, shared unchanged with the Apple client. */
#include <jni.h>
#include <stdlib.h>
#include <string.h>
#include "lattice_tls.h"

#define FN(name) Java_ai_latticevpn_android_vpn_cnsa2_tls_NativeTls_##name

static void throw_state(JNIEnv *env, const char *message)
{
    jclass cls = (*env)->FindClass(env, "java/lang/IllegalStateException");
    if (cls) (*env)->ThrowNew(env, cls, message && *message ? message : "TLS failure");
}

static jbyteArray to_array(JNIEnv *env, const uint8_t *data, size_t len)
{
    jbyteArray out = (*env)->NewByteArray(env, (jsize)len);
    if (out && len) (*env)->SetByteArrayRegion(env, out, 0, (jsize)len, (const jbyte *)data);
    return out;
}

JNIEXPORT jlong JNICALL FN(create)(JNIEnv *env, jclass cls, jbyteArray ca, jbyteArray cert, jbyteArray key, jstring name)
{
    char err[256] = "";
    jsize ca_len = (*env)->GetArrayLength(env, ca), cert_len = (*env)->GetArrayLength(env, cert),
          key_len = (*env)->GetArrayLength(env, key);
    jbyte *ca_b = (*env)->GetByteArrayElements(env, ca, NULL);
    jbyte *cert_b = (*env)->GetByteArrayElements(env, cert, NULL);
    jbyte *key_b = (*env)->GetByteArrayElements(env, key, NULL);
    const char *server = (*env)->GetStringUTFChars(env, name, NULL);
    ltls *t = NULL;
    if (ca_b && cert_b && key_b && server) {
        t = ltls_new((const uint8_t *)ca_b, (size_t)ca_len, (const uint8_t *)cert_b, (size_t)cert_len,
                     (const uint8_t *)key_b, (size_t)key_len, server, err, sizeof(err));
    }
    if (key_b) { memset(key_b, 0, (size_t)key_len); (*env)->ReleaseByteArrayElements(env, key, key_b, JNI_ABORT); }
    if (cert_b) (*env)->ReleaseByteArrayElements(env, cert, cert_b, JNI_ABORT);
    if (ca_b) (*env)->ReleaseByteArrayElements(env, ca, ca_b, JNI_ABORT);
    if (server) (*env)->ReleaseStringUTFChars(env, name, server);
    if (!t) throw_state(env, err);
    return (jlong)(intptr_t)t;
}

JNIEXPORT void JNICALL FN(destroy)(JNIEnv *env, jclass cls, jlong h) { ltls_free((ltls *)(intptr_t)h); }

JNIEXPORT void JNICALL FN(feed)(JNIEnv *env, jclass cls, jlong h, jbyteArray data)
{
    jsize len = (*env)->GetArrayLength(env, data);
    jbyte *b = (*env)->GetByteArrayElements(env, data, NULL);
    int r = b ? ltls_feed((ltls *)(intptr_t)h, (const uint8_t *)b, (size_t)len) : -1;
    if (b) (*env)->ReleaseByteArrayElements(env, data, b, JNI_ABORT);
    if (r != 0) throw_state(env, "TLS input failed");
}

/* true once complete and verified, false if more data is needed; throws on failure */
JNIEXPORT jboolean JNICALL FN(handshake)(JNIEnv *env, jclass cls, jlong h)
{
    ltls *t = (ltls *)(intptr_t)h;
    int r = ltls_handshake(t);
    if (r < 0) throw_state(env, ltls_error(t));
    return r == 1 ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT jbyteArray JNICALL FN(drain)(JNIEnv *env, jclass cls, jlong h)
{
    ltls *t = (ltls *)(intptr_t)h;
    size_t cap = 4096, len = 0;
    uint8_t *buf = malloc(cap);
    jbyteArray out;
    if (!buf) return NULL;
    for (;;) {
        int n = ltls_drain(t, buf + len, cap - len);
        if (n <= 0) break;
        len += (size_t)n;
        if (len == cap) {
            uint8_t *bigger = realloc(buf, cap * 2);
            if (!bigger) break;
            buf = bigger; cap *= 2;
        }
    }
    out = to_array(env, buf, len);
    free(buf);
    return out;
}

JNIEXPORT void JNICALL FN(write)(JNIEnv *env, jclass cls, jlong h, jbyteArray data)
{
    jsize len = (*env)->GetArrayLength(env, data);
    jbyte *b = (*env)->GetByteArrayElements(env, data, NULL);
    int r = b ? ltls_write((ltls *)(intptr_t)h, (const uint8_t *)b, (size_t)len) : -1;
    if (b) (*env)->ReleaseByteArrayElements(env, data, b, JNI_ABORT);
    if (r != 0) throw_state(env, "TLS write failed");
}

/* one TLS record of application data, or null if none is waiting; throws on failure */
JNIEXPORT jbyteArray JNICALL FN(readRecord)(JNIEnv *env, jclass cls, jlong h)
{
    ltls *t = (ltls *)(intptr_t)h;
    uint8_t *buf = malloc(17408);
    jbyteArray out = NULL;
    int n;
    if (!buf) return NULL;
    n = ltls_read(t, buf, 17408);
    if (n < 0) throw_state(env, ltls_error(t));
    else if (n > 0) out = to_array(env, buf, (size_t)n);
    free(buf);
    return out;
}

JNIEXPORT jbyteArray JNICALL FN(exportKeys)(JNIEnv *env, jclass cls, jlong h, jstring label, jint len)
{
    const char *l = (*env)->GetStringUTFChars(env, label, NULL);
    uint8_t buf[512];
    jbyteArray out = NULL;
    if (l && len > 0 && len <= (jint)sizeof(buf) && ltls_export((ltls *)(intptr_t)h, l, buf, (size_t)len) == 0)
        out = to_array(env, buf, (size_t)len);
    else
        throw_state(env, "key export failed");
    memset(buf, 0, sizeof(buf));
    if (l) (*env)->ReleaseStringUTFChars(env, label, l);
    return out;
}

JNIEXPORT jstring JNICALL FN(describe)(JNIEnv *env, jclass cls, jlong h)
{
    return (*env)->NewStringUTF(env, ltls_describe((ltls *)(intptr_t)h));
}

/* returns tag (16 bytes) followed by ciphertext */
JNIEXPORT jbyteArray JNICALL FN(gcmSeal)(JNIEnv *env, jclass cls, jbyteArray key, jbyteArray nonce, jbyteArray ad, jbyteArray plain)
{
    jsize ad_len = (*env)->GetArrayLength(env, ad), in_len = (*env)->GetArrayLength(env, plain);
    uint8_t k[32], n[12];
    uint8_t *adb, *in, *out;
    jbyteArray result = NULL;
    if ((*env)->GetArrayLength(env, key) != 32 || (*env)->GetArrayLength(env, nonce) != 12) return NULL;
    (*env)->GetByteArrayRegion(env, key, 0, 32, (jbyte *)k);
    (*env)->GetByteArrayRegion(env, nonce, 0, 12, (jbyte *)n);
    adb = malloc((size_t)ad_len + 1); in = malloc((size_t)in_len + 1); out = malloc((size_t)in_len + 17);
    if (adb && in && out) {
        (*env)->GetByteArrayRegion(env, ad, 0, ad_len, (jbyte *)adb);
        (*env)->GetByteArrayRegion(env, plain, 0, in_len, (jbyte *)in);
        if (ltls_gcm_seal(k, n, adb, (size_t)ad_len, in, (size_t)in_len, out + 16, out) == 0)
            result = to_array(env, out, (size_t)in_len + 16);
    }
    memset(k, 0, sizeof(k));
    free(adb); free(in); free(out);
    return result;
}

/* input is tag (16 bytes) followed by ciphertext; null if it does not authenticate */
JNIEXPORT jbyteArray JNICALL FN(gcmOpen)(JNIEnv *env, jclass cls, jbyteArray key, jbyteArray nonce, jbyteArray ad, jbyteArray sealed)
{
    jsize ad_len = (*env)->GetArrayLength(env, ad), in_len = (*env)->GetArrayLength(env, sealed);
    uint8_t k[32], n[12];
    uint8_t *adb, *in, *out;
    jbyteArray result = NULL;
    if ((*env)->GetArrayLength(env, key) != 32 || (*env)->GetArrayLength(env, nonce) != 12 || in_len < 16) return NULL;
    (*env)->GetByteArrayRegion(env, key, 0, 32, (jbyte *)k);
    (*env)->GetByteArrayRegion(env, nonce, 0, 12, (jbyte *)n);
    adb = malloc((size_t)ad_len + 1); in = malloc((size_t)in_len); out = malloc((size_t)in_len);
    if (adb && in && out) {
        (*env)->GetByteArrayRegion(env, ad, 0, ad_len, (jbyte *)adb);
        (*env)->GetByteArrayRegion(env, sealed, 0, in_len, (jbyte *)in);
        if (ltls_gcm_open(k, n, adb, (size_t)ad_len, in + 16, (size_t)in_len - 16, in, out) == 0)
            result = to_array(env, out, (size_t)in_len - 16);
    }
    memset(k, 0, sizeof(k));
    free(adb); free(in); free(out);
    return result;
}

JNIEXPORT jbyteArray JNICALL FN(random)(JNIEnv *env, jclass cls, jint len)
{
    uint8_t buf[256];
    if (len <= 0 || len > (jint)sizeof(buf) || ltls_random(buf, (size_t)len) != 0) { throw_state(env, "no randomness"); return NULL; }
    return to_array(env, buf, (size_t)len);
}
