# Lattice VPN for Mac: App Store submission checklist

Created by Demetris Dangerfield

Status 2026-11-22: code is ready on branch `codex/lattice-mac-build` (commit `f1a729e`). The steps below need the Apple Developer and App Store Connect accounts.

## How the Mac app is set up

- Bundle ID `ai.cloakvpn.CloakVPN`, tunnel extension `ai.cloakvpn.CloakVPN.CloakTunnel`: the same IDs as the iOS app. The Mac app is added as a second platform on the existing App Store record (universal purchase), so the four existing subscription products and one purchase cover iPhone and Mac.
- Team `5HYY2YP2G9` (KryptoKnightz LLC), automatic signing.
- App Sandbox, packet tunnel as an app extension, minimum macOS 26.0.
- Version 1.0, build 1.

## Step 1: provisioning (Apple Developer account)

The App IDs already exist from iOS and already have Network Extension and the App Group. They only need macOS profiles.

Easiest: open `clients/mac/LatticeMac.xcodeproj` in Xcode signed in to the KryptoKnightz team, select each target, open Signing & Capabilities, and let "Automatically manage signing" create the profiles. Command-line equivalent: `xcodebuild ... -allowProvisioningUpdates`.

Check after: both targets show a valid "Mac App Development" profile and no red errors.

## Step 2: test the signed build

1. Run the LatticeMac scheme. Remove the old test VPN configurations in System Settings > VPN first ("LATTICE VPN" from the test build, and "Lattice Normal Test ...").
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

Scheme "LatticeMac-AppStore" > Product > Archive > Distribute App > App Store Connect. Then install the processed build from TestFlight on a Mac and repeat the Step 2 checks before submitting for review.

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

- The app icon is the square iOS artwork scaled down. It is valid, but a Mac-shaped icon would look better in the Dock and Finder.
- No launch-at-login and no auto-connect. Not required for approval.
- The iOS and Android apps still use Rosenpass. Store text for those platforms must not claim ML-KEM-768 until they are updated.
- The Mac app requires macOS 26 or later.
