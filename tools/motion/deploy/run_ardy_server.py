#!/usr/bin/env python3
"""Launch text-to-vrma with all text-encoder weights pinned locally."""

from __future__ import annotations

import argparse
import importlib
import os
import runpy
import sys
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--server", required=True)
    known, remaining = parser.parse_known_args()

    adapter = os.environ.get("ARDY_SUPERVISED_ADAPTER", "").strip()
    if not adapter:
        raise RuntimeError("ARDY_SUPERVISED_ADAPTER is required")

    load_model = importlib.import_module("ardy.model.load_model")
    load_model.TEXT_ENCODER_PRESETS["llm2vec"]["kwargs"][
        "peft_model_name_or_path"
    ] = adapter

    server_path = str(Path(known.server).resolve())
    sys.path.insert(0, str(Path(server_path).parent))
    sys.argv = [server_path, *remaining]
    runpy.run_path(server_path, run_name="__main__")


if __name__ == "__main__":
    main()
