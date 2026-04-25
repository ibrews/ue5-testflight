#!/bin/bash
# run_macos_build.sh — UE5 BuildCookRun for macOS, auto-triggers ship on success
# Trigger: launchctl start $ORG_LABEL.macosbuild
# Log:     /tmp/ue5kit-macos-build.log
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../ue5kit.conf"

exec > /tmp/ue5kit-macos-build.log 2>&1
echo "=== macOS Build Started: $(date) ==="

export HOME="${HOME:-/Users/$(whoami)}"
export USER="${USER:-$(whoami)}"
export PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin

"$UE5_ENGINE_PATH/Engine/Build/BatchFiles/RunUAT.sh" \
  BuildCookRun \
  -project="$MACOS_PROJECT_PATH" \
  -platform=Mac -clientconfig=Shipping \
  -cook -build -stage -pak -archive \
  -archivedirectory="$MACOS_ARCHIVE_DIR" \
  -unattended -noP4 -nodebuginfo -utf8output

BUILD_EXIT=$?
echo "=== macOS Build Finished: $(date) exit=$BUILD_EXIT ==="

if [ $BUILD_EXIT -eq 0 ]; then
  echo "Build succeeded — triggering ship..."
  launchctl start "$ORG_LABEL.shipmacos"
else
  echo "Build FAILED (exit $BUILD_EXIT) — skipping ship step"
fi
