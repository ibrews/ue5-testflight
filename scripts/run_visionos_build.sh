#!/bin/bash
# run_visionos_build.sh — UE5 BuildCookRun for visionOS, auto-triggers ship on success
# Trigger: launchctl start $ORG_LABEL.visionosbuild
# Log:     /tmp/ue5kit-visionos-build.log
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../ue5kit.conf"

exec > /tmp/ue5kit-visionos-build.log 2>&1
echo "=== visionOS Build Started: $(date) ==="

export HOME="${HOME:-/Users/$(whoami)}"
export USER="${USER:-$(whoami)}"
export PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin

"$UE5_ENGINE_PATH/Engine/Build/BatchFiles/RunUAT.sh" \
  BuildCookRun \
  -project="$VISIONOS_PROJECT_PATH" \
  -platform=VisionOS -clientconfig=Development \
  -cook -build -stage -pak -archive \
  -archivedirectory="$VISIONOS_ARCHIVE_DIR" \
  -unattended -noP4 -nodebuginfo -utf8output

BUILD_EXIT=$?
echo "=== visionOS Build Finished: $(date) exit=$BUILD_EXIT ==="

if [ $BUILD_EXIT -eq 0 ]; then
  echo "Build succeeded — triggering ship..."
  launchctl start "$ORG_LABEL.shipvisionos"
else
  echo "Build FAILED (exit $BUILD_EXIT)"
fi
