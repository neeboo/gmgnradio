#!/usr/bin/env python3
"""Preserve resolved native product metadata while changing only the launcher."""
import argparse
from pathlib import Path
import plistlib


def product_metadata(source: dict, *, e2e: bool = False) -> dict:
    identity = "ai.gmgn.radio.e2e" if e2e else "ai.gmgn.radio"
    if source.get("CFBundleIdentifier") != identity or source.get("CFBundleExecutable") != "gmgn radio":
        raise ValueError("Expected the explicit native carrier with the matching product identity")
    required = ("CFBundleName", "CFBundleIconFile", "CFBundleVersion", "CFBundleShortVersionString",
                "LSMinimumSystemVersion", "NSMicrophoneUsageDescription", "NSAppleMusicUsageDescription",
                "NSLocalNetworkUsageDescription")
    if any(not isinstance(source.get(key), str) or not source[key].strip() or "$(" in source[key]
           for key in required):
        raise ValueError("Native product metadata must be resolved and retain its privacy capabilities")
    result = dict(source)
    result["CFBundleExecutable"] = "gmgn-gpui-app"
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--destination", type=Path, required=True)
    parser.add_argument("--e2e", action="store_true", help="explicit isolated test identity only")
    args = parser.parse_args()
    with args.source.open("rb") as handle:
        source = plistlib.load(handle)
    with args.destination.open("wb") as handle:
        plistlib.dump(product_metadata(source, e2e=args.e2e), handle, sort_keys=False)


if __name__ == "__main__":
    main()
