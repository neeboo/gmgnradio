#!/usr/bin/env python3
"""Compile offline navigation checks against current production WorldRuntime sources."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--test", action="store_true")
    parser.add_argument("--package", type=Path, default=ROOT / "apps/macos/Resources/Worlds/marble-living-cabin")
    parser.add_argument("--output", type=Path, help="explicit candidate output directory; never writes app resources")
    parser.add_argument("--verify", type=Path, help="verify an existing navigation.json instead of generating one")
    parser.add_argument("--verify-layout", type=Path, help="verify all navigation edges from an authored layout")
    parser.add_argument("--update-layout-source", action="store_true", help="after successful verification, update only the verified layout navigation source")
    args = parser.parse_args()
    if args.verify and args.verify_layout:
        parser.error("choose --verify or --verify-layout")
    if args.update_layout_source and not args.verify_layout:
        parser.error("--update-layout-source requires --verify-layout")
    if not args.test and not args.output:
        parser.error("--output is required unless --test is used")
    with tempfile.TemporaryDirectory(prefix="gmgn-cabin-nav-build-") as temporary:
        layout = None
        verify = args.verify
        if args.verify_layout:
            layout = json.loads(args.verify_layout.read_text())
            manifest = json.loads((args.package / "world.json").read_text())
            configuration = json.loads((args.package / "marble.json").read_text())
            if (layout["worldID"] != manifest["worldID"] or
                    layout["collisionVolumes"] != manifest["collisionVolumes"] or
                    layout["framing"] != configuration["framing"]):
                parser.error("verification package does not match the authored world, collision volumes and framing")
            verify = Path(temporary) / "navigation.json"
            verify.write_text(json.dumps(layout["navigation"]))
        executable = Path(temporary) / "navigation"
        # Props block navigation at runtime through the graph's lazy replanning, so the
        # baker no longer reserves authored placement surfaces and no longer needs the
        # placement configuration compiled into this hostless module.
        sources = sorted((ROOT / "apps/macos/Packages/WorldRuntime/Sources/WorldRuntime").glob("*.swift"))
        sources += [ROOT / "tools/navigation/LivingCabinNavigation.swift",
                    ROOT / "tools/navigation" / ("test-living-cabin-navigation.swift" if args.test else "bake-living-cabin-navigation-main.swift")]
        subprocess.run(["/usr/bin/swiftc", "-O", "-parse-as-library", *map(str,sources), "-o", str(executable)], check=True)
        command = [str(executable)]
        if not args.test:
            command += [str(args.package.resolve(strict=True)), str(args.output.resolve())]
            if verify:
                command += [str(verify.resolve(strict=True))]
        subprocess.run(command, check=True)
        if args.update_layout_source:
            # The native verifier checks every edge in both directions against
            # actual geometry and the current collision volumes before emitting.
            verified = json.loads((args.output / "navigation.json").read_text())
            current = json.loads(args.verify_layout.read_text())
            if current != layout:
                raise RuntimeError("authored layout changed during verification; refusing to overwrite")
            current["navigation"]["source"] = verified["source"]
            args.verify_layout.write_text(json.dumps(current, ensure_ascii=False, indent=2) + "\n")

if __name__ == "__main__":
    main()
