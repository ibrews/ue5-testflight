#!/bin/bash
# ship_ios.sh — Resign staged UE5 iOS .app, pack IPA, upload to TestFlight, distribute
# Trigger: launchctl start $ORG_LABEL.shipios
# Log:     /tmp/ue5kit-ship-ios.log
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../ue5kit.conf"

exec > /tmp/ue5kit-ship-ios.log 2>&1
export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
echo "=== ship_ios.sh: $(date) ==="

APP_DIR="$IOS_ARCHIVE_DIR/Saved/StagedBuilds/IOS/${IOS_PROJECT_NAME}.app"
# Fallback: RunUAT may stage directly inside the project directory
if [ ! -d "$APP_DIR" ]; then
  _PROJ_DIR="$(dirname "$IOS_PROJECT_PATH")"
  APP_DIR="$_PROJ_DIR/Saved/StagedBuilds/IOS/${IOS_PROJECT_NAME}.app"
fi
IPA_PATH="$IOS_ARCHIVE_DIR/${IOS_PROJECT_NAME}.ipa"
ENTITLEMENTS="/tmp/ue5kit-ios.xcent"

# ── 1. Unlock CI keychain ──────────────────────────────────────────────────
echo "[1/6] Unlocking CI keychain..."
security unlock-keychain -p "$CI_KEYCHAIN_PASS" "$CI_KEYCHAIN_PATH"
security list-keychains -d user -s "$CI_KEYCHAIN_PATH" \
    ~/Library/Keychains/login.keychain-db /Library/Keychains/System.keychain

# ── 2. Generate entitlements + patch Info.plist ────────────────────────────
# NOTE: Must use /opt/homebrew/bin/python3 with a standalone script — NOT a
# python3 heredoc. Heredocs in LaunchAgent context silently fail to write
# plist files (the print executes but plistlib.dump does not persist).
echo "[2/6] Generating entitlements + patching Info.plist..."
/opt/homebrew/bin/python3 "$SCRIPT_DIR/gen_entitlements.py" "$PROFILE_PATH" "$ENTITLEMENTS"

VERSION_FILE="$IOS_ARCHIVE_DIR/.last_successful_build"
if [ -f "$VERSION_FILE" ]; then
    LAST=$(cat "$VERSION_FILE")
    PREFIX=$(echo "$LAST" | rev | cut -d. -f2- | rev)
    SUFFIX=$(echo "$LAST" | rev | cut -d. -f1 | rev)
    NEXT_VERSION="${PREFIX}.$((SUFFIX + 1))"
else
    NEXT_VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$APP_DIR/Info.plist" 2>/dev/null || echo "0.0")
fi
echo "  Next build version: $NEXT_VERSION"
/opt/homebrew/bin/python3 "$SCRIPT_DIR/plist_patch.py" "$APP_DIR/Info.plist" "$BUNDLE_ID" "$NEXT_VERSION"

# ── 3. Re-sign ─────────────────────────────────────────────────────────────
echo "[3/6] Re-signing .app..."
rm -f "$APP_DIR"/*.cstemp
rm -rf "$APP_DIR/_CodeSignature"
cp "$PROFILE_PATH" "$APP_DIR/embedded.mobileprovision"
codesign --force --sign "$CERT_SHA1" \
    --entitlements "$ENTITLEMENTS" --timestamp=none \
    --keychain "$CI_KEYCHAIN_PATH" "$APP_DIR" 2>&1
[ $? -ne 0 ] && echo "SIGNING FAILED" && exit 1
codesign --verify --verbose=2 "$APP_DIR" 2>&1

# ── 4. Package IPA ─────────────────────────────────────────────────────────
echo "[4/6] Packaging IPA..."
mkdir -p "$IOS_ARCHIVE_DIR"
rm -f "$IPA_PATH"
PACK_DIR="/tmp/ue5kit-ios-pack-$$"
mkdir -p "$PACK_DIR/Payload"
cp -R "$APP_DIR" "$PACK_DIR/Payload/"
(cd "$PACK_DIR" && zip -qr "$IPA_PATH" Payload/)
rm -rf "$PACK_DIR"
ls -lh "$IPA_PATH"

# ── 5. Upload ──────────────────────────────────────────────────────────────
echo "[5/6] Uploading to TestFlight..."
xcrun altool --upload-app --type ios --file "$IPA_PATH" \
    --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID" --verbose 2>&1
[ $? -ne 0 ] && echo "UPLOAD FAILED" && exit 1

UPLOADED_VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$APP_DIR/Info.plist" 2>/dev/null)
echo "$UPLOADED_VERSION" > "$VERSION_FILE"
echo "  Recorded successful build: $UPLOADED_VERSION → $VERSION_FILE"

# ── 6. Poll → attach to external group ────────────────────────────────────
echo "[6/6] Polling for VALID, then attaching to external group..."
/opt/homebrew/bin/python3 "$SCRIPT_DIR/attach_to_group.py" ios

echo "=== ship_ios.sh complete: $(date) ==="
