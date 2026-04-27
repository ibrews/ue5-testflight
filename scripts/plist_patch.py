#!/usr/bin/env python3
"""Patch an Unreal Engine staged .app Info.plist for TestFlight submission.

Increments CFBundleVersion, sets CFBundleIdentifier, and injects required
privacy/encryption keys. Used by ship_ios.sh, ship_visionos.sh, ship_macos.sh.

Must be called via /opt/homebrew/bin/python3 (not system python3 or a heredoc)
— python3 heredocs in LaunchAgent context silently fail to write plist files.

Usage:
    plist_patch.py <Info.plist path> <bundle_id>
"""
import plistlib, sys, os

def main():
    if len(sys.argv) < 3:
        print("Usage: plist_patch.py <Info.plist> <bundle_id>")
        sys.exit(1)

    plist_path = sys.argv[1]
    bundle_id  = sys.argv[2]

    if not os.path.exists(plist_path):
        print(f"ERROR: Info.plist not found at {plist_path}")
        sys.exit(1)

    with open(plist_path, "rb") as f:
        info = plistlib.load(f)

    info["CFBundleIdentifier"] = bundle_id

    # Auto-increment last component of CFBundleVersion to avoid ASC duplicate errors
    old = info.get("CFBundleVersion", "0")
    parts = old.rsplit(".", 1)
    if len(parts) == 2:
        try:
            info["CFBundleVersion"] = parts[0] + "." + str(int(parts[1]) + 1)
        except ValueError:
            info["CFBundleVersion"] = old + ".1"
    else:
        info["CFBundleVersion"] = old + ".1"

    # Required privacy strings (Apple rejects without these — ITMS-90683)
    # NOTE: For visionOS, INI-based privacy keys (NSCameraUsageDescription etc. set under
    # [/Script/IOSRuntimeSettings.IOSRuntimeSettings]) are NOT translated into the visionOS
    # plist by UE5. Only AdditionalPlistData entries make it in via the build system.
    # This script patches the staged plist directly as a belt-and-suspenders fallback.
    info.setdefault("NSCameraUsageDescription",          "This app may use the camera.")
    info.setdefault("NSMicrophoneUsageDescription",      "This app may use the microphone.")
    info.setdefault("NSPhotoLibraryUsageDescription",    "This app may access your photo library.")
    info.setdefault("NSHandsTrackingUsageDescription",   "This app tracks your hands to enable interaction.")
    info.setdefault("ITSAppUsesNonExemptEncryption",     False)

    with open(plist_path, "wb") as f:
        plistlib.dump(info, f)

    bid = info["CFBundleIdentifier"]
    ver = info["CFBundleVersion"]
    print(f"  BundleID: {bid}  Build: {ver}")

if __name__ == "__main__":
    main()
