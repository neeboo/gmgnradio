"""Private API smoke client. Token is read from a file, never printed."""
import argparse
import base64
import json
from pathlib import Path
from urllib.request import Request, urlopen


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=["health", "submit", "status", "cancel", "download"])
    parser.add_argument("--url", default="http://127.0.0.1:8191")
    parser.add_argument("--token-file", type=Path, default=Path("/home/spark/gmgn-prop-service/api-token"))
    parser.add_argument("--job")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    headers = {"Authorization": "Bearer " + args.token_file.read_text().strip(), "Content-Type": "application/json"}
    body = None
    if args.action == "health":
        path = "/health"
    elif args.action == "submit":
        # An original procedural test reference, no brands or private user image.
        from PIL import Image, ImageDraw
        import io
        image = Image.new("RGBA", (512, 512), (255, 255, 255, 255))
        draw = ImageDraw.Draw(image)
        draw.polygon([(122,160),(262,90),(397,165),(258,243)], fill="#8acbf2")
        draw.polygon([(122,160),(258,243),(258,415),(122,327)], fill="#428cb9")
        draw.polygon([(258,243),(397,165),(397,336),(258,415)], fill="#215779")
        stream = io.BytesIO(); image.save(stream, format="PNG")
        payload = {"image_base64": base64.b64encode(stream.getvalue()).decode(), "name": "蓝色积木测试道具",
                   "source": {"license": "CC0-1.0", "author": "gmgn original procedural fixture"}, "height_meters": 0.3}
        headers["Idempotency-Key"] = "original-blue-block-v1"
        body = json.dumps(payload).encode()
        path = "/v1/jobs"
    else:
        if not args.job:
            parser.error("--job is required")
        path = "/v1/jobs/" + args.job
        if args.action == "cancel":
            path += "/cancel"; body = b"{}"
        elif args.action == "download":
            if not args.output:
                parser.error("--output is required")
            path += "/model.glb"
    with urlopen(Request(args.url + path, data=body, headers=headers), timeout=30) as response:
        if args.action == "download":
            args.output.write_bytes(response.read())
            print(json.dumps({"downloaded": str(args.output)}))
        else:
            print(json.dumps(json.load(response), ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
