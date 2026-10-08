"""Metadata/hash contract for the actual Unity + embedded GPUI product."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib

IDENTITY = "ai.gmgn.unity-sample.player"
PRIVACY = ("NSMicrophoneUsageDescription", "NSAppleMusicUsageDescription", "NSLocalNetworkUsageDescription")
COMPONENTS = ("Contents/Plugins/UnityMediaHost.dylib", "Contents/Plugins/libgmgn_gpui_overlay_probe.dylib", "Contents/Helpers/gmgn-taskd")

def product_metadata(player, privacy, *, version=None, build=None):
    if player.get("CFBundleIdentifier") != IDENTITY:
        raise ValueError("Expected existing formal Unity identity")
    executable = player.get("CFBundleExecutable")
    if not isinstance(executable, str) or not executable or Path(executable).name != executable or executable in (".", ".."):
        raise ValueError("Unsafe Unity executable")
    result = dict(player)
    result["CFBundleName"] = result["CFBundleDisplayName"] = "gmgn radio"
    for key in PRIVACY:
        value = privacy.get(key)
        if not isinstance(value, str) or not value.strip() or "$(" in value:
            raise ValueError("Unresolved production privacy metadata: " + key)
        result[key] = value
    for key, override in (("CFBundleShortVersionString", version), ("CFBundleVersion", build)):
        if override is not None:
            result[key] = override
        value = result.get(key)
        if not isinstance(value, str) or not value.strip() or "$(" in value:
            raise ValueError("Expected source or explicit release version: " + key)
    return result

def verify(app):
    app = Path(app).resolve(strict=True)
    with (app / "Contents/Info.plist").open("rb") as handle:
        info = plistlib.load(handle)
    product_metadata(info, info)
    paths = (app / "Contents/MacOS" / info["CFBundleExecutable"],
             app / "Contents/Plugins/UnityMediaHost.dylib",
             app / "Contents/Plugins/libgmgn_gpui_overlay_probe.dylib",
             app / "Contents/Helpers/gmgn-taskd", app / "Contents/Resources/unity-product-manifest.json")
    for path in paths:
        if path.is_symlink() or not path.is_file() or not path.resolve().is_relative_to(app):
            raise ValueError("Missing or unsafe Unity component: " + path.name)
    if not os.access(paths[0], os.X_OK) or not os.access(paths[3], os.X_OK):
        raise ValueError("Product/helper must be executable")
    manifest = json.loads(paths[4].read_text())
    expected = {relative: hashlib.sha256((app / relative).read_bytes()).hexdigest() for relative in COMPONENTS}
    if manifest != expected:
        raise ValueError("Unity product component manifest mismatch")

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--player", type=Path)
    parser.add_argument("--privacy-source", type=Path)
    parser.add_argument("--verify", type=Path)
    parser.add_argument("--write-manifest", type=Path)
    args = parser.parse_args()
    if args.write_manifest:
        app = args.write_manifest.resolve(strict=True)
        for relative in COMPONENTS:
            path = app / relative
            if path.is_symlink() or not path.is_file() or not path.resolve().is_relative_to(app):
                raise ValueError("Unsafe component manifest input")
        destination = app / "Contents/Resources/unity-product-manifest.json"
        if destination.is_symlink() or not destination.parent.resolve().is_relative_to(app):
            raise ValueError("Unsafe manifest destination")
        manifest = {relative: hashlib.sha256((app / relative).read_bytes()).hexdigest() for relative in COMPONENTS}
        destination.write_text(json.dumps(manifest, sort_keys=True) + "\n")
        return
    if args.verify:
        verify(args.verify)
        return
    if args.player is None or args.player.is_symlink() or args.privacy_source is None:
        raise ValueError("Explicit fresh Unity Player and privacy source required")
    plist = args.player / "Contents/Info.plist"
    with plist.open("rb") as handle:
        player = plistlib.load(handle)
    with args.privacy_source.open("rb") as handle:
        privacy = plistlib.load(handle)
    result = product_metadata(player, privacy, version=os.environ.get("GMGN_RELEASE_VERSION"), build=os.environ.get("GMGN_RELEASE_BUILD"))
    with plist.open("wb") as handle:
        plistlib.dump(result, handle, sort_keys=False)

if __name__ == "__main__":
    main()
