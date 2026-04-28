# Cloak VPN — App Store Screenshot Guide

App Store requires at minimum:
- 6.7" iPhone (1290 × 2796 px) — covers iPhone 15/16 Pro Max generations
- 6.5" iPhone (1284 × 2778 px) — covers iPhone XS Max / 11 Pro Max / 14 Plus

Optional but recommended:
- 5.5" iPhone (1242 × 2208 px)
- 12.9" iPad Pro (2048 × 2732 px) if you ever ship an iPad-optimized build

You need **at least one** screenshot per declared device size. App Store will up-rez 6.7" screenshots for smaller devices automatically, but it's better to provide native sizes when possible (the auto-scaled output is noticeably softer).

## Capture flow on your iPhone 16 Pro Max (6.7")

1. Plug iPhone into Mac.
2. Open the Cloak VPN app, set up the desired state for each shot.
3. Press **Side button + Volume Up** simultaneously to take a screenshot — saved to Photos at native resolution (1290 × 2796).
4. AirDrop the screenshots to your Mac.
5. Drop them into App Store Connect → App Store tab → 6.7" Display gallery.

## Recommended shot list (5 screenshots minimum)

### 1. Hero — Connected state
**State:** Connected to a region, IP panel showing your home IP → VPN IP.
**Caption (overlaid, optional):** "Quantum-resistant VPN. One tap to connect."

Set up:
- App is connected (green status badge)
- A region selected (preferably US-W or DE — visually clean flag)
- IP panel shows both addresses populated
- PQC indicator shows "PQC: N rotations ✓"

### 2. Region picker
**State:** Disconnected, QUICK CONNECT strip visible with all 4 flags highlighted.
**Caption (optional):** "4 regions worldwide. Switch in one tap."

Set up:
- Disconnected
- All 4 region flags visible in the QUICK CONNECT strip
- Optionally select one to show the green ring

### 3. Settings drawer (PIA-style)
**State:** Hamburger menu open showing the settings sheet.
**Caption (optional):** "Account, settings, privacy — one menu."

Set up:
- Tap the hamburger icon top-left
- Capture the slide-up sheet showing the account header + nav rows

### 4. Pro tier app icon
**State:** iOS home screen showing the gold-ringed Pro app icon.
**Caption (optional):** "Pro subscribers get the gold mark."

Set up:
- Switch to Pro tier in app (Account → Plan preview → Pro)
- Wait for iOS to re-render the home screen icon
- Take a home-screen screenshot showing the gold-ringed icon next to other apps

### 5. Privacy posture
**State:** A screenshot of ipleak.net or a similar site showing no leak.
**Caption (optional):** "Strict no-logs. No IP leaks. No DNS leaks."

Set up:
- Connect to a region (e.g., Germany)
- Open Safari → ipleak.net
- Screenshot the "Your IP addresses" panel showing the German IP (and DNS routed through Quad9)

## Optional bonus shots (6th-10th if you want a richer gallery)

- **6.** Account → Plan preview screen (showing Basic/Pro picker)
- **7.** PQC diagnostics (Settings → Advanced → PQC diagnostics)
- **8.** Add region custom URL flow
- **9.** Connection in progress (the "Connecting…" state with spinner)
- **10.** Reset tunnel confirmation alert (shows the safety net for power users)

## Screenshot frame template (optional polish)

If you want the screenshots to look more polished in the App Store:
- Add a 1-line caption above the screenshot (Apple's preview UI shows the caption next to the image)
- Optionally place the screenshot inside a device frame mockup (e.g., via shotbot.app or screenshots.pro)

For first launch, raw screenshots are fine — Apple does NOT require fancy frames.

## File naming convention (suggested)

```
01-hero-connected.png
02-region-picker.png
03-settings-drawer.png
04-pro-icon.png
05-no-leak.png
```

Sequential numbering matches the order they'll appear in the App Store
listing.

## Localization

Screenshots can have per-locale variants. For English (US) launch, just
upload the 5 above. Add other locales when localization ships.
