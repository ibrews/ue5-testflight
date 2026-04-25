# ue5-testflight

Fully autonomous UE5 → TestFlight pipeline for **iOS** and **visionOS**. One command triggers build → sign → upload → distribute. No manual steps.

```bash
launchctl start com.yourcompany.iosbuild
# 30–60 min later: build is live in TestFlight, internal + external groups notified
```

## What It Does

| Step | iOS | visionOS |
|------|-----|----------|
| Cook + stage via RunUAT | ✓ | ✓ |
| Patch Info.plist (bundle ID, build number, privacy strings) | ✓ | ✓ |
| Auto-increment CFBundleVersion | ✓ | ✓ |
| Extract entitlements from provisioning profile | ✓ | ✓ |
| Generate 3-layer `.solidimagestack` icon (Apple requirement) | — | ✓ |
| Re-sign with CI keychain (no UI dialog) | ✓ | ✓ |
| Pack IPA | ✓ | ✓ |
| Upload via `xcrun altool` | ✓ | ✓ |
| Poll ASC until VALID | ✓ | ✓ |
| Attach to external TestFlight group | ✓ | ✓ |

## Requirements

- macOS build machine with Xcode command-line tools
- Unreal Engine 5 installed (tested on UE 5.7)
- Homebrew Python 3 with `cryptography` and `pillow`:
  ```bash
  /opt/homebrew/bin/pip3 install cryptography pillow
  ```
- App Store Connect API key (`.p8` file + Key ID + Issuer ID)
- iOS Distribution certificate in a CI keychain (to sign without UI prompt)
- App Store provisioning profile (`.mobileprovision`)

## Setup

**1. Clone and configure**

```bash
git clone https://github.com/ibrews/ue5-testflight
cd ue5-testflight
cp ue5kit.conf.template ue5kit.conf
# Edit ue5kit.conf — fill in your project paths, bundle ID, certs, and ASC credentials
```

**2. Set up CI keychain** (skip if using login keychain — but login keychain requires a GUI session)

```bash
# Create a dedicated keychain so codesign works from LaunchAgents (no UI prompt)
security create-keychain -p "your-password" ~/Library/Keychains/ue5-ci.keychain-db
security import YourDistCert.p12 -k ~/Library/Keychains/ue5-ci.keychain-db -P "" -T /usr/bin/codesign
security set-key-partition-list -S "apple-tool:,apple:,codesign:" -s -k "your-password" ~/Library/Keychains/ue5-ci.keychain-db
```

Update `CI_KEYCHAIN_PATH` and `CI_KEYCHAIN_PASS` in `ue5kit.conf`.

**3. Add visionOS config to your UE5 project** (required, or app crashes after splash screen)

```bash
mkdir -p YourProject/Config/VisionOS
cp ue5-config/VisionOS/*.ini YourProject/Config/VisionOS/
```

**4. Set iOS fps cap settings in your UE5 project**

In `Config/DefaultEngine.ini` under `[/Script/IOSRuntimeSettings.IOSRuntimeSettings]`:
```ini
FrameRateLock=PUFRL_None
```

Copy `ue5-config/DefaultDeviceProfiles.ini` content into `Config/DefaultDeviceProfiles.ini`.

**5. Run setup**

```bash
bash setup.sh
```

This validates config, checks prerequisites, and installs the four LaunchAgents.

## Usage

```bash
# Trigger full pipeline
launchctl start com.yourcompany.iosbuild       # or your $ORG_LABEL
launchctl start com.yourcompany.visionosbuild

# Monitor
tail -f /tmp/ue5kit-ios-build.log
tail -f /tmp/ue5kit-ship-ios.log

# Ship only (build already staged)
launchctl start com.yourcompany.shipios
launchctl start com.yourcompany.shipvisionos

# Manual external group attach (if ASC poll timed out)
python3 scripts/attach_to_group.py ios
python3 scripts/attach_to_group.py visionos
```

## Hard-Won Gotchas

**Never run `codesign` directly over SSH.** macOS blocks keychain access from SSH sessions. Always use `launchctl start` (runs in GUI session context). `security find-identity -v` always returns 0 identities over SSH even if certs are present — this is expected and not an error.

**UE5 ignores `BundleIdentifier` in DefaultEngine.ini for iOS.** The xcconfig file hardcodes the bundle ID as `$(UE_SIGNING_PREFIX).$(UE_PRODUCT_NAME_STRIPPED)`. The ship scripts patch `CFBundleIdentifier` in the staged `.app/Info.plist` post-build.

**30fps iOS default requires two separate fixes.** `FrameRateLock=PUFRL_None` in `DefaultEngine.ini` handles the UE5-level cap. The `DefaultDeviceProfiles.ini` CVars handle the render-level cap. Neither alone is sufficient.

**visionOS crashes after splash** without `Config/VisionOS/VisionOSEngine.ini` and `VisionOSDeviceProfiles.ini`. The minimum required settings are `vr.InstancedStereo=False`, `vr.MobileMultiView=False`, and `xr.OpenXRAcquireMode=1`.

**visionOS icon must be a `.solidimagestack`.** Apple rejects with ITMS-90970 without one. The `gen_visionos_icon.py` script generates a minimal placeholder and compiles it with `xcrun actool`. The `CFBundlePrimaryIcon` Info.plist value must be a **string** — not a dict (ITMS-90039 if dict).

**visionOS ASC processing takes 30–60 min** (vs 5–10 min for iOS). The poll script will time out. Run `attach_to_group.py visionos` manually once the build is VALID.

**UE5 allows only one RunUAT at a time.** Don't trigger iOS and visionOS builds simultaneously — the second one exits immediately with an AutomationTool mutex error.

**iOS builds run on Apple Vision Pro** via the iOS compatibility layer. You don't need a separate visionOS build to test on the headset.

## ASC Setup Notes

- Create an App Store Connect API key at Users & Access → Keys. Download the `.p8` — it cannot be re-downloaded.
- Create an "Internal" beta group with `hasAccessToAllBuilds = true` — no per-build attachment needed.
- Create an "External" beta group — the ship scripts attach each build explicitly after it reaches VALID.
- For the external group UUID, check the ASC URL when viewing the group, or via the API: `GET /v1/betaGroups?filter[app]=YOUR_APP_ID`.

## File Structure

```
ue5-testflight/
├── ue5kit.conf.template     # copy to ue5kit.conf and fill in
├── setup.sh                 # validates config + installs LaunchAgents
├── SKILL.md                 # Claude Code skill (load via skills.sh)
├── scripts/
│   ├── run_ios_build.sh     # UE5 cook+stage for iOS → auto-triggers ship
│   ├── run_visionos_build.sh
│   ├── ship_ios.sh          # resign → repack → upload → distribute
│   ├── ship_visionos.sh
│   ├── gen_entitlements.py  # extract entitlements from .mobileprovision
│   ├── gen_visionos_icon.py # generate .solidimagestack icon + compile with actool
│   └── attach_to_group.py  # poll ASC for VALID + attach to external group
└── ue5-config/
    ├── VisionOS/
    │   ├── VisionOSEngine.ini        # copy to your project Config/VisionOS/
    │   └── VisionOSDeviceProfiles.ini
    └── DefaultDeviceProfiles.ini     # iOS fps cap settings
```
