#!/usr/bin/env python3
"""Build ARDY's LLM2Vec text encoder from pinned local snapshots."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import torch
from peft import PeftModel
from transformers import AutoTokenizer

from ardy.model.llm2vec.models.bidirectional_llama import LlamaBiModel


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", required=True)
    parser.add_argument("--adapter", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    output = Path(args.out)
    output.mkdir(parents=True, exist_ok=True)

    print(f"loading local base: {args.base}", flush=True)
    model = LlamaBiModel.from_pretrained(
        args.base,
        dtype=torch.bfloat16,
        local_files_only=True,
        low_cpu_mem_usage=True,
    )
    print(f"merging local adapter: {args.adapter}", flush=True)
    model = PeftModel.from_pretrained(model, args.adapter, local_files_only=True)
    model = model.merge_and_unload()

    print(f"saving merged encoder: {output}", flush=True)
    model.save_pretrained(output, safe_serialization=True)
    AutoTokenizer.from_pretrained(args.adapter, local_files_only=True).save_pretrained(output)

    config_path = output / "config.json"
    config = json.loads(config_path.read_text(encoding="utf-8"))
    config["_name_or_path"] = "meta-llama/Meta-Llama-3-8B-Instruct"
    config_path.write_text(json.dumps(config, indent=2) + "\n", encoding="utf-8")
    (output / "build-complete.marker").touch()
    print("done", flush=True)


if __name__ == "__main__":
    main()
