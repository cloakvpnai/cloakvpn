/* SPDX-License-Identifier: Apache-2.0
 *
 * Lattice VPN addition to wireguard-android's libwg-go.
 *
 * JNI wrapper for the wgSetConfig entry point declared in api-uapi.go.
 * Mirrors the wrappers in the upstream jni.c exactly, but binds to
 * ai.latticevpn.android.vpn.WgUapi instead of GoBackend (which is a
 * sealed class inside the wireguard-android AAR that we cannot extend).
 *
 * Dropped into tunnel/tools/libwg-go/ by build-libwg-go-android.sh and
 * compiled by cgo alongside the upstream jni.c.
 */

#include <jni.h>
#include <stddef.h>

/* Layout of a Go string as seen by a cgo //export function. */
struct go_string { const char *str; long n; };

extern int wgSetConfig(struct go_string settings);

JNIEXPORT jint JNICALL
Java_ai_latticevpn_android_vpn_WgUapi_wgSetConfig(JNIEnv *env, jclass c, jstring settings)
{
	const char *settings_str = (*env)->GetStringUTFChars(env, settings, 0);
	size_t settings_len = (*env)->GetStringUTFLength(env, settings);
	int ret = wgSetConfig((struct go_string){
		.str = settings_str,
		.n = settings_len
	});
	(*env)->ReleaseStringUTFChars(env, settings, settings_str);
	return ret;
}
