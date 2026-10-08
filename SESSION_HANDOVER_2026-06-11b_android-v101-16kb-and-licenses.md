# Session Handover — 2026-06-11b — Android v1.0.1: 16 KB fix + licenses screen + PQC first-handshake fix

Follows `SESSION_HANDOVER_2026-06-11_android-LIVE-and-ios-build-109.md`.

## Headline: Android v1.0.1 (versionCode=3) is built, signed, and verified
Both carried Android items are done in one release:

### 1. Open-source licenses screen (parity with iOS build 109)
- `assets/ThirdPartyNotices.txt` — same 13.7 KB notices file as iOS
  (WireGuard, Rosenpass, liboqs + full MIT/Apache-2.0 texts).
- New `LicensesScreen.kt` (monospace scrollable text, loads the asset off
  the main thread, no external links — same constraints as the iOS one).
- Wired in: `Screen.LICENSES` enum case, `LatticeApp` route, and a
  Settings → About → "Open-source licenses" row.
- Verified in the built AAB: asset present, screen strings in the dex.

### 2. 16 KB page-size fix — root cause was THIRD-PARTY libs
Our own libs (`librosenpassffi.so`, `libwg-go.so`) were **already**
16 KB-aligned in v1.0.0. The shipped AAB's offenders were:
- `libjnidispatch.so` (JNA 5.14.0, x86_64 was 0x1000) → **bumped JNA to
  5.17.0@aar**, the first release built with 16 KB alignment (JNA
  issues #1618/#1647). Don't downgrade below 5.17.0.
- `libwg.so` + `libwg-quick.so` (wireguard-android tunnel AAR, 0x1000,
  no fixed upstream release) → **excluded from packaging**
  (`jniLibs.excludes`). Safe: they serve only the root-mode
  `WgQuickBackend`/`ToolsInstaller` path; this app uses `GoBackend`
  exclusively (grep-verified, no references).

**Verified in the final AAB:** every `.so` in both ABIs now shows LOAD
align `0x4000` (`readelf -lW`), wg/wg-quick gone, versionCode=3 /
versionName=1.0.1 in manifest + output-metadata, APK Sig Block v2/v3
present (release-signed). `testReleaseUnitTest` passes (no test sources).

### 3. PQC "times out in first 8 seconds" on fresh connect — DIAGNOSED + FIXED
User repro on the live Play-store build: connect → PQC shows a timeout for
~8–10 s → eventually establishes with 1 rotation.

**Diagnosis (live, us-west-1 journal + fleet check):**
- Fleet is HEALTHY: `cloak-rpd` active on all 4 boxes, NRestarts=0, control
  sockets present. NOT the legacy restart-on-provision problem.
- The user's peer (`peer-7bc7a25d3e97`) shows the smoking gun: first connect
  (07:20 UTC provisions) took ~60 s to land exchange #1, AND steady-state
  rotations intermittently stall — one `stale → exchanged` gap of 3.5 min
  (07:35:08 → 07:38:39) ≈ 5–6 consecutive failed attempts.
- **Root cause (client):** `RosenpassRotator.singleHandshake` sent each
  handshake message exactly ONCE, then blocked 8 s (`RECEIVE_TIMEOUT_SEC`)
  with NO retransmission. One lost UDP datagram = whole attempt fails
  (8 s + exponential backoff). Stock rosenpass retransmits within the
  exchange; our single-shot loop didn't.

**Fixes (in v1.0.1):**
- Retransmit-within-the-exchange: inbound waits sliced into 2 s windows
  (`RETRANSMIT_INTERVAL_SEC`); each quiet slice retransmits the last
  outbound message (InitHello/InitConf, idempotent responder-side) up to a
  12 s per-attempt deadline (`HANDSHAKE_DEADLINE_SEC`). A single lost
  packet now costs ~2 s instead of ~10 s.
- Convergence-grace UI: while rotations == 0, a failed attempt keeps status
  "Handshaking" instead of flashing "Error: …" (Android analogue of the iOS
  NE convergence-grace). `_consecutiveFailures` still increments, so the
  TunnelManager watchdog is unchanged.

**Open question (carried):** WHY packets drop on this path at all
(consumer-Wi-Fi loss, Wi-Fi power-save on idle phone, Hawaii→Hillsboro
path). The retransmit fix makes the client robust either way. If stalls
persist, run the tcpdump split from the 05-30 handover during a repro.
**Also check iOS:** does `RosenpassDriver` retransmit within an exchange,
or does it have the same single-send flaw?

## Artifacts
- AAB: `clients/android/app/build/outputs/bundle/release/app-release.aab` (11.0 MB)
- APK: `clients/android/app/build/outputs/apk/release/app-release.apk`
- Build scripts added: `clients/android/Scripts/build-v101.sh`,
  `Scripts/run-tests.sh` (run on the Mac; gradle logs to
  `build_v101.log` / `test_run.log`).

## NEXT STEPS (user)
1. **Play Console:** upload the v1.0.1 AAB as an update (production or a
   quick closed-testing pass first). This should clear the "available for
   some of your devices" 16 KB caveat once live.
2. **App Store:** unchanged from last session — upload iOS **Build 109**,
   attach the 4 IAPs, submit (109 > 108 > 107).
3. Optional QA before upload: install `app-release.apk` on a device and
   eyeball Settings → About → Open-source licenses. The screen compiled
   and is verified present in the bundle but has not been visually
   smoke-tested on a device this session.

## Gotchas this session
- Backgrounded `do shell script` osascript calls can report "Command
  failed" while the nohup'd gradle **still launches** — two "failed"
  attempts + one success ran 3 concurrent daemons. Final artifacts were
  rebuilt cleanly afterward and verified consistent (full up-to-date run).
  Prefer the `Scripts/build-v101.sh` wrapper.
- AGP 8.5.2 warns it's untested with compileSdk 35 — pre-existing,
  cosmetic. Future item: bump AGP (8.7+) which also auto-handles 16 KB
  zip alignment changes.

## Still open (carried)
- iOS PQC re-provision loop (recovery re-provisions on region switch).
- iOS account recovery via iCloud Keychain (IAP restore across reinstalls).
- PLAY_STORE.md partly stale; `Comparison.astro` dead code on website.
