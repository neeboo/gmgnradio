"""Rebuild our tiny authored thinking clips; no model or remote service used."""
import json
from pathlib import Path

from tools.motion.gmgn_motion_factory import build_vmd, build_vrma


def main():
    root = Path(__file__).resolve().parents[2]
    spec = json.loads((root / "tools/motion/fixtures/resident-thinking.json").read_text())
    output = root / "apps/macos/Resources/ResidentMotions"
    output.mkdir(parents=True, exist_ok=True)
    for extension, builder in (("vmd", build_vmd), ("vrma", build_vrma)):
        artifact = output / f"gmgn.motion.resident-thinking.{extension}"
        artifact.write_bytes(builder(spec))
        print(f"{artifact.relative_to(root)}: {artifact.stat().st_size} bytes")


if __name__ == "__main__":
    main()
