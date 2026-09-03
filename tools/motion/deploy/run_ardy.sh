#!/usr/bin/env bash
set -euo pipefail

engine_root="${GMGN_ARDY_ENGINE_ROOT:-$HOME/services/ardy-engine}"
source_root="${GMGN_TEXT_TO_VRMA_ROOT:-$HOME/services/text-to-vrma}"
deploy_root="${GMGN_MOTION_DEPLOY_ROOT:-$HOME/services/gmgn-motion-service/tools/motion/deploy}"

export HF_HOME="${HF_HOME:-$engine_root/hf-cache}"
export CHECKPOINTS_DIR="${CHECKPOINTS_DIR:-$engine_root/checkpoints}"
export TEXT_ENCODER_DEVICE="${TEXT_ENCODER_DEVICE:-cpu}"
export ARDY_SUPERVISED_ADAPTER="${ARDY_SUPERVISED_ADAPTER:-$engine_root/source-models/LLM2Vec-Meta-Llama-3-8B-Instruct-mntp-supervised}"

exec "$engine_root/venv/bin/python" \
  "$deploy_root/run_ardy_server.py" \
  --server "$source_root/tools/ardy-engine/server.py" \
  --port 2337 \
  --merged-base "$engine_root/llm2vec-base-merged"
