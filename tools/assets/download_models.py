"""Download only the fixed workflow's TRELLIS branch weights, serially."""
import argparse
import hashlib
import json
from pathlib import Path
import urllib.request

WORKFLOW_SHA256 = "a4ffdea180901016255224df7e509f7db0fe2325f688a8c4376bf153dcf1b7a0"
SELECTED_NODES = {15, 40, 117, 118, 193}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("workflow", type=Path)
    parser.add_argument("models", type=Path)
    args = parser.parse_args()
    source = args.workflow.read_bytes()
    if hashlib.sha256(source).hexdigest() != WORKFLOW_SHA256:
        raise SystemExit("untrusted workflow")
    nodes = json.loads(source)["nodes"]
    receipts = []
    for node in nodes:
        if node["id"] not in SELECTED_NODES:
            continue
        for model in node["properties"]["models"]:
            destination = args.models / model["directory"] / model["name"]
            destination.parent.mkdir(parents=True, exist_ok=True)
            partial = destination.with_suffix(destination.suffix + ".partial")
            if not destination.exists():
                print("Downloading", model["name"], flush=True)
                with urllib.request.urlopen(model["url"], timeout=60) as response, partial.open("wb") as output:
                    while block := response.read(8 * 1024 * 1024):
                        output.write(block)
                partial.rename(destination)
            digest = hashlib.file_digest(destination.open("rb"), "sha256").hexdigest()
            receipts.append({"name": model["name"], "directory": model["directory"], "url": model["url"], "bytes": destination.stat().st_size, "sha256": digest})
            print("Downloaded", model["name"], destination.stat().st_size, digest, flush=True)
    (args.models.parent / "model-receipts.json").write_text(json.dumps(receipts, indent=2) + "\n")


if __name__ == "__main__":
    main()
