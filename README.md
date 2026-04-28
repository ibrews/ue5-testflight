# ue5-testflight

Fully autonomous UE5 → TestFlight pipeline for **iOS**, **visionOS**, and **macOS**. One command triggers build → sign → upload → distribute. No manual steps.

```bash
launchctl start com.yourcompany.iosbuild
# 30–60 min later: build is live in TestFlight, internal + external groups notified
```

## What It Does

| Step | iOS | visionOS | macOS |
|------|-----|----------|-------|
| Cook + stage via RunUAT | ✓ | ✓ | ✓ |
| Patch Info.plist (bundle ID, build number, privacy strings) | ✓ | ✓ | ✓ |
| Auto-increment CFBundleVersion (tracked file, no gaps) | ✓ | ✓ | ✓ |
| Extract entitlements from provisioning profile | ✓ | ✓ | ✓ |
| Generate 3-layer `.solidimagestack` icon (Apple requirement) | — | ✓ | — |
| Re-sign with CI keychain (no UI dialog) | ✓ | ✓ | ✓ |
| Pack IPA / zip .app | ✓ | ✓ | ✓ |
| Upload via `xcrun altool` | ✓ | ✓ | ✓ |
| Poll ASC until VALID | ✓ | ✓ | ✓ |
| Attach to external TestFlight group | ✓ | ✓ | ✓ |

## Requirements

- macOS build machine with Xcode command-line tools
- Unreal Engine 5 installed (tested on UE 5.7)
- Homebrew Python 3 with `cryptography` and `pillow`:
  ```bash
  /opt/homebrew/bin/pip3 install cryptography pillow
  ```
- App Store Connect API key (`.p8` file + Key ID + Issuer ID)
- iOS Distribution certificate + App Store `.mobileprovision` (for iOS/visionOS)
- 3rd Party Mac Developer Application certificate + Mac App Store `.provisionprofile` (for macOS)
- All certs imported into a CI keychain (to sign without UI prompt)

