#!/usr/bin/env python3
"""Extract entitlements from a .mobileprovision file into a .xcent plist.

UE5 visionOS staged builds do not generate a .xcent entitlements file —
codesign requires one explicitly. This script extracts it from the
provisioning profile.

Usage:
    gen_entitlements.py <profile.mobileprovision> <output.xcent>
"""
import plistlib, sys

def main():
    if len(sys.argv) < 3:
        print("Usage: gen_entitlements.py <profile.mobileprovision> <output.xcent>")
        sys.exit(1)

    profile_path = sys.argv[1]
    out_path = sys.argv[2]

    with open(profile_path, "rb") as f:
        content = f.read()

    start = content.find(b"<?xml")
    end = content.find(b"</plist>") + len(b"</plist>")
    if start == -1 or end < len(b"</plist>"):
        print("ERROR: Could not find plist in provisioning profile")
        sys.exit(1)

    plist = plistlib.loads(content[start:end])
    entitlements = plist.get("Entitlements", {})

    with open(out_path, "wb") as f:
        plistlib.dump(entitlements, f, fmt=plistlib.FMT_XML)

    print(f"Entitlements written to {out_path}: {list(entitlements.keys())}")

if __name__ == "__main__":
    main()
