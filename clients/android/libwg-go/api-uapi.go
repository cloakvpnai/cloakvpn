/* SPDX-License-Identifier: Apache-2.0
 *
 * Lattice VPN addition to wireguard-android's libwg-go.
 *
 * Adds a single entry point, wgSetConfig, that applies a WireGuard UAPI
 * "set" payload to the *running* tunnel in place — via device.IpcSet —
 * with no interface teardown. The Rosenpass rotation loop uses this to
 * install a freshly derived preshared key every ~2 minutes seamlessly,
 * instead of bouncing the tunnel (which the stock library forces,
 * because GoBackend exposes no live-reconfigure path).
 *
 * This file is dropped into a checkout of wireguard-android's
 * tunnel/tools/libwg-go/ by Scripts/build-libwg-go-android.sh and
 * compiled as part of the same `package main` as api-android.go. It
 * relies only on that file's `tunnelHandles` map and the long-stable
 * device.Device.IpcSet API.
 */

package main

import "C"

// wgSetConfig applies `settings` — WireGuard UAPI "set" lines in
// key=value form, WITHOUT a leading "set=1" — to the single running
// tunnel, in place. The peer's endpoint, allowed-IPs and live handshake
// state are left untouched; only the supplied fields change. The new
// preshared key is picked up by the next routine WireGuard rekey.
//
// GoBackend permits only one userspace tunnel at a time, so the
// tunnelHandles map holds at most one entry and "the current tunnel" is
// unambiguous — no handle argument is needed from the Java side.
//
// Returns:
//
//	 0  success
//	-1  no tunnel is currently running
//	-2  device.IpcSet rejected the payload
//
//export wgSetConfig
func wgSetConfig(settings string) int32 {
	for _, handle := range tunnelHandles {
		if err := handle.device.IpcSet(settings); err != nil {
			return -2
		}
		return 0
	}
	return -1
}
