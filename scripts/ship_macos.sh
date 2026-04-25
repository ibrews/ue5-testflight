#!/bin/bash
# ship_macos.sh — Resign staged UE5 macOS .app, zip, upload to TestFlight, distribute
# Trigger: launchctl start $ORG_LABEL.shipmacos  (must run as LaunchAgent, not over SSH)
# Log:     /tmp/ue5kit-ship-macos.log
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../ue5kit.conf"

exec > /tmp/ue5kit-ship-macos.log 2>&1
export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
echo "=== ship_macos.sh: $(date) ==="

APP_DIR="$MACOS_ARCHIVE_DIR/Saved/StagedBuilds/Mac/${MACOS_PROJECT_NAME}.app"
if [ ! -d "$APP_DIR" ]; then
  _PROJ_DIR="$(dirname "$MACOS_PROJECT_PATH")"
  APP_DIR="$_PROJ_DIR/Saved/StagedBuilds/Mac/${MACOS_PROJECT_NAME}.app"
fi
if [ ! -d "$APP_DIR" ]; then
  APP_DIR=$(find "$MACOS_ARCHIVE_DIR" -name "*.app" -type d 2>/dev/null | head -1)
fi
[ -z "$APP_DIR" ] || [ ! -d "$APP_DIR" ] && echo "ERROR: No staged .app found." && exit 1

ZIP_PATH="$MACOS_ARCHIVE_DIR/${MACOS_PROJECT_NAME}-macos.zip"
ENTITLEMENTS="/tmp/ue5kit-macos.xcent"

# ── 1. Unlock CI keychain ──────────────────────────────────────────────────
echo "[1/6] Unlocking CI keychain..."
security unlock-keychain "$CI_KEYCHAIN_PATH" <<< "$CI_KEYCHAIN_PASS"
security list-keychains -d user -s "$CI_KEYCHAIN_PATH" \
    ~/Library/Keychains/login.keychain-db /Library/Keychains/System.keychain

# ── 2. Extract entitlements + patch Info.plist ────────────────────────────
echo "[2/6] Generating entitlements + patching Info.plist..."
/opt/homebrew/bin/python3 "$SCRIPT_DIR/gen_entitlements.py" "$MACOS_PROFILE_PATH" "$ENTITLEMENTS"

/opt/homebrew/bin/python3 - << PYEOF
import plistlib, sys, os
path = "${APP_DIR}/Contents/Info.plist"
if not os.path.exists(path):
    print(f"ERROR: Info.plist not found at {path}"); sys.exit(1)
with open(path, "rb") as f:
    info = plistlib.load(f)
info["CFBundleIdentifier"] = "${BUNDLE_ID}"
old = info.get("CFBundleVersion", "0")
parts = old.rsplit(".", 1)
info["CFBundleVersion"] = parts[0] + "." + str(int(parts[1]) + 1) if len(parts) == 2 else old + ".1"
info.setdefault("NSCameraUsageDescription",       "This app may use the camera.")
info.setdefault("NSMicrophoneUsageDescription",   "This app may use the microphone.")
info.setdefault("ITSAppUsesNonExemptEncryption",  False)
with open(path, "wb") as f:
    plistlib.dump(info, f)
print(f"  BundleID: {info['CFBundleIdentifier']}  Build: {info.get('CFBundleVersion')}")
PYEOF

# ── 3. Embed provisioning profile + re-sign ────────────────────────────────
echo "[3/6] Re-signing .app..."
cp "$MACOS_PROFILE_PATH" "$APP_DIR/Contents/embedded.provisionprofile"

# Sign frameworks and dylibs first, then the .app bundle
find "$APP_DIR" \( -name "*.dylib" -o -name "*.framework" \) | while read -r item; do
  codesign --force --sign "$MACOS_CERT_SHA1" --timestamp=none \
    --keychain "$CI_KEYCHAIN_PATH" "$item" 2>&1
done

codesign --force --sign "$MACOS_CERT_SHA1" \
  --entitlements "$ENTITLEMENTS" --timestamp=none \
  --keychain "$CI_KEYCHAIN_PATH" "$APP_DIR" 2>&1
[ $? -ne 0 ] && echo "SIGNING FAILED" && exit 1
codesign --verify --verbose=2 "$APP_DIR" 2>&1

# ── 4. Zip .app for altool upload ──────────────────────────────────────────
echo "[4/6] Zipping .app..."
mkdir -p "$MACOS_ARCHIVE_DIR"
(cd "$(dirname "$APP_DIR")" && zip -qr "$ZIP_PATH" "$(basename "$APP_DIR")")
ls -lh "$ZIP_PATH"

# ── 5. Upload ──────────────────────────────────────────────────────────────
echo "[5/6] Uploading to TestFlight..."
xcrun altool --upload-app --type macos --file "$ZIP_PATH" \
    --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID" --verbose 2>&1
[ $? -ne 0 ] && echo "UPLOAD FAILED" && exit 1

# ── 6. Poll → attach to external group ────────────────────────────────────
echo "[6/6] Polling for VALID, then attaching to external group..."
/opt/homebrew/bin/python3 "$SCRIPT_DIR/attach_to_group.py" macos

echo "=== ship_macos.sh complete: $(date) ==="
