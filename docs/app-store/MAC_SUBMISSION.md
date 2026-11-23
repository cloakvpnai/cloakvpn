# Lattice VPN for Mac: App Store submission checklist

Created by Demetris Dangerfield

Status 2026-11-22 22:00 HST: code is on branch `codex/lattice-mac-build` (commit `969e42a`). Provisioning is done, the release archive builds, and a distribution-signed package exists. Remaining: test the signed build (Step 2), App Store Connect setup (Step 3), upload (Step 4).

## How the Mac app is set up

- Bundle ID `ai.cloakvpn.CloakVPN`, tunnel extension `ai.cloakvpn.CloakVPN.CloakTunnel`: the same IDs as the iOS app. The Mac app is added as a second platform on the existing App Store record (universal purchase), so the four existing subscription products and one purchase cover iPhone and Mac.
- Team `5HYY2YP2G9` (KryptoKnightz LLC), automatic signing.
- App Sandbox, packet tunnel as an app extension, minimum macOS 26.0, Apple silicon only (arm64).
- Shows in the Dock and the menu bar. Clicking the Dock icon opens the Lattice window.
- Version 1.0, build 1.

## Step 1: provisioning (done 2026-11-22)

Xcode automatic signing created the Mac profiles for both existing App IDs:

- Development: used by the build installed at `/Applications/LatticeMac.app`.
- Distribution: "Mac Team Store Provisioning Profile" for `ai.cloakvpn.CloakVPN` and `ai.cloakvpn.CloakVPN.CloakTunnel`, cloud-managed Apple Distribution certificate, and a "3rd Party Mac Developer Installer: KryptoKnightz LLC" certificate (expires 2027-11-23).

## Step 2: test the signed build

1. Open `/Applications/LatticeMac.app`. Remove the old test VPN configurations in System Settings > VPN first ("LATTICE VPN" from the test build, and "Lattice Normal Test ...").
2. Subscription tab: plans load with prices; Restore Purchases finds an existing Apple subscription and signs in; a sandbox purchase completes.
3. Menu bar: Connect to at least two regions, confirm Exit IP changes, Disconnect, sleep and wake, reconnect.

## Step 3: App Store Connect

1. Open the Lattice app > add platform > macOS.
2. Confirm the subscription group and the four products are attached to the macOS version (In-App Purchases and Subscriptions section of the version page).
3. Screenshots, Mac sizes: 1280x800, 1440x900, 2560x1600 or 2880x1800. At least one; three recommended (menu bar panel connected, region list, Subscription tab).
4. Description: reuse the iOS text with these changes for Mac:
   - Replace the Rosenpass sentence with: "Lattice combines WireGuard with an ML-KEM-768 post-quantum key exchange (NIST FIPS 203). The key that protects your tunnel is negotiated fresh each time your Mac connects."
   - Replace "iOS keeps enforcement active even while reconnecting, over Wi-Fi and cellular alike" with "all traffic is routed through the tunnel while you are connected".
   - Remove the "exclusive Pro app icon" claim unless the Mac app offers it (it does not today).
5. App Privacy: same answers as iOS (device ID for app functionality, not linked; purchase history linked, for app functionality; no tracking).
6. Export compliance: answer the encryption questions the same way as the iOS builds.
7. Age rating, category (Utilities), copyright: same as iOS.

## Step 4: archive and upload

Archive and export already work from the command line:

```
cd clients/mac
xcodebuild archive -scheme LatticeMac-AppStore -destination 'generic/platform=macOS' \
  -archivePath ~/Library/Developer/Xcode/Archives/2026-11-22/LatticeMac-1.0-1.xcarchive -allowProvisioningUpdates
xcodebuild -exportArchive -archivePath <that archive> -exportOptionsPlist <method app-store-connect> \
  -exportPath <folder> -allowProvisioningUpdates
```

- Archive: `~/Library/Developer/Xcode/Archives/2026-11-22/LatticeMac-1.0-1.xcarchive` (also visible in Xcode > Window > Organizer).
- Signed package: `Mac App Store Build/LatticeMac-1.0-build1.pkg` in the project folder.
- Upload after Step 3.1 (the macOS platform must exist on the app record): Organizer > Distribute App > App Store Connect, or the Transporter app with the package.
- Then install the processed build from TestFlight on a Mac and repeat the Step 2 checks before submitting for review.
- Any code change after this needs a new archive with a higher build number.

Build notes: scheme names must not contain spaces or parentheses (the WireGuardKitGo Makefile breaks on the archive path), and the archive is arm64 only.

## App Review notes for the macOS version

```
Lattice VPN for Mac is a menu bar app. After launch, a Lattice window opens and a shield icon appears in the menu bar at the top right of the screen. Click the shield icon to choose a region and connect.

Sign-in: Lattice uses an account number instead of an email and password.
1. In the Lattice window, open the Account tab.
2. Enter this account number: [ACCOUNT NUMBER]
3. Click the shield icon in the menu bar, pick any region, and click Connect.
4. macOS asks for permission to add a VPN configuration. Click Allow.

Subscriptions are sold through in-app purchase on the Subscription tab (the same auto-renewable subscriptions as the iOS app, shared through universal purchase). Restore Purchases is on the same tab.

The VPN uses Apple's NetworkExtension framework (Packet Tunnel Provider, packaged as an app extension) per Guideline 5.4. The developer is an organization account (KryptoKnightz LLC). No user activity is logged; see https://latticevpn.ai/privacy.
```

Keep the real account number out of git. Paste it into App Store Connect only.

## Known gaps to decide before submitting

- Intel Macs are not supported (arm64 only).
- No launch-at-login and no auto-connect. Not required for approval.
- The iOS and Android apps still use Rosenpass. Store text for those platforms must not claim ML-KEM-768 until they are updated.
- The Mac app requires macOS 26 or later.
