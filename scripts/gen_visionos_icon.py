#!/usr/bin/env python3
"""Generate a minimal visionOS .solidimagestack icon and inject it into a UE5-staged .app bundle.

UE5 visionOS builds do not include a visionOS app icon. Apple rejects the upload with
ITMS-90970 (missing CFBundleIcons.CFBundlePrimaryIcon) unless a compiled Assets.car
containing an AppIcon.solidimagestack is present.

This script:
  1. Creates a 3-layer .solidimagestack catalog (Back=RGB, Middle/Front=RGBA)
  2. Compiles it with xcrun actool --platform xros
  3. Copies Assets.car into the .app bundle
  4. Patches Info.plist with CFBundleIcons.CFBundlePrimaryIcon = "AppIcon" (string, not dict)

Requires: Pillow (pip install pillow), Xcode command-line tools

Usage:
    gen_visionos_icon.py <path/to/App.app> [custom_icon_dir]

    custom_icon_dir: optional path to your own .solidimagestack catalog.
                     If omitted, a minimal placeholder icon is generated.
"""
import os, sys, json, subprocess, plistlib, shutil
from PIL import Image, ImageDraw

CATALOG_DIR = "/tmp/ue5kit-visionos-icon.xcassets"
OUTPUT_DIR  = "/tmp/ue5kit-visionos-icon-compiled"


def write_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump(data, f, indent=2)


def build_placeholder_catalog(catalog_dir):
    """Generate a minimal 3-layer placeholder icon."""
    stack_dir = os.path.join(catalog_dir, "AppIcon.solidimagestack")
    layers = ["Front", "Middle", "Back"]

    write_json(os.path.join(stack_dir, "Contents.json"), {
        "info": {"author": "xcode", "version": 1},
        "layers": [{"filename": f"{l}.solidimagestacklayer"} for l in layers]
    })

    for layer in layers:
        layer_dir = os.path.join(stack_dir, f"{layer}.solidimagestacklayer")
        write_json(os.path.join(layer_dir, "Contents.json"),
                   {"info": {"author": "xcode", "version": 1}})
        img_dir = os.path.join(layer_dir, "Content.imageset")
        write_json(os.path.join(img_dir, "Contents.json"), {
            "images": [{"filename": f"{layer}.png", "idiom": "vision", "scale": "2x"}],
            "info": {"author": "xcode", "version": 1}
        })
        os.makedirs(img_dir, exist_ok=True)
        png_path = os.path.join(img_dir, f"{layer}.png")

        if layer == "Back":
            # Must be RGB (no alpha) — ITMS-90523 if RGBA
            img = Image.new("RGB", (1024, 1024), (20, 20, 30))
            draw = ImageDraw.Draw(img)
            for y in range(1024):
                c = int(20 + (y / 1024) * 40)
                draw.line([(0, y), (1023, y)], fill=(c, c, c + 10))
            img.save(png_path, "PNG")
        else:
            # Middle and Front: RGBA transparent
            Image.new("RGBA", (1024, 1024), (0, 0, 0, 0)).save(png_path, "PNG")


def compile_catalog(catalog_dir, output_dir, app_dir):
    os.makedirs(output_dir, exist_ok=True)
    cmd = [
        "xcrun", "actool",
        "--compile", output_dir,
        "--platform", "xros",
        "--minimum-deployment-target", "1.0",
        "--app-icon", "AppIcon",
        "--output-partial-info-plist", os.path.join(output_dir, "AssetInfo.plist"),
        catalog_dir
    ]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        print("actool stderr:", r.stderr[:500])

    car_src = os.path.join(output_dir, "Assets.car")
    if os.path.exists(car_src):
        shutil.copy2(car_src, os.path.join(app_dir, "Assets.car"))
        print(f"Assets.car injected ({os.path.getsize(car_src)//1024}KB)")
        return True

    print("WARNING: actool did not produce Assets.car")
    print("Files produced:", os.listdir(output_dir))
    return False


def patch_infoplist(app_dir):
    plist_path = os.path.join(app_dir, "Info.plist")
    with open(plist_path, "rb") as f:
        info = plistlib.load(f)
    # CFBundlePrimaryIcon must be a string, not a dict (ITMS-90039 if dict)
    info["CFBundleIcons"] = {"CFBundlePrimaryIcon": "AppIcon"}
    info["CFBundleIcons~ipad"] = {"CFBundlePrimaryIcon": "AppIcon"}
    with open(plist_path, "wb") as f:
        plistlib.dump(info, f)
    print("Patched Info.plist: CFBundleIcons.CFBundlePrimaryIcon = 'AppIcon'")


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    app_dir = sys.argv[1]
    custom_catalog = sys.argv[2] if len(sys.argv) > 2 else None

    for d in [CATALOG_DIR, OUTPUT_DIR]:
        if os.path.exists(d):
            shutil.rmtree(d)

    if custom_catalog:
        print(f"Using custom icon catalog: {custom_catalog}")
        catalog_dir = custom_catalog
    else:
        print("Generating placeholder icon catalog...")
        build_placeholder_catalog(CATALOG_DIR)
        catalog_dir = CATALOG_DIR

    print("Compiling with actool...")
    compile_catalog(catalog_dir, OUTPUT_DIR, app_dir)
    patch_infoplist(app_dir)
    print("visionOS icon injection complete.")


if __name__ == "__main__":
    main()
