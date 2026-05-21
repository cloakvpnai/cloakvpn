package ai.latticevpn.android.vpn

/**
 * Applies a freshly derived 32-byte Rosenpass PSK to the running
 * WireGuard tunnel.
 *
 * This is the seam between the post-quantum rotation loop
 * ([RosenpassRotator]) and the WireGuard backend. It is an interface on
 * purpose: there are two ways to push a PSK into a live tunnel on
 * Android, with very different quality, and isolating the choice here
 * keeps the rotation loop unaware of which one is in effect.
 *
 * ### 1. [ReconfiguringPskApplicator] — works on the stock library today
 *
 * wireguard-android's `GoBackend` exposes no live-reconfigure call.
 * `setState(UP)` on an already-up tunnel internally tears the tunnel
 * down and brings it back up. So the only way to change the PSK with the
 * stock `com.wireguard.android:tunnel` artifact is to rebuild the
 * `Config` with the new `PresharedKey` and re-issue it — accepting a
 * brief reconnect each rotation. This is the implementation wired in
 * this phase.
 *
 * ### 2. UAPI `set` — seamless rotation (recommended follow-up)
 *
 * wireguard-go (which `GoBackend` embeds) supports an in-place
 * `IpcSet("public_key=…\npreshared_key=…")` that updates a peer's PSK
 * with no interface teardown — the next routine WireGuard rekey (every
 * ~120 s anyway) simply picks up the new PSK. This is exactly how the
 * iOS client rotates without disruption.
 *
 * The stock Android library does not surface this: its libwg-go exports
 * `wgTurnOn` / `wgTurnOff` / `wgGetConfig` but no `wgSetConfig`, and the
 * UAPI socket `libwg-go` tries to open lands under `/var/run/wireguard`,
 * which is not writable in the app sandbox. Closing this gap is a small,
 * well-bounded native change — add a `wgSetConfig(handle, settings)`
 * export that calls `device.IpcSet(settings)`, plus the matching JNI
 * declaration — after which a `UapiPskApplicator` can drop in here with
 * no change to [RosenpassRotator]. See the Android README follow-up note.
 */
interface PskApplicator {
    /**
     * Apply [psk] (exactly 32 bytes) to the tunnel. Suspends until the
     * change has been handed to the backend. Implementations should
     * treat "tunnel not currently up" as a no-op rather than an error —
     * the PSK is still recorded and takes effect on the next connect.
     *
     * @throws IllegalArgumentException if [psk] is not 32 bytes.
     */
    suspend fun apply(psk: ByteArray)
}

/**
 * The stock-library [PskApplicator]: hands the new PSK to
 * [TunnelRepository], which rebuilds the WireGuard `Config` and
 * re-issues it via `GoBackend`.
 *
 * Trade-off: because `GoBackend.setState(UP)` bounces the tunnel, each
 * rotation causes a short reconnect (sub-second to ~2 s). TCP flows
 * generally survive it via retransmission, but it is perceptible. It is
 * the honest best available without the native `wgSetConfig` addition
 * documented on [PskApplicator]; swap in a UAPI-based applicator there
 * for seamless rotation.
 */
class ReconfiguringPskApplicator(
    private val repository: TunnelRepository,
) : PskApplicator {

    override suspend fun apply(psk: ByteArray) {
        require(psk.size == 32) { "Rosenpass PSK must be 32 bytes, got ${psk.size}" }
        repository.applyPresharedKey(psk)
    }
}
