#!/usr/bin/env bash
set -euo pipefail

service_root="${GMGN_MOTION_SERVICE_ROOT:-$HOME/services/gmgn-motion-service}"
output_root="${GMGN_MOTION_OUTPUT_ROOT:-$HOME/.local/share/gmgn-radio/motions}"
public_base_url="${GMGN_MOTION_PUBLIC_BASE_URL:-https://192.168.1.85:8765}"
listen_host="${GMGN_MOTION_LISTEN_HOST:-192.168.1.85}"
tls_root="${GMGN_MOTION_TLS_ROOT:-$HOME/.config/gmgn-motion/tls}"

cd "$service_root"
exec python3 -m tools.motion.gmgn_motion_service \
  --output-root "$output_root" \
  --ardy-url http://127.0.0.1:2337 \
  --host "$listen_host" \
  --port 8765 \
  --public-base-url "$public_base_url" \
  --tls-cert "$tls_root/server.crt" \
  --tls-key "$tls_root/server.key" \
  --model ARDY-Core-RP-20FPS-Horizon40 \
  --revision abe6c43beb28c867c950acb824b9c4ef3d63fb76
