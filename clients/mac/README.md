# Lattice VPN — macOS client

Native macOS menu-bar app, sharing the post-quantum tunnel core with the iOS app.

## What's in this directory

```
clients/mac/
├── LatticeMac/                       host app (menu bar utility)
│   ├── LatticeMacApp.swift           SwiftUI @main + Settings scene
│   ├── AppDelegate.swift             NSStatusItem + popover lifecycle
│   ├── MenuBar/
│   │   ├── MenuBarController.swift   status-item / popover / context-menu
│   │   ├── ConnectionPopoverView.swift   the dropdown UI
│   │   └── StatusItemIcon.swift      SF Symbol per connection state
│   ├── Settings/
│   │   └── SettingsView.swift        General / Account / Subscription / Advanced
│   ├── ViewModels/
│   │   └── ConnectionViewModel.swift bridges UI <-> TunnelManager
│   └── Resources/
│       ├── Info.plist                LSUIElement, min OS, etc.
│       └── LatticeMac.entitlements   app-sandbox, NetworkExtension, app-group
├── LatticeMacTunnel/                 NEPacketTunnelProvider system extension
│   ├── LatticeMacTunnelProvider.swift thin subclass of shared PTP
│   ├── LatticeMacTunnel-Info.plist
│   └── LatticeMacTunnel.entitlements
├── Scripts/
│   └── notarize.sh                   codesign + notarytool + stapler
└── README.md                         (this file)
```

The shared core (TunnelManager, RosenpassBridge, rosenpassffi, ConfigParser,
Region, AppGroupKeyStore, CloakAuthClient, SubscriptionInfo, RosenpassDriver,
PacketTunnelProvider) lives in `../ios/` and is included in the Mac targets via
**Xcode target membership** — no file duplication.

## One-time Xcode project setup

Phase 1 is just source files. The actual `LatticeMac.xcodeproj` is created
once by hand because the file layout / target topology / signing config is
not worth round-tripping through `xcodegen` for a single project.

**Prerequisites:** Xcode 16+ (for SwiftUI Settings scene + macOS 14 SDK),
active Apple Developer account with the NetworkExtension entitlement
approved on the team. (Once the Kryptoknightz LLC migration completes,
re-request the entitlement under the LLC team ID.)

### 1. Create the project

