# Cloak VPN — iOS client

SwiftUI app + `NEPacketTunnelProvider` app extension using Apple's WireGuardKit.

## Prereqs

- Xcode 15+ on macOS
- Apple Developer Program account ($99/yr)
- A device (NetworkExtension does not work in the simulator)

## Project layout

```
clients/ios/
  CloakVPN/           # Main SwiftUI app target
    CloakVPNApp.swift
    ContentView.swift
    TunnelManager.swift   # Wraps NETunnelProviderManager
    ConfigParser.swift    # Parses the config block produced by the server
    RosenpassBridge.swift # PQC-key-exchange bridge (FFI into rosenpass-go or Rust)
  CloakTunnel/        # NEPacketTunnelProvider extension target
    PacketTunnelProvider.swift
    Info.plist
  CloakVPN.xcodeproj  # (to be generated — see "Creating the Xcode project")
```

## Creating the Xcode project

1. In Xcode: **File → New → Project… → iOS → App**. Name it `CloakVPN`, Team = your dev team, Bundle ID = `com.cloakvpn.app`, Interface = SwiftUI, Language = Swift.
2. Save it at `clients/ios/` (this folder), so `CloakVPN.xcodeproj` sits next to the source folders.
3. **File → New → Target… → iOS → Network Extension**. Name it `CloakTunnel`, Bundle ID `com.cloakvpn.app.tunnel`. Set "Providing" = **Packet Tunnel**.
4. In both targets' **Signing & Capabilities**:
   - Add **App Groups** capability. Create one group: `group.com.cloakvpn.app`.
   - Add **Network Extensions** → **Packet Tunnel**.
   - (Main app only) Add **Personal VPN**.
5. Replace the generated `ContentView.swift`, `CloakVPNApp.swift`, `PacketTunnelProvider.swift` with the files committed in this folder.
6. Add **WireGuardKit** via Swift Package Manager:
   - **File → Add Package Dependencies…** → `https://git.zx2c4.com/wireguard-apple` → select `WireGuardKit`.
   - Add it to **both** targets (app and extension).

## Running

- Select your device as the run destination.
- **Build & Run** the `CloakVPN` scheme.
- Paste a config block (produced by the server's `setup.sh` / `add-peer.sh`) into the import screen.
- Tap **Connect**. iOS will prompt for VPN permission once.

## Known limits in the skeleton

- `RosenpassBridge` is stubbed. The production build will embed the Rust `rosenpass` crate built for iOS (`aarch64-apple-ios`) via `cargo-lipo` or XCFramework, exposing an `extern "C"` `rosenpass_exchange()` call.
- The tunnel extension will invoke Rosenpass out-of-band and write the rotated PSK into a shared App Group file, which the WireGuardKit config reloads on each handshake.
- The UI is intentionally minimal — one "Connect" button and a config paste field. Polish comes in Phase 1.

## NetworkExtension gotchas

- **Packet-tunnel extensions have a 15MB memory budget.** Keep the Rosenpass FFI slim; prefer doing the PQC exchange in the main app and handing the PSK to the extension via the shared app group.
- `NETunnelProviderProtocol.providerConfiguration` is a `[String: Any]` that's persisted; use it for non-secret metadata. Secrets (private keys) go in the Keychain with `kSecAttrAccessGroup = "group.com.cloakvpn.app"`.
- Always-on VPN is a managed-device feature (requires MDM). For consumer use, the user taps "Connect" or toggles the system VPN.
