#!/bin/bash
# ship_visionos.sh — Resign staged UE5 visionOS .app, pack IPA, upload to TestFlight, distribute
# Trigger: launchctl start $ORG_LABEL.shipvisionos
# Log:     /tmp/ue5kit-ship-visionos.log
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../ue5kit.conf"

exec > /tmp/ue5kit-ship-visionos.log 2>&1
export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
echo "=== ship_visionos.sh: $(date) ==="

STAGED_APP="$VISIONOS_ARCHIVE_DIR/Saved/StagedBuilds/VisionOS/${VISIONOS_PROJECT_NAME}.app"
# Fallback: RunUAT may stage inside the project dir
if [ ! -d "$STAGED_APP" ]; then
  _PROJ_DIR="$(dirname "$VISIONOS_PROJECT_PATH")"
  STAGED_APP="$_PROJ_DIR/Saved/StagedBuilds/VisionOS/${VISIONOS_PROJECT_NAME}.app"
fi
ARCHIVE_IPA="$VISIONOS_ARCHIVE_DIR/VisionOS/${VISIONOS_PROJECT_NAME}.ipa"
IPA_PATH="$VISIONOS_ARCHIVE_DIR/${VISIONOS_PROJECT_NAME}-visionos.ipa"
ENTITLEMENTS="/tmp/ue5kit-visionos.xcent"

# ── 1. Generate entitlements + unlock keychain ─────────────────────────────
/opt/homebrew/bin/python3 "$SCRIPT_DIR/gen_entitlements.py" "$PROFILE_PATH" "$ENTITLEMENTS"
echo "[1/6] Unlocking CI keychain..."
security unlock-keychain -p "$CI_KEYCHAIN_PASS" "$CI_KEYCHAIN_PATH"
security list-keychains -d user -s "$CI_KEYCHAIN_PATH" \
    ~/Library/Keychains/login.keychain-db /Library/Keychains/System.keychain

# ── 2. Locate .app ─────────────────────────────────────────────────────────
echo "[2/6] Locating .app..."
WORK_APP=""
TEMP_UNPACK=""

if [ -d "$STAGED_APP" ]; then
    echo "Using staged .app: $STAGED_APP"
    WORK_APP="$STAGED_APP"
else
    FOUND=$(find "$(dirname "$VISIONOS_PROJECT_PATH")/Saved/StagedBuilds" -name "*.app" -type d 2>/dev/null | head -1)
    if [ -n "$FOUND" ]; then
        echo "Found staged .app: $FOUND"
        WORK_APP="$FOUND"
    elif [ -f "$ARCHIVE_IPA" ]; then
        echo "Unpacking archive IPA: $ARCHIVE_IPA"
        TEMP_UNPACK="/tmp/ue5kit-visionos-unpack-$$"
        mkdir -p "$TEMP_UNPACK"
        unzip -q "$ARCHIVE_IPA" -d "$TEMP_UNPACK"
        WORK_APP=$(find "$TEMP_UNPACK/Payload" -name "*.app" -maxdepth 1 | head -1)
    else
        echo "ERROR: No staged .app or IPA found. Did the build succeed?"
        exit 1
    fi
fi

# ── 3. Patch Info.plist ────────────────────────────────────────────────────
# NOTE: Must use /opt/homebrew/bin/python3 with a standalone script — NOT a
# python3 heredoc. Heredocs in LaunchAgent context silently fail to write
# plist files (the print executes but plistlib.dump does not persist).
echo "[3/6] Patching Info.plist..."
/opt/homebrew/bin/python3 "$SCRIPT_DIR/plist_patch.py" "$WORK_APP/Info.plist" "$BUNDLE_ID"

# ── 4. Inject visionOS icon + re-sign ──────────────────────────────────────
/opt/homebrew/bin/python3 "$SCRIPT_DIR/gen_visionos_icon.py" "$WORK_APP"
echo "[4/6] Re-signing .app..."
rm -f "$WORK_APP"/*.cstemp
rm -rf "$WORK_APP/_CodeSignature"
cp "$PROFILE_PATH" "$WORK_APP/embedded.mobileprovision"
codesign --force --sign "$CERT_SHA1" \
    --entitlements "$ENTITLEMENTS" --timestamp=none \
    --keychain "$CI_KEYCHAIN_PATH" "$WORK_APP" 2>&1
[ $? -ne 0 ] && echo "SIGNING FAILED" && exit 1
codesign --verify --verbose=2 "$WORK_APP" 2>&1

# ── 5. Pack IPA ────────────────────────────────────────────────────────────
echo "[5/6] Packing IPA..."
mkdir -p "$VISIONOS_ARCHIVE_DIR"
rm -f "$IPA_PATH"
PACK_DIR="/tmp/ue5kit-visionos-pack-$$"
mkdir -p "$PACK_DIR/Payload"
cp -R "$WORK_APP" "$PACK_DIR/Payload/"
(cd "$PACK_DIR" && zip -qr "$IPA_PATH" Payload/)
rm -rf "$PACK_DIR"
[ -n "$TEMP_UNPACK" ] && rm -rf "$TEMP_UNPACK"
ls -lh "$IPA_PATH"

# ── 6. Upload + distribute ─────────────────────────────────────────────────
echo "[6/6] Uploading to TestFlight (altool -t ios covers visionOS)..."
xcrun altool --upload-app --type ios --file "$IPA_PATH" \
    --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID" --verbose 2>&1
[ $? -ne 0 ] && echo "UPLOAD FAILED" && exit 1

echo "Polling for VALID + attaching to external group..."
/opt/homebrew/bin/python3 "$SCRIPT_DIR/attach_to_group.py" visionos

echo "=== ship_visionos.sh complete: $(date) ==="
