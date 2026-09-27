"""Rebuild the fixed PMX right-hand display loop; no remote service is used."""
import json
from pathlib import Path

from tools.motion.gmgn_motion_factory import build_vmd


def main():
    root = Path(__file__).resolve().parents[2]
    spec = json.loads(
        (root / "tools/motion/fixtures/resident-hold-display.json").read_text()
    )
    output = (
        root
        / "apps/macos/Resources/ResidentMotions"
        / "gmgn.motion.resident-hold-display.vmd"
    )
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(build_vmd(spec))
    print(f"{output.relative_to(root)}: {output.stat().st_size} bytes")


if __name__ == "__main__":
    main()
