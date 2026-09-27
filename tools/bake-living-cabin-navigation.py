#!/usr/bin/env python3
"""Compile offline navigation checks against current production WorldRuntime sources."""
import argparse
import hashlib
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
    args = parser.parse_args()
    if not args.test and not args.output:
        parser.error("--output is required unless --test is used")
    with tempfile.TemporaryDirectory(prefix="gmgn-cabin-nav-build-") as temporary:
        executable = Path(temporary) / "navigation"
        # Compile the actual authored support configuration into this hostless
        # module. Only its value type is needed from the placement service.
        presence = ROOT / "apps/macos/Sources/GMGNRadio/Presence"
        configuration_bytes = (presence / "ResidentPropPlacementConfiguration.swift").read_bytes()
        service = (presence / "ResidentPropPlacementService.swift").read_text()
        support_type = service[service.index("struct ResidentPropSupportSurface:"):service.index("enum ResidentPropPlacementError:")]
        configuration = Path(temporary) / "SupportConfiguration.swift"
        configuration.write_text(configuration_bytes.decode().replace("import WorldRuntime\n", "") + "\n" + support_type
            + '\nlet cabinSupportConfigurationSHA256 = "' + hashlib.sha256(configuration_bytes).hexdigest() + '"\n')
        sources = sorted((ROOT / "apps/macos/Packages/WorldRuntime/Sources/WorldRuntime").glob("*.swift"))
        sources += [configuration, ROOT / "tools/navigation/LivingCabinNavigation.swift",
                    ROOT / "tools/navigation" / ("test-living-cabin-navigation.swift" if args.test else "bake-living-cabin-navigation-main.swift")]
        subprocess.run(["/usr/bin/swiftc", "-O", "-parse-as-library", *map(str,sources), "-o", str(executable)], check=True)
        command = [str(executable)]
        if not args.test:
            command += [str(args.package.resolve(strict=True)), str(args.output.resolve())]
            if args.verify:
                command += [str(args.verify.resolve(strict=True))]
        subprocess.run(command, check=True)

if __name__ == "__main__":
    main()