1. File → New → Project → **macOS → App**
2. Product Name: `LatticeMac`
3. Team: (your active team — personal for now, swap to LLC after migration)
4. Organization Identifier: `ai.latticevpn`
5. Bundle Identifier: `ai.latticevpn.macos` (will auto-derive)
6. Interface: **SwiftUI**, Language: **Swift**
7. Storage: **None**
8. Tests: uncheck (we add a separate test target later)
9. Save to `clients/mac/` (you'll end up with `clients/mac/LatticeMac.xcodeproj` next to this README)

When Xcode creates the project it'll generate `ContentView.swift` + `LatticeMacApp.swift`
+ `Assets.xcassets`. **Delete those** — we have our own versions in `LatticeMac/`.

### 2. Add the source files we've already written

In Xcode's Project Navigator:

1. Right-click the `LatticeMac` group → **Add Files to "LatticeMac"…**
2. Select the `LatticeMac/` folder from this directory
3. Check "Create groups", uncheck "Copy items if needed"
4. Add to target: ✅ LatticeMac

Repeat for the Resources subfolder — the `Info.plist` and `LatticeMac.entitlements`
need to be referenced (not copied) so future edits flow through.

In Build Settings:
- `INFOPLIST_FILE` = `LatticeMac/Resources/Info.plist`
- `CODE_SIGN_ENTITLEMENTS` = `LatticeMac/Resources/LatticeMac.entitlements`

### 3. Add the PTP extension target

1. File → New → Target → **macOS → Network Extension**
2. Product Name: `LatticeMacTunnel`
3. Bundle Identifier: `ai.latticevpn.macos.tunnel`
4. Subclass: `Packet Tunnel Provider`
5. Embed in Application: `LatticeMac`

Xcode will generate a `PacketTunnelProvider.swift`. **Delete it** — we have
`LatticeMacTunnelProvider.swift` in `LatticeMacTunnel/`.

Then add the files from `LatticeMacTunnel/` the same way as step 2, with
target = LatticeMacTunnel.

### 4. Add the shared iOS sources to the Mac targets

This is the step that makes the port a port instead of a rewrite.

For each of these files in `../ios/CloakVPN/`:
- `TunnelManager.swift`
- `AppGroupKeyStore.swift`
- `CloakAuthClient.swift`
- `ConfigParser.swift`
- `Region.swift`
- `RosenpassBridge.swift`
- `rosenpassffi.swift`
- `SubscriptionInfo.swift`

In Xcode → File Inspector (right panel) → **Target Membership** → check ✅ LatticeMac.

For these files in `../ios/CloakTunnel/`:
- `PacketTunnelProvider.swift`
- `RosenpassDriver.swift`

Check ✅ LatticeMacTunnel.

For `../ios/RosenpassFFI.xcframework` (the Rust static lib):
- Add to Frameworks, Libraries, and Embedded Content of both Mac targets
- "Embed & Sign" for the app, "Do Not Embed" for the extension (extensions can't embed)

### 5. Capabilities

On the **LatticeMac** target → Signing & Capabilities tab:
- ✅ App Sandbox  (network: outgoing connections)
- ✅ Network Extensions  (packet-tunnel-provider)
- ✅ App Groups  (group.ai.latticevpn.shared)
- ✅ Keychain Sharing  ($(AppIdentifierPrefix)ai.latticevpn.shared)

Same four on the **LatticeMacTunnel** target.

### 6. Build configurations (App Store vs Direct Download)

Project → Info → Configurations: duplicate `Release` twice and rename to
`Release-AppStore` and `Release-DirectDownload`.

In Build Settings → **Other Swift Flags** for each Mac target:
- Release-AppStore: add `-DAPPSTORE_BUILD`
- Release-DirectDownload: add `-DDIRECT_DOWNLOAD_BUILD`

Several files (`SubscriptionSettingsView`, `LatticeMacTunnelProvider`) already
branch on these — App Store builds use StoreKit, Direct Download builds use
license keys + diagnostic log flush.

In Signing & Capabilities for the LatticeMac target:
- Release-AppStore: signing certificate = "Mac App Distribution"
- Release-DirectDownload: signing certificate = "Developer ID Application"

### 7. First run

Cmd-R should now build and launch. You'll see:
- No Dock icon (correct — LSUIElement)
- A shield icon in the menu bar (top-right)
- Clicking it: popover with mock connection state, region list, primary action button

Connect/disconnect cycles work against the mock state. Real tunnel wiring
happens in Phase 3 (see `ConnectionViewModel.swift` — every `TODO[Phase 3]`
comment is an integration point).

## Distribution (after Apple LLC migration completes)

### Mac App Store

1. Product → Archive
2. Window → Organizer → select archive → Distribute App → App Store Connect
3. Upload, then submit via App Store Connect web UI

### Direct Download

1. Product → Archive with `Release-DirectDownload` scheme
2. Export with Developer ID signing
3. Run `Scripts/notarize.sh path/to/LatticeMac.app`
4. The script staples the notarization ticket and produces a `.dmg`
   ready to host at `https://latticevpn.ai/download/latticemac.dmg`

Notarization requires app-specific password stored in the keychain:
```
xcrun notarytool store-credentials latticevpn-notary \
    --apple-id demetris@neuroaistudios.com \
    --team-id <TEAM_ID> \
    --password <APP_SPECIFIC_PASSWORD>
```

## Implementation phases

- [x] **Phase 1** — scaffold (this PR): directory tree, source files, plists, entitlements, README
- [ ] **Phase 2** — menu bar app skeleton runs with mock state (mostly done in Phase 1; needs Xcode project)
- [ ] **Phase 3** — wire ConnectionViewModel to TunnelManager + real NetworkExtension
- [ ] **Phase 4** — fill in Settings tabs (account sign-in, real subscription, kill switch)
- [ ] **Phase 5** — dual distribution config + notarize script tested end-to-end
- [ ] **Phase 6** — Mac AppIcon, launch-at-login (SMAppService), App Store screenshots, metadata, submit

Estimated total: 2-3 weeks of focused work. Bottleneck for shipping is the
LLC developer account migration (signing + entitlements).