---

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
security create-keychain -p "your-password" ~/Library/Keychains/ue5-ci.keychain-db
security import YourIOSDistCert.p12 -k ~/Library/Keychains/ue5-ci.keychain-db -P "" -T /usr/bin/codesign
security import YourMacDistCert.p12 -k ~/Library/Keychains/ue5-ci.keychain-db -P "" -T /usr/bin/codesign
security set-key-partition-list -S "apple-tool:,apple:,codesign:" -s -k "your-password" ~/Library/Keychains/ue5-ci.keychain-db
```

Update `CI_KEYCHAIN_PATH` and `CI_KEYCHAIN_PASS` in `ue5kit.conf`.

**3. Copy visionOS config into your UE5 project** (required or app crashes after splash)

```bash
mkdir -p YourProject/Config/VisionOS
cp ue5-config/VisionOS/*.ini YourProject/Config/VisionOS/
```

**4. Set iOS fps cap in your UE5 project**

In `Config/DefaultEngine.ini` under `[/Script/IOSRuntimeSettings.IOSRuntimeSettings]`:
```ini
FrameRateLock=PUFRL_None
```
Copy `ue5-config/DefaultDeviceProfiles.ini` content into `Config/DefaultDeviceProfiles.ini`.

**5. Run setup**

```bash
bash setup.sh
```

Validates config, checks prerequisites, installs the six LaunchAgents.

---

## visionOS Project Setup

visionOS requires significantly more project configuration than iOS. Do all of this before your first build.

### Required plugins

Add to your `.uproject` Plugins array. The first three are in `Engine/Plugins/`. `OpenXRVisionOS` is in `Engine/Platforms/VisionOS/Plugins/` and won't show in a standard plugin search — add it manually:

```json
{"Name": "OpenXR",              "Enabled": true},
{"Name": "OpenXREyeTracker",    "Enabled": true},
{"Name": "OpenXRHandTracking",  "Enabled": true},
{"Name": "OpenXRVisionOS",      "Enabled": true}
```

### Required DefaultEngine.ini settings

These must match the VR Template (`TP_VirtualRealityBP`) exactly. Missing any one causes rendering issues:

```ini
[/Script/EngineSettings.GameMapsSettings]
GlobalDefaultGameMode=/Game/XRFramework/Blueprints/BP_XRGameMode.BP_XRGameMode_C
GameDefaultMap=/Game/YourLevel/YourLevel
EditorStartupMap=/Game/YourLevel/YourLevel.YourLevel

[/Script/Engine.RendererSettings]
r.ForwardShading=True
r.MobileHDR=False
r.Mobile.ShadingPath=0
r.Mobile.PropagateAlpha=True
r.Mobile.UseHWsRGBEncoding=True
r.AllowStaticLighting=True
r.AllowOcclusionQueries=False
r.Shadow.Virtual.Enable=0
r.DynamicGlobalIlluminationMethod=0
r.ReflectionMethod=1
r.GenerateMeshDistanceFields=True
r.DefaultFeature.AutoExposure=False
r.DefaultFeature.AmbientOcclusion=False
r.DefaultFeature.AmbientOcclusionStaticFraction=False
r.DefaultFeature.MotionBlur=False
vr.MobileMultiView=True
vr.InstancedStereo=True

[/Script/OpenXRHMD.OpenXRHMDSettings]
xr.OpenXRInvertAlpha=True
```

**`r.MobileHDR=False` + `r.ForwardShading=True` + `r.Mobile.ShadingPath=0`** — all three required for correct alpha propagation in mixed immersion. Missing any one causes geometry to appear half-transparent.

**`xr.OpenXRInvertAlpha=True`** — without this the scene renders transparent (you see the real world but no UE5 content).

**`r.AllowOcclusionQueries=False`** — UE5 5.7 bug: occlusion queries corrupt the second eye. Disable it.

**`r.AllowStaticLighting=True`** — required to load `_BuiltData.uasset` baked lighting. If your project was created with static lighting disabled, baked lightmaps will be silently ignored.

### Required DefaultGame.ini

```ini
[/Script/EngineSettings.GeneralProjectSettings]
bStartInVR=True
```

### Required DefaultInput.ini

```ini
[/Script/Engine.InputSettings]
DefaultTouchInterface=None
```

Without `DefaultTouchInterface=None`, UE5 shows virtual joystick controls on visionOS.

### Privacy strings (visionOS)

INI-based privacy keys (`NSCameraUsageDescription` etc. under `[/Script/IOSRuntimeSettings.IOSRuntimeSettings]`) are **not** translated to visionOS plists by UE5. Use `AdditionalPlistData` instead, and add under `[/Script/IOSRuntimeSettings.IOSRuntimeSettings]`:

```ini
AdditionalPlistData=<key>NSHandsTrackingUsageDescription</key><string>Track your hands to interact with the application.</string>
```

`NSHandsTrackingUsageDescription` is required on xrOS — ARKit's hand tracking XPC service intentionally crashes the app if this key is absent (SIGABRT on launch, ~3 seconds in).

The `plist_patch.py` ship script also injects privacy strings directly into the staged plist as a belt-and-suspenders fallback.

### VisionOSEngine.ini (mixed immersion mode)

The `ue5-config/VisionOS/VisionOSEngine.ini` in this kit enables **mixed immersion** (content overlaid on real-world passthrough) by default. To switch to **full immersion** (dark surround), comment out the four lines at the bottom:

```ini
; Comment these four out for full immersion:
r.Mobile.PropagateAlpha=1
r.PostProcessing.PropagateAlpha=1
r.AlphaInvertPass=1

[/Script/VisionOSRuntimeSettings.VisionOSRuntimeSettings]
ImmersiveStyle=1
```

**Tip:** To verify mixed immersion is working, hide the sky sphere mesh in your level. With sky hidden: passthrough visible → ✓; black → alpha pipeline issue.

### Default map must be project-owned

Engine maps like `/Engine/Maps/Templates/OpenWorld` do not get cooked for device builds. Set `GameDefaultMap` to a map in your project's `Content/` folder — otherwise the app launches into a blank/transparent scene.

---

## Usage

```bash
# Trigger full pipeline
launchctl start com.yourcompany.iosbuild       # or your $ORG_LABEL
launchctl start com.yourcompany.visionosbuild
launchctl start com.yourcompany.macosbuild

# Monitor
tail -f /tmp/ue5kit-ios-build.log
tail -f /tmp/ue5kit-ship-ios.log
tail -f /tmp/ue5kit-visionos-build.log
tail -f /tmp/ue5kit-ship-visionos.log

# Ship only (build already staged)
launchctl start com.yourcompany.shipios
launchctl start com.yourcompany.shipvisionos
launchctl start com.yourcompany.shipmacos

# Manual external group attach (if ASC poll timed out)
python3 scripts/attach_to_group.py ios
python3 scripts/attach_to_group.py visionos
python3 scripts/attach_to_group.py macos
```

---

## Hard-Won Gotchas

**Never run `codesign` directly over SSH.** macOS blocks keychain access from SSH sessions. Always use `launchctl start` (runs in GUI session context). `security find-identity -v` always returns 0 identities over SSH even if certs are present — this is expected and not an error.

**UE5 ignores `BundleIdentifier` in DefaultEngine.ini for iOS.** The xcconfig file hardcodes the bundle ID as `$(UE_SIGNING_PREFIX).$(UE_PRODUCT_NAME_STRIPPED)`. The ship scripts patch `CFBundleIdentifier` in the staged `.app/Info.plist` post-build.

**30fps iOS default requires two separate fixes.** `FrameRateLock=PUFRL_None` in `DefaultEngine.ini` handles the UE5-level cap. The `DefaultDeviceProfiles.ini` CVars handle the render-level cap. Neither alone is sufficient.

**visionOS crashes after splash** without `Config/VisionOS/VisionOSEngine.ini` and `VisionOSDeviceProfiles.ini`. The minimum required settings are `vr.InstancedStereo=False`, `vr.MobileMultiView=False`, and `xr.OpenXRAcquireMode=1`.

**visionOS icon must be a `.solidimagestack`.** Apple rejects with ITMS-90970 without one. The `gen_visionos_icon.py` script generates a minimal placeholder and compiles it with `xcrun actool`. The `CFBundlePrimaryIcon` Info.plist value must be a **string** — not a dict (ITMS-90039 if dict).

**Half-transparent rendering in mixed immersion** — `r.MobileHDR=False`, `r.ForwardShading=True`, and `r.Mobile.ShadingPath=0` must all be present in `DefaultEngine.ini`. Missing any one causes the HDR/deferred pipeline to mishandle the alpha channel.

**One eye renders black on visionOS (UE5 5.7 bug)** — occlusion queries corrupt the second eye. Add `r.AllowOcclusionQueries=False` to `[/Script/Engine.RendererSettings]`.

**Touch controls appear on visionOS** — set `DefaultTouchInterface=None` in `Config/DefaultInput.ini` under `[/Script/Engine.InputSettings]`.

**NSHandsTrackingUsageDescription crash** — ARKit's hand tracking XPC service intentionally crashes the app on launch (~3 seconds in) if this plist key is absent. Add via `AdditionalPlistData` in DefaultEngine.ini.

**plist patching must use a standalone script** — `python3 - << HEREDOC` in LaunchAgent context silently fails to write plist files (`plistlib.dump` doesn't persist). The kit uses `plist_patch.py` via `/opt/homebrew/bin/python3`.

**visionOS ASC processing takes 30–60 min** (vs 5–10 min for iOS/macOS). The poll script will time out. Run `attach_to_group.py visionos` manually once the build is VALID.

**UE5 allows only one RunUAT at a time.** Don't trigger builds simultaneously — the second one exits immediately with an AutomationTool mutex error.

**iOS builds run on Apple Vision Pro** via the iOS compatibility layer. You don't need a separate visionOS build to test on the headset.

**macOS uses a different cert and profile type.** The iOS Distribution cert won't sign macOS builds. You need a `3rd Party Mac Developer Application` cert and a Mac App Store `.provisionprofile` — separate from the iOS `.mobileprovision`.

**macOS upload uses `--type macos` and a `.zip`**, not an IPA. `xcrun altool` accepts a zip of the `.app` bundle directly.

**iOS icon upload fails with error 90717 (invalid large app icon)** — ASC rejects the IPA if the 1024×1024 icon in the asset catalog has an alpha channel *or* is compiled as grayscale. UE5 builds often ship with a near-grayscale default icon (R≈G≈B for every pixel); `actool` detects this and emits `Encoding: Gray, Opaque: false` internally, which ASC rejects even if the PNG color type is RGB. Fix: inject a replacement asset catalog with vivid-color icons (blue/teal stripes, anything with R≠G≠B) compiled into a fresh `Assets.car` before re-signing. The `ship_ios.sh` script now does this automatically in step 1b. Note: actool has a persistent content-hash cache — if you change the PNG but use the same path, it may return the cached (gray) output. Always generate icons into a fresh temp directory.

**MetaHuman iOS crash on cold launch (UE-227478)** — The Metal PSO precache pool compiles MetaHuman shader permutation `Main_00002308_a823f915` (vertex factory `0x2308`), which declares vertex attribute 7 (4th UV channel) in `stage_in` but UE5 builds the Metal vertex descriptor without it. AGX hard-aborts: `Vertex attribute 7 is not defined in the vertex descriptor`. Intermittent because it only fires on cold starts before the binary shader cache warms up. Fix: create `Config/IOS/IOSEngine.ini` with:
```ini
[ConsoleVariables]
r.PSOPrecaching=0
```
Scope to the IOS-specific ini (not `DefaultEngine.ini`) so desktop builds keep precaching. The file **must exist before the cook starts** — if you create it mid-cook, UAT has already processed config and the setting won't bundle. Verify it was included by checking the cook log for `Including config file .../Config/IOS/IOSEngine.ini`. A template is in `ue5-config/IOS/IOSEngine.ini`.

---

## ASC Setup Notes

- Create an App Store Connect API key at Users & Access → Keys. Download the `.p8` — it cannot be re-downloaded.
- Create an "Internal" beta group with `hasAccessToAllBuilds = true` — no per-build attachment needed.
- Create an "External" beta group — the ship scripts attach each build explicitly after it reaches VALID.
- For the external group UUID, check the ASC URL when viewing the group, or via the API: `GET /v1/betaGroups?filter[app]=YOUR_APP_ID`.

---

## File Structure

```
ue5-testflight/
├── ue5kit.conf.template      # copy to ue5kit.conf and fill in
├── setup.sh                  # validates config + installs LaunchAgents
├── SKILL.md                  # Claude Code skill (load via skills.sh)
├── scripts/
│   ├── run_ios_build.sh      # UE5 cook+stage for iOS → auto-triggers ship
│   ├── run_visionos_build.sh
│   ├── run_macos_build.sh
│   ├── ship_ios.sh           # resign → repack → upload → distribute
│   ├── ship_visionos.sh
│   ├── ship_macos.sh
│   ├── plist_patch.py        # Info.plist patcher (bundle ID, version, privacy strings)
│   ├── gen_entitlements.py   # extract entitlements from .mobileprovision/.provisionprofile
│   ├── gen_visionos_icon.py  # generate .solidimagestack icon + compile with actool
│   └── attach_to_group.py   # poll ASC for VALID + attach to external group (ios/visionos/macos)
└── ue5-config/
    ├── IOS/
    │   └── IOSEngine.ini              # UE-227478 PSO precache workaround (MetaHuman)
    ├── VisionOS/
    │   ├── VisionOSEngine.ini         # copy to your project Config/VisionOS/
    │   └── VisionOSDeviceProfiles.ini
    └── DefaultDeviceProfiles.ini      # iOS fps cap settings
```
