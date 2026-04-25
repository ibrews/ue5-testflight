#!/bin/bash
# run_ios_build.sh — UE5 BuildCookRun for iOS, auto-triggers ship on success
# Trigger: launchctl start $ORG_LABEL.iosbuild
# Log:     /tmp/ue5kit-ios-build.log
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../ue5kit.conf"

exec > /tmp/ue5kit-ios-build.log 2>&1
echo "=== iOS Build Started: $(date) ==="

export HOME="${HOME:-/Users/$(whoami)}"
export USER="${USER:-$(whoami)}"
export PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin

"$UE5_ENGINE_PATH/Engine/Build/BatchFiles/RunUAT.sh" \
  BuildCookRun \
  -project="$IOS_PROJECT_PATH" \
  -platform=IOS -clientconfig=Development \
  -cook -build -stage -pak -archive \
  -archivedirectory="$IOS_ARCHIVE_DIR" \
  -unattended -noP4 -nodebuginfo -utf8output

BUILD_EXIT=$?
echo "=== iOS Build Finished: $(date) exit=$BUILD_EXIT ==="

if [ $BUILD_EXIT -eq 0 ]; then
  echo "Build succeeded — triggering ship..."
  launchctl start "$ORG_LABEL.shipios"
else
  echo "Build FAILED (exit $BUILD_EXIT) — skipping ship step"
fi
