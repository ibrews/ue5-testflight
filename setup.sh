#!/bin/bash
# setup.sh — Install ue5-testflight kit on a macOS build machine
# Run once after filling in ue5kit.conf.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF="$SCRIPT_DIR/ue5kit.conf"

echo "=== ue5-testflight kit setup ==="

# ── 1. Check config ─────────────────────────────────────────────────────────
if [ ! -f "$CONF" ]; then
    echo "ERROR: ue5kit.conf not found."
    echo "  cp $SCRIPT_DIR/ue5kit.conf.template $SCRIPT_DIR/ue5kit.conf"
    echo "  # Fill in your values, then re-run setup.sh"
    exit 1
fi
source "$CONF"

echo "Config loaded:"
echo "  Bundle ID:      $BUNDLE_ID"
echo "  iOS project:    $IOS_PROJECT_PATH"
echo "  visionOS project: $VISIONOS_PROJECT_PATH"
echo "  ASC App ID:     $ASC_APP_ID"
echo "  Org label:      $ORG_LABEL"

# ── 2. Check prerequisites ──────────────────────────────────────────────────
echo ""
echo "Checking prerequisites..."

check() {
    if command -v "$1" >/dev/null 2>&1; then
        echo "  ✓ $1"
    else
        echo "  ✗ $1 — NOT FOUND"
        MISSING=1
    fi
}

check xcrun
check codesign
check security
check /opt/homebrew/bin/python3

if ! /opt/homebrew/bin/python3 -c "import cryptography, PIL" 2>/dev/null; then
    echo "  ✗ Python packages missing — run:"
    echo "      /opt/homebrew/bin/pip3 install cryptography pillow"
    MISSING=1
else
    echo "  ✓ Python cryptography + pillow"
fi

if [ -n "$MISSING" ]; then
    echo ""
    echo "Fix the above before continuing."
    exit 1
fi

# ── 3. Validate signing assets ──────────────────────────────────────────────
echo ""
echo "Validating signing assets..."

[ -f "$PROFILE_PATH" ]       && echo "  ✓ Provisioning profile: $PROFILE_PATH" \
                              || { echo "  ✗ Profile not found: $PROFILE_PATH"; exit 1; }
[ -f "$ASC_KEY_PATH" ]       && echo "  ✓ ASC API key: $ASC_KEY_PATH" \
                              || { echo "  ✗ ASC key not found: $ASC_KEY_PATH"; exit 1; }
[ -f "$CI_KEYCHAIN_PATH" ]   && echo "  ✓ CI keychain: $CI_KEYCHAIN_PATH" \
                              || echo "  ℹ CI keychain not found — will use login keychain"

# ── 4. Make scripts executable ──────────────────────────────────────────────
chmod +x "$SCRIPT_DIR/scripts/"*.sh "$SCRIPT_DIR/scripts/"*.py
echo ""
echo "Scripts made executable."

# ── 5. Install LaunchAgents ─────────────────────────────────────────────────
echo ""
echo "Installing LaunchAgents..."
LA_DIR="$HOME/Library/LaunchAgents"
mkdir -p "$LA_DIR"

install_agent() {
    local label="$ORG_LABEL.$1"
    local script="$SCRIPT_DIR/scripts/$2"
    local log="/tmp/ue5kit-$3.log"
    local plist="$LA_DIR/$label.plist"

    cat > "$plist" << PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$label</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$script</string>
    </array>
    <key>RunAtLoad</key>
    <false/>
    <key>StandardOutPath</key>
    <string>$log</string>
    <key>StandardErrorPath</key>
    <string>$log</string>
</dict>
</plist>
PLIST_EOF

    launchctl unload "$plist" 2>/dev/null || true
    launchctl load "$plist"
    echo "  ✓ $label"
}

install_agent "iosbuild"      "run_ios_build.sh"      "ios-build"
install_agent "shipios"       "ship_ios.sh"            "ship-ios"
install_agent "visionosbuild" "run_visionos_build.sh"  "visionos-build"
install_agent "shipvisionos"  "ship_visionos.sh"       "ship-visionos"

# ── 6. Done ─────────────────────────────────────────────────────────────────
echo ""
echo "=== Setup complete ==="
echo ""
echo "Trigger a build:"
echo "  iOS:      launchctl start $ORG_LABEL.iosbuild"
echo "  visionOS: launchctl start $ORG_LABEL.visionosbuild"
echo ""
echo "Monitor:"
echo "  tail -f /tmp/ue5kit-ios-build.log"
echo "  tail -f /tmp/ue5kit-ship-ios.log"
echo "  tail -f /tmp/ue5kit-visionos-build.log"
echo "  tail -f /tmp/ue5kit-ship-visionos.log"
echo ""
echo "Re-attach to external group manually (if poll timed out):"
echo "  /opt/homebrew/bin/python3 $SCRIPT_DIR/scripts/attach_to_group.py ios"
echo "  /opt/homebrew/bin/python3 $SCRIPT_DIR/scripts/attach_to_group.py visionos"
